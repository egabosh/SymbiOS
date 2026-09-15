#!/bin/bash
# SymbiOS - Report host system statistics for the dashboard WebUI.
# Output: one JSON line with CPU %, load average, memory, swap, uptime and
# disk I/O (read/write throughput and %util) sampled over 1 second.
# Pure /proc based - no sysstat or any other package is required.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Sample interval in seconds; a short delay is needed to compute rates.
f_interval=1

f_tmp="${g_tmp:-/tmp}"
f_cpu_a="${f_tmp}/symbios-stats-cpu-a.$$"
f_cpu_b="${f_tmp}/symbios-stats-cpu-b.$$"
f_disk_a="${f_tmp}/symbios-stats-disk-a.$$"
f_disk_b="${f_tmp}/symbios-stats-disk-b.$$"
trap 'rm -f "${f_cpu_a}" "${f_cpu_b}" "${f_disk_a}" "${f_disk_b}"' EXIT

# Collect the diskstats lines for the *real* block devices into a snapshot
# file. Virtual / removable / RAID devices (loop, ram, zram, dm, md, sr, fd,
# nbd) are skipped so only physical host disks are reported.
f_device_names=""
for f_block in /sys/block/*
do
  f_name="${f_block##*/}"
  case "${f_name}" in
    loop*|ram*|zram*|dm-*|md*|sr*|fd*|nbd*)
      continue
      ;;
  esac
  f_device_names="${f_device_names} ${f_name}"
done

f_disk_snap() {
  awk -v f_devs="${f_device_names# }" '
    BEGIN { for (f_n = 1; f_n <= split(f_devs, f_a, " "); f_n++) want[f_a[f_n]] = 1 }
    ($3 in want) { print }
  ' /proc/diskstats > "${1}"
}

# Take the first sample, wait, then take the second sample.
f_device_ok=0
grep -m1 '^cpu ' /proc/stat > "${f_cpu_a}"
if [[ -n "${f_device_names}" ]]
then
  f_disk_snap "${f_disk_a}"
  f_device_ok=1
fi
sleep "${f_interval}"
grep -m1 '^cpu ' /proc/stat > "${f_cpu_b}"
if [[ "${f_device_ok}" -eq 1 ]]
then
  f_disk_snap "${f_disk_b}"
fi

# CPU usage: deltas between the two samples. The idle field already excludes
# iowait ticks (iowait is busy waiting, not idle), so it is reported
# separately as an I/O load indicator. Fields: user nice system idle iowait
# irq softirq steal guest guest_nice (plus the leading 'cpu' label).
f_cpu=$(awk -v f_a="$(cat "${f_cpu_a}")" -v f_b="$(cat "${f_cpu_b}")" '
  BEGIN {
    split(f_a, a); split(f_b, b);
    total_a = 0; total_b = 0;
    for (i = 2; i <= 11; i++) { total_a += a[i]; total_b += b[i]; }
    delta = total_b - total_a;
    idle_a = a[5]; idle_b = b[5];
    iowait_a = a[6]; iowait_b = b[6];
    idle_delta = idle_b - idle_a;
    iowait_delta = iowait_b - iowait_a;
    cpu = (delta > 0) ? (delta - idle_delta) * 100.0 / delta : 0;
    iowait = (delta > 0) ? iowait_delta * 100.0 / delta : 0;
    if (cpu < 0) cpu = 0;
    if (cpu > 100) cpu = 100;
    if (iowait < 0) iowait = 0;
    if (iowait > 100) iowait = 100;
    printf "%.1f|%.1f", cpu, iowait;
  }')
f_cpu_percent="${f_cpu%%|*}"
f_iowait_percent="${f_cpu##*|}"

# Disk I/O: total throughput and %util across all physical devices plus a
# per-device breakdown. diskstats columns after major/minor are:
#   $3 name, $6 sectors read, $10 sectors written, $13 time doing I/O (ms).
# The two snapshot files list the devices in the same order, so a line-wise
# delta is valid. Sectors are 512 bytes -> kB/s; %util is ms-per-sample / 10.
f_io=""
if [[ "${f_device_ok}" -eq 1 ]]
then
  f_io=$(awk '
    NR == FNR { fa[NR] = $0; next }
    {
      fb[FNR] = $0;
      split(fa[FNR], xa);
      split($0, xb);
      dname    = xb[3];
      rsec     = xb[6]  - xa[6];
      wsec     = xb[10] - xa[10];
      io_time  = xb[13] - xa[13];
      if (rsec < 0) rsec = 0;
      if (wsec < 0) wsec = 0;
      if (io_time < 0) io_time = 0;
      rkbs     = rsec * 512 / 1024;
      wkbs     = wsec * 512 / 1024;
      util     = io_time / 10.0;
      if (util > 100) util = 100;
      total_r += rsec; total_w += wsec; total_io += io_time;
      printf "%s,%d,%d,%.1f;", dname, rkbs, wkbs, util;
    }
    END {
      if (FNR > 0) {
        printf "|%d|%d|%.1f", total_r * 512 / 1024, total_w * 512 / 1024, total_io / 10.0;
      }
    }
  ' "${f_disk_a}" "${f_disk_b}")
fi
f_devices_io="${f_io%%|*}"
f_io_agg="${f_io#*|}"
f_io_rkbs="0"; f_io_wkbs="0"; f_io_util="0.0"
if [[ -n "${f_io_agg}" ]] && [[ "${f_io_agg}" != "${f_io}" ]]
then
  f_io_rkbs="${f_io_agg%%|*}"; f_io_mid="${f_io_agg#*|}"
  f_io_wkbs="${f_io_mid%%|*}"; f_io_util="${f_io_mid#*|}"
fi

# Load average (1 / 5 / 15 minutes).
read -r f_load1 f_load5 f_load15 _ < /proc/loadavg
f_load1="${f_load1:-0}"; f_load5="${f_load5:-0}"; f_load15="${f_load15:-0}"

# Memory and swap from /proc/meminfo (values in kB).
f_mem_total=0; f_mem_available=0; f_swap_total=0; f_swap_free=0
while read -r f_key f_value _f_unit
do
  case "${f_key}" in
    MemTotal:)     f_mem_total="${f_value}"     ;;
    MemAvailable:) f_mem_available="${f_value}" ;;
    SwapTotal:)    f_swap_total="${f_value}"    ;;
    SwapFree:)     f_swap_free="${f_value}"     ;;
  esac
done < /proc/meminfo

f_mem_total_mb=$(( f_mem_total / 1024 ))
f_mem_available_mb=$(( f_mem_available / 1024 ))
f_mem_used_mb=$(( f_mem_total_mb - f_mem_available_mb ))
f_mem_percent=0
if [[ "${f_mem_total_mb}" -gt 0 ]]
then
  f_mem_percent=$(( f_mem_used_mb * 100 / f_mem_total_mb ))
fi
f_swap_total_mb=$(( f_swap_total / 1024 ))
f_swap_free_mb=$(( f_swap_free / 1024 ))
f_swap_used_mb=$(( f_swap_total_mb - f_swap_free_mb ))
f_swap_percent=0
if [[ "${f_swap_total_mb}" -gt 0 ]]
then
  f_swap_percent=$(( f_swap_used_mb * 100 / f_swap_total_mb ))
fi

# Number of CPU cores for load-normalization display.
f_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[[ "${f_cores}" -ge 1 ]] || f_cores=1

# Uptime as a human readable string.
f_uptime_secs="$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || echo 0)"
f_up_days=$(( f_uptime_secs / 86400 ))
f_up_rest=$(( f_uptime_secs % 86400 ))
f_up_hours=$(( f_up_rest / 3600 ))
f_up_minutes=$(( (f_up_rest % 3600) / 60 ))
f_uptime=""
if [[ "${f_up_days}" -gt 0 ]]
then
  f_uptime="${f_up_days} days, "
fi
f_uptime+="$(printf '%02d:%02d' "${f_up_hours}" "${f_up_minutes}")"

f_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the per-device I/O JSON array.
printf '{"timestamp":"%s","cores":%d,"cpu_percent":%.1f,"cpu_iowait":%.1f,' \
  "${f_timestamp}" "${f_cores}" "${f_cpu_percent}" "${f_iowait_percent}"
printf '"load1":%s,"load5":%s,"load15":%s,' "${f_load1}" "${f_load5}" "${f_load15}"
printf '"mem_total_mb":%d,"mem_used_mb":%d,"mem_percent":%d,' \
  "${f_mem_total_mb}" "${f_mem_used_mb}" "${f_mem_percent}"
printf '"swap_total_mb":%d,"swap_used_mb":%d,"swap_percent":%d,' \
  "${f_swap_total_mb}" "${f_swap_used_mb}" "${f_swap_percent}"
printf '"uptime":"%s",' "${f_uptime}"
printf '"io_read_kbs":%s,"io_write_kbs":%s,"io_util_percent":%.1f,"io_devices":[' \
  "${f_io_rkbs}" "${f_io_wkbs}" "${f_io_util}"
f_first=1
if [[ -n "${f_devices_io}" ]]
then
  while IFS= read -r -d ';' f_ent
  do
    [[ -z "${f_ent}" ]] && continue
    if [[ "${f_first}" -eq 1 ]]
    then
      f_first=0
    else
      printf ','
    fi
    IFS=',' read -r f_name f_rkbs f_wkbs f_util <<< "${f_ent}"
    # The awk emitted integer rates as integers; keep them as numbers.
    printf '{"name":"%s","rkbs":%s,"wkbs":%s,"util":%.1f}' \
      "${f_name}" "${f_rkbs}" "${f_wkbs}" "${f_util}"
  done <<< "${f_devices_io}"
fi
printf ']}\n'

exit 0