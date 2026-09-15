#!/bin/bash
# SymbiOS - Report the top processes by CPU, memory and disk I/O usage.
# Called by symbios-dashboard-snapshot.sh once per minute (cron). The output
# is written to <log>/dashboard-top.json for the WebUI Health page.
#
# Output: one JSON document on stdout:
# {
#   "timestamp": "...", "interval_sec": N, "measuring_io": true|false,
#   "cpu": [{ "pid":..., "name":"...", "cmd":"...", "cpu":<float> }],
#   "mem": [{ "pid":..., "name":"...", "cmd":"...", "rss_mb":<float> }],
#   "io":  [{ "pid":..., "name":"...", "cmd":"...", "read_kbs":<float>,
#             "write_kbs":<float>, "total_kbs":<float> }]
# }
# The `cmd` field carries the full command line (for tooltips in the WebUI);
# it falls back to the truncated comm name when cmdline is unavailable
# (kernel threads, zombies, unreadable proc entries).
#
# I/O is NOT available from /proc stat; it comes from /proc/<pid>/io
# (read_bytes/write_bytes counters). The delta against the previous sample is
# the per-interval rate. The first run after a state reset has no baseline,
# so the io list stays empty until the next tick.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile

f_top_n="${1:-6}"
# Fixed path (NOT g_tmp: that is per-PID and would reset the I/O baseline on
# every invocation). Mirrors the symbios-network-scan.sh /tmp cache pattern.
f_state_file="/tmp/symbios-top-io-state.txt"
f_measuring_io=1
f_interval=0

# Elapsed seconds since the previous sample (for the I/O rate). Equal to the
# cron interval on a healthy system; the first run without a state file
# reports 0 and produces no I/O deltas.
if [[ -f "${f_state_file}" ]]
then
  f_interval=$(( $(date +%s) - $(stat -c %Y "${f_state_file}") ))
  [[ "${f_interval}" -lt 1 ]] && f_interval=1
  f_measuring_io=0
fi

# Top CPU consumers (ps %cpu is averaged over the process lifetime; that is
# exactly what the history trend wants for leak/runaway detection).
f_cpu="$(ps -eo pid=,comm=,%cpu= --sort=-%cpu | head -n "${f_top_n}")"

# Top memory consumers by resident set size.
f_mem="$(ps -eo pid=,comm=,rss= --sort=-rss | head -n "${f_top_n}")"

# Snapshot the current /proc/<pid>/io counters into a plain list of
# "pid read_bytes write_bytes comm" lines and remember the old values.
f_state_tmp="${f_state_file}.$$"
: > "${f_state_tmp}"
f_io_list=""
declare -A g_old_r g_old_w g_cmdline
# Read the full command line of a process; /proc/<pid>/cmdline is NUL
# separated, empty for kernel threads and most kernel helpers.
f_get_cmd() {
  local f_pid="$1"
  if [[ -z "${g_cmdline[${f_pid}]+x}" ]]
  then
    # Guard against races: a process may vanish between the ps snapshot and
    # this read, which would otherwise print a redirection error to stderr.
    if [[ -r "/proc/${f_pid}/cmdline" ]]
    then
      g_cmdline["${f_pid}"]="$(tr '\0' ' ' < "/proc/${f_pid}/cmdline")"
    fi
  fi
  [[ -n "${g_cmdline[${f_pid}]+x}" ]] && echo "${g_cmdline[${f_pid}]}" || echo ""
}
# Preload cmdline for the CPU and memory lists (their pids come from ps).
while read -r f_pid f_rest
do
  f_get_cmd "${f_pid}" > /dev/null
done <<< "${f_cpu}${f_mem}"
if [[ "${f_measuring_io}" -eq 0 ]]
then
  while read -r f_pid f_r f_w f_rest
  do
    g_old_r["${f_pid}"]="${f_r}"
    g_old_w["${f_pid}"]="${f_w}"
  done < "${f_state_file}"
fi
for f_proc in /proc/[0-9]*
do
  [[ -r "${f_proc}/io" ]] || continue
  f_pid="${f_proc##*/}"
  f_r=0; f_w=0
  while read -r f_key f_val
  do
    case "${f_key}" in
      read_bytes:)  f_r="${f_val}" ;;
      write_bytes:) f_w="${f_val}" ;;
    esac
  done < "${f_proc}/io" 2>/dev/null
  f_name="$(cat "${f_proc}/comm" 2>/dev/null || echo ?)"
  printf '%s %s %s %s\n' "${f_pid}" "${f_r}" "${f_w}" "${f_name}" >> "${f_state_tmp}"
  f_cmd="$(f_get_cmd "${f_pid}")"
  f_name="${f_name//[$'\t\n\r']/ }"
  # Tracked delta only for processes that already existed last tick.
  if [[ "${f_measuring_io}" -eq 0 ]] && [[ -n "${g_old_r[${f_pid}]+x}" ]]
  then
    f_dr=$(( f_r - g_old_r[${f_pid}] ))
    f_dw=$(( f_w - g_old_w[${f_pid}] ))
    [[ "${f_dr}" -lt 0 ]] && f_dr=0
    [[ "${f_dw}" -lt 0 ]] && f_dw=0
    f_tot=$(( f_dr + f_dw ))
    if [[ "${f_tot}" -gt 0 ]]
    then
      f_dr_kbs=$(awk -v f_v="${f_dr}" -v f_i="${f_interval}" 'BEGIN { printf "%.2f", f_v / 1024 / f_i }')
      f_dw_kbs=$(awk -v f_v="${f_dw}" -v f_i="${f_interval}" 'BEGIN { printf "%.2f", f_v / 1024 / f_i }')
      f_tot_kbs=$(awk -v f_v="${f_tot}" -v f_i="${f_interval}" 'BEGIN { printf "%.2f", f_v / 1024 / f_i }')
      f_io_list+=$'\n'"${f_pid} ${f_name} ${f_dr_kbs} ${f_dw_kbs} ${f_tot_kbs}"
    fi
  fi
done
f_io_list="$(printf '%s\n' "${f_io_list#?}" | sort -k5 -nr | head -n "${f_top_n}")"
mv -f "${f_state_tmp}" "${f_state_file}"

# Build the JSON document. Field order per input line:
#   cpu: pid name cpu
#   mem: pid name rss_kb        (converted to MB)
#   io:  pid name read_kbs write_kbs total_kbs
# The full command line for every pid comes from the g_cmdline map (populated
# during the /proc scan above).
f_list_json() {
  local f_kind="$1" f_text="$2" f_first=1
  local f_out="[" f_pid f_name f_a f_b f_c f_cmd
  while read -r f_pid f_name f_a f_b f_c
  do
    [[ -n "${f_pid}" ]] || continue
    [[ "${f_first}" -eq 1 ]] || f_out+=","
    f_first=0
    f_cmd="${g_cmdline[${f_pid}]:-}"
    [[ -n "${f_cmd}" ]] || f_cmd="${f_name}"
    f_cmd="${f_cmd//[$'\t\n\r']/ }"
    case "${f_kind}" in
      cpu) f_out+="{\"pid\":${f_pid},\"name\":$(printf '%s' "${f_name}" | f_json_escape),\"cmd\":$(printf '%s' "${f_cmd}" | f_json_escape),\"cpu\":${f_a}}" ;;
      mem)
        f_rmb="$(awk -v f_v="${f_a}" 'BEGIN { printf "%.1f", f_v / 1024 }')"
        f_out+="{\"pid\":${f_pid},\"name\":$(printf '%s' "${f_name}" | f_json_escape),\"cmd\":$(printf '%s' "${f_cmd}" | f_json_escape),\"rss_mb\":${f_rmb}}" ;;
      io)
        f_out+="{\"pid\":${f_pid},\"name\":$(printf '%s' "${f_name}" | f_json_escape),\"cmd\":$(printf '%s' "${f_cmd}" | f_json_escape),"
        f_out+="\"read_kbs\":${f_a},\"write_kbs\":${f_b},\"total_kbs\":${f_c}}" ;;
    esac
  done <<< "${f_text}"
  f_out+="]"
  printf '%s' "${f_out}"
}

f_json_cpu="$(f_list_json cpu "${f_cpu}")"
f_json_mem="$(f_list_json mem "${f_mem}")"
f_json_io="$(f_list_json io "${f_io_list}")"

printf '{"timestamp":"%s","interval_sec":%d,"measuring_io":%s,"cpu":%s,"mem":%s,"io":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${f_interval}" "${f_measuring_io}" \
  "${f_json_cpu}" "${f_json_mem}" "${f_json_io}"

exit 0