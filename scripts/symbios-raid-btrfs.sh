#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# symbios-raid-btrfs.sh - Manage btrfs multi-device filesystems
#
# Actions:
#   status [--json]             Show filesystems + device stats + scrub state
#   replace <mnt> <old> <new>   Replace a member device (old: device
#                               path, absent member path or devid)
#   add <mnt> <device>          Add a device + rebalance
#   remove <mnt> <device>       Remove a device
#   scrub <mnt> [start|cancel|status]  Control data scrubbing (start also
#                               records the result for the health check)
#   balance <mnt>               Rebalance data across devices
#   help                        Show this help
#
# Disk location (identify by activity LED) lives on the Data Disk page.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <action> [args...]

Manage btrfs multi-device filesystems (raid1 data/metadata). Replace,
add and remove run in the foreground so the WebUI exec modal can stream
progress; rebalance may take hours on large filesystems.

Actions:
  status [--json]             Show filesystems + device stats + scrub state
  replace <mnt> <old> <new>   Replace a member device (old: device
                              path, absent member path or devid - an
                              absent source is rebuilt from the mirrors)
  add <mnt> <device>          Add a device and rebalance
  remove <mnt> <device>       Remove a device
  scrub <mnt> [start|cancel|status]
                              Control data scrubbing (start records the
                              result for the health check when it ends)
  balance <mnt>               Rebalance data across devices
  locate <device> [seconds]   Identify a disk by sustained reads
                              (dd, default 30s, max 120s)
  help                        Show this help

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]
then
  f_usage
  exit 0
fi

set -euo pipefail

# Central path config (g_config_dir for the scrub state file). Resolved
# relative to this script: the scrub recorder runs as a systemd transient
# unit, where scripts/ is not on PATH.
g_lib="$(dirname "$(readlink -f "$0")")/symbios-lib.sh"
[[ -r "${g_lib}" ]] && source "${g_lib}"

function f_json_escape {
  local f_s
  IFS= read -r f_s
  f_s="${f_s//\\/\\\\}"
  f_s="${f_s//\"/\\\"}"
  f_s="${f_s//$'\t'/\\t}"
  f_s="${f_s//$'\n'/\\n}"
  f_s="${f_s//$'\r'/\\r}"
  printf '"%s"' "$f_s"
}

function f_json_error {
  local f_msg="$1"
  printf '{"ok":false,"error":%s}\n' "$(echo "$f_msg" | f_json_escape)"
  exit 1
}

function f_json_ok {
  local f_data="$1"
  printf '{"ok":true,%s}\n' "$f_data"
}

function f_log {
  echo "[$(date '+%H:%M:%S')] $*"
}

function f_need_btrfs {
  command -v btrfs >/dev/null 2>&1 || f_json_error "btrfs-progs is not installed"
}

# Newest complete line of `btrfs replace status <mnt>`. While a replace
# runs, that command polls internally until it ends and rewrites its
# progress with backspace (new progs) or carriage-return (old ones)
# characters - normalize both into newlines. The erase length does not
# always match the printed text, so a cut-off stream can end in a partial
# fragment; keep only lines that are a complete progress update or a final
# status line. The probe timeout cuts a running poll off; without an
# active replace the command returns by itself right away.
function f_replace_status_line {
  local f_mnt="$1" f_to="${2:-5}"
  timeout "${f_to}" btrfs replace status "${f_mnt}" 2>/dev/null | \
    tr '\r\b' '\n\n' | grep -vE '^[[:space:]]*$' | \
    grep -E '[0-9]+(\.[0-9]+)?% done|finished on|canceled on' | tail -1 || true
}

# State file of the last scrub per filesystem ("<uuid> <mnt> <started> <status>").
# Shared with the monthly btrfs-scrub autoupdate module and read by the
# raid-mdadm check for the freshness test.
function f_scrub_state_file {
  printf '%s/btrfs-scrub-state' "${g_config_dir:-/symbios/base-services/symbios-ui/config}"
}

# True while a scrub runs on <mnt>. A running dev-replace is reported the
# same way (it reuses the scrub machinery).
function f_scrub_running {
  btrfs scrub status "$1" 2>/dev/null | \
    grep -qiE '^[[:space:]]*status:[[:space:]]*running'
}

# Wait for the scrub on <mnt> to end and record its outcome. Runs detached
# (see f_scrub_record_start): a full scrub of a large filesystem takes hours,
# so the WebUI job returns at once - but the result still has to reach the
# state file. Otherwise a manual scrub records nothing and the monthly check
# keeps reporting the previous (aborted) run plus a stale scan.
function f_scrub_record {
  local f_mnt="$1" f_started="$2" f_wait=0 f_raw f_uuid f_val f_status f_state
  while f_scrub_running "${f_mnt}"
  do
    # Give up after two days - a scrub that never ends is not recorded.
    [[ "${f_wait}" -ge 172800 ]] && return 0
    sleep 60
    f_wait=$(( f_wait + 60 ))
  done
  f_raw=$(btrfs scrub status "${f_mnt}" 2>/dev/null || true)
  f_uuid=$(btrfs filesystem show "${f_mnt}" 2>/dev/null | \
    grep -m1 'uuid:' | sed 's/.*uuid:[[:space:]]*//')
  [[ -n "${f_uuid}" ]] || return 0
  # Same line format as the monthly module: "status: <value>", plus (ERROR)
  # when the scan aborted - the check treats that as "did not complete".
  f_val=$(grep -iE '^[[:space:]]*status:' <<< "${f_raw}" | head -1 | \
    sed -E 's/^[[:space:]]*[Ss]tatus:[[:space:]]*//')
  [[ -z "${f_val}" ]] && f_val="no status reported"
  f_status="status: ${f_val}"
  grep -qiE 'status:[[:space:]]*aborted' <<< "${f_raw}" && f_status="${f_status} (ERROR)"
  f_state=$(f_scrub_state_file)
  mkdir -p "$(dirname "${f_state}")" 2>/dev/null || return 0
  grep -v "^${f_uuid} " "${f_state}" 2>/dev/null > "${f_state}.tmp" || true
  echo "${f_uuid} ${f_mnt} ${f_started} ${f_status}" >> "${f_state}.tmp"
  mv -f "${f_state}.tmp" "${f_state}"
}

# Start the recorder as a detached transient unit: the exec job that starts
# the scrub must not wait for it (hours), and gaboshlib kills background jobs
# at exit - systemd-run is the established way around both.
function f_scrub_record_start {
  local f_mnt="$1" f_started="$2" f_uuid8 f_self
  f_uuid8=$(btrfs filesystem show "${f_mnt}" 2>/dev/null | \
    grep -m1 -oE '[0-9a-f]{8}-[0-9a-f-]{27}' | cut -c1-8)
  f_self=$(readlink -f "$0")
  systemd-run --unit="symbios-btrfs-scrub-record-${f_uuid8:-manual}" \
    --collect --no-block </dev/null >/dev/null 2>&1 /bin/bash "${f_self}" \
    scrub "${f_mnt}" record "${f_started}" || true
}

function f_main {
  g_action="${1:-}"
  shift 2>/dev/null || true

  case "${g_action}" in

  status)
    # List ALL btrfs filesystems from `btrfs filesystem show` (mounted AND
    # unmounted - unmounted ones never appear in /proc/mounts). Locked-LUKS
    # members stay invisible until unlocked via the Data Disk page.
    f_need_btrfs
    local f_out="" f_first="yes"
    local f_b_label="" f_b_uuid="" f_b_missing="false" f_b_members="" f_b_devices=""
    local f_b_raw_show=""
    # Block group profiles of one type, joined with "+": a filesystem that
    # was grown or converted can carry several at once (here: a leftover
    # "single" chunk next to the "RAID1" ones). Taking the first match only
    # would report full redundancy while a part of the data has no mirror.
    f_btrfs_profiles() {
      local f_df="$1" f_type="$2" f_p
      f_p=$(awk -v t="${f_type}," '$1 == t { gsub(/:.*/, "", $2); print $2 }' <<< "${f_df}" | \
        paste -sd+ -)
      printf '%s' "${f_p:-unknown}"
    }
    f_btrfs_emit() {
      [[ -z "${f_b_uuid}" ]] && return 0
      local f_b_mount f_b_df f_b_data f_b_meta f_b_sys f_b_stats f_b_scrub
      local f_b_scrub_running="false" f_b_scrub_pct="-1"
      # Declared here, not inside the mounted branch: an unmounted filesystem
      # has no replace to report, but the JSON fields are emitted anyway.
      local f_b_replace_running="false" f_b_replace_pct=""
      # A filesystem can be mounted at several paths (bind mounts): take the
      # first one - every btrfs command needs a single path, not a list.
      # findmnt's UUID= filter resolves the UUID via blkid to ONE device; on
      # multi-device btrfs all members share the fs UUID and that one may not
      # be the mount's source. Scan mounted btrfs filesystems by their actual
      # fs UUID instead - it matches whichever member is the mount source.
      f_b_mount=$(findmnt -n -o TARGET,FSTYPE,UUID -t btrfs 2>/dev/null | \
        awk -v u="${f_b_uuid}" '$2 == "btrfs" && $3 == u { print $1; exit }' || true)
      f_b_df=""
      f_b_data="unknown"
      f_b_meta="unknown"
      f_b_sys="unknown"
      f_b_stats="-"
      f_b_scrub="-"
      if [[ -n "${f_b_mount}" ]]
      then
        f_b_df=$(btrfs filesystem df "${f_b_mount}" 2>/dev/null || true)
        f_b_data=$(f_btrfs_profiles "${f_b_df}" "Data")
        f_b_meta=$(f_btrfs_profiles "${f_b_df}" "Metadata")
        f_b_sys=$(f_btrfs_profiles "${f_b_df}" "System")
        f_b_stats=$(btrfs device stats "${f_b_mount}" 2>/dev/null | awk '
          /write_io_errs/   { g_w += $2 }
          /read_io_errs/    { g_r += $2 }
          /flush_io_errs/   { g_f += $2 }
          /corruption_errs/ { g_c += $2 }
          /generation_errs/ { g_g += $2 }
          END { print "w=" g_w+0 " r=" g_r+0 " f=" g_f+0 " c=" g_c+0 " g=" g_g+0 }')
        # A running dev-replace is reported by `btrfs replace status` -
        # but while one runs that command polls internally until the
        # replace ends, so the probe is wrapped in a short timeout: cut
        # off mid-progress means the replace is alive and the newest line
        # carries the current percentage. Without an active replace the
        # command returns immediately (final or "no replace" line).
        local f_b_rep_line
        f_b_rep_line=$(f_replace_status_line "${f_b_mount}" 5)
        if [[ "${f_b_rep_line}" == *"% done"* ]]
        then
          f_b_replace_running="true"
          f_b_replace_pct=$(grep -oE '[0-9]+(\.[0-9]+)?% done' <<< "${f_b_rep_line}" | \
            grep -oE '^[0-9]+(\.[0-9]+)?' || true)
        fi
        local f_b_scrub_raw
        f_b_scrub_raw=$(btrfs scrub status "${f_b_mount}" 2>/dev/null || true)
        # While a dev-replace runs, btrfs reports it here as a "running"
        # scrub (the replace reuses the scrub machinery) - that state
        # belongs to the replace and must not show up as a user scrub.
        if [[ "${f_b_replace_running}" == "true" ]]
        then
          f_b_scrub="-"
        else
          f_b_scrub=$(echo "${f_b_scrub_raw}" | grep -E 'Status|Duration|Total' | tr '\n' ';' || true)
          # Running scrub: modern progs print the percentage directly
          # ("Bytes scrubbed: 37G (0.28%)"); older ones only give byte
          # counters - fall back to dividing by the used filesystem size.
          if echo "${f_b_scrub_raw}" | grep -qi "running"
          then
            f_b_scrub_running="true"
            f_b_scrub_pct=$(echo "${f_b_scrub_raw}" | grep -oE '\([0-9]+(\.[0-9]+)?%\)' | head -1 | tr -d '()%' || true)
            if ! [[ "${f_b_scrub_pct:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
            then
              local f_b_done f_b_used_h f_b_used
              f_b_done=$(echo "${f_b_scrub_raw}" | grep -oE 'data_bytes_scrubbed: [0-9]+' | awk '{print $2; exit}' || true)
              f_b_used_h=$(btrfs filesystem show "${f_b_uuid}" 2>/dev/null | \
                grep -oE 'FS bytes used [0-9.]+[KMGTPE]?i?B' | awk '{print $4; exit}' || true)
              f_b_used=$(numfmt --from=iec "${f_b_used_h}" 2>/dev/null || echo 0)
              if [[ "${f_b_done:-0}" =~ ^[0-9]+$ ]] && [[ "${f_b_used:-0}" =~ ^[0-9]+$ ]] \
                && [[ "${f_b_done}" -gt 0 ]] && [[ "${f_b_used}" -gt 0 ]]
              then
                f_b_scrub_pct=$(( f_b_done * 100 / f_b_used ))
                [[ "${f_b_scrub_pct}" -gt 100 ]] && f_b_scrub_pct=100
              else
                f_b_scrub_pct=0
              fi
            fi
          fi
        fi
      fi
      [[ "${f_first}" == "yes" ]] || f_out="${f_out}, "
      f_first="no"
      f_out="${f_out}{\"uuid\":$(printf '%s' "${f_b_uuid}" | f_json_escape)"
      f_out="${f_out},\"label\":$(printf '%s' "${f_b_label}" | f_json_escape)"
      f_out="${f_out},\"mountpoint\":$(printf '%s' "${f_b_mount}" | f_json_escape)"
      f_out="${f_out},\"mounted\":$([[ -n "${f_b_mount}" ]] && echo true || echo false)"
      f_out="${f_out},\"data_profile\":$(printf '%s' "${f_b_data}" | f_json_escape)"
      f_out="${f_out},\"metadata_profile\":$(printf '%s' "${f_b_meta}" | f_json_escape)"
      f_out="${f_out},\"system_profile\":$(printf '%s' "${f_b_sys}" | f_json_escape)"
      # A "single" chunk next to the RAID1 ones means part of the data has
      # no mirror - shown as a badge instead of silently calling the
      # filesystem redundant.
      if [[ "${f_b_data}${f_b_meta}${f_b_sys}" == *single* || "${f_b_data}${f_b_meta}${f_b_sys}" == *dup* ]]
      then
        f_out="${f_out},\"redundancy_incomplete\":true"
      else
        f_out="${f_out},\"redundancy_incomplete\":false"
      fi
      f_out="${f_out},\"device_stats\":$(printf '%s' "${f_b_stats}" | f_json_escape)"
      f_out="${f_out},\"scrub\":$(printf '%s' "${f_b_scrub}" | f_json_escape)"
      f_out="${f_out},\"scrub_running\":${f_b_scrub_running}"
      f_out="${f_out},\"scrub_percent\":${f_b_scrub_pct}"
      f_out="${f_out},\"replace_running\":${f_b_replace_running}"
      if [[ -n "${f_b_replace_pct}" ]]
      then
        f_out="${f_out},\"replace_percent\":${f_b_replace_pct}"
      else
        f_out="${f_out},\"replace_percent\":null"
      fi
      f_out="${f_out},\"degraded\":${f_b_missing}"
      f_out="${f_out},\"devices\":[${f_b_devices}]"
      f_out="${f_out},\"members\":[${f_b_members}]}"
      f_b_label="" f_b_uuid="" f_b_missing="false" f_b_members="" f_b_devices="" f_b_raw_show=""
    }
    while IFS= read -r f_line
    do
      if [[ "${f_line}" == Label:* ]]
      then
        f_btrfs_emit
        f_b_label="${f_line#*Label: }"
        f_b_label="${f_b_label%%  uuid:*}"
        f_b_label="${f_b_label//\'/}"
        f_b_uuid="${f_line##*uuid: }"
      elif [[ "${f_line}" =~ ^[[:space:]]*devid[[:space:]]+([0-9]+).*[[:space:]]path[[:space:]]+(.*)$ ]]
      then
        # One line per member. A pulled disk keeps its devid but has no
        # path any more ("path  MISSING") - that id is the only way to
        # address it for a replace, so it has to reach the WebUI.
        local f_b_id="${BASH_REMATCH[1]}" f_b_path="${BASH_REMATCH[2]}"
        f_b_path="${f_b_path%"${f_b_path##*[![:space:]]}"}"
        # Per-device capacity. btrfs registers a device with the size it had
        # when it joined the filesystem - a larger replacement disk keeps the
        # old size registered, so the rest of it stays unused (that is why a
        # replace does not raise the usable capacity). Both numbers travel to
        # the WebUI so the unused remainder can be shown per member.
        [[ -z "${f_b_raw_show}" ]] && \
          f_b_raw_show=$(btrfs filesystem show --raw "${f_b_uuid}" 2>/dev/null || true)
        local f_b_size
        f_b_size=$(awk -v id="${f_b_id}" '$1 == "devid" && $2 == id { print $4; exit }' \
          <<< "${f_b_raw_show}")
        [[ "${f_b_size:-}" =~ ^[0-9]+$ ]] || f_b_size=0
        local f_b_phys=0
        [[ -b "${f_b_path}" ]] && f_b_phys=$(blockdev --getsize64 "${f_b_path}" 2>/dev/null || echo 0)
        [[ "${f_b_phys:-}" =~ ^[0-9]+$ ]] || f_b_phys=0
        if [[ -z "${f_b_path}" || "${f_b_path}" == "MISSING" ]]
        then
          f_b_missing="true"
          [[ -n "${f_b_devices}" ]] && f_b_devices="${f_b_devices}, "
          f_b_devices="${f_b_devices}{\"devid\":${f_b_id},\"path\":\"\",\"missing\":true,\"size\":${f_b_size},\"device_size\":${f_b_phys}}"
        else
          [[ -n "${f_b_devices}" ]] && f_b_devices="${f_b_devices}, "
          f_b_devices="${f_b_devices}{\"devid\":${f_b_id},\"path\":$(printf '%s' "${f_b_path}" | f_json_escape),\"missing\":false,\"size\":${f_b_size},\"device_size\":${f_b_phys}}"
          [[ -n "${f_b_members}" ]] && f_b_members="${f_b_members}, "
          f_b_members="${f_b_members}$(printf '%s' "${f_b_path}" | f_json_escape)"
        fi
      elif [[ "${f_line}" == *"Some devices missing"* ]]
      then
        # Older btrfs-progs report the missing members only in this summary
        # line (no per-device MISSING row) - keep it as a fallback.
        f_b_missing="true"
      fi
    done < <(btrfs filesystem show 2>/dev/null || true)
    f_btrfs_emit
    f_json_ok "\"filesystems\":[${f_out}]"
    ;;

  replace)
    f_need_btrfs
    local f_mnt="${1:-}" f_old="${2:-}" f_new="${3:-}" f_source f_devid f_out
    [[ -z "${f_mnt}" || -z "${f_old}" || -z "${f_new}" ]] && \
      f_json_error "Usage: $0 replace <mountpoint> <old-device|devid> <new-device>"
    [[ -b "${f_new}" ]] || f_json_error "New device ${f_new} does not exist"
    # The source is a device path, a devid, or the recorded path of a disk
    # that is already gone. btrfs needs the numeric devid plus -r for the
    # last two cases: it then rebuilds the data from the surviving mirrors.
    # That is the normal path when a failing disk was pulled and the
    # replacement sits in its bay (a RAID1 volume with two members cannot
    # shrink by "remove", so replace is the only way to swap a disk).
    local f_opts=()
    if [[ "${f_old}" =~ ^[0-9]+$ ]]
    then
      # Numeric devid: the source device is not addressable by path.
      f_source="${f_old}"
      f_opts=(-r)
    elif [[ -b "${f_old}" ]]
    then
      f_source="${f_old}"
    else
      # Recorded member that is absent right now - resolve its devid.
      f_devid=$(btrfs filesystem show --raw "${f_mnt}" 2>/dev/null | \
        awk -v p="${f_old}" '$1 == "devid" && $NF == p {print $2; exit}')
      [[ -n "${f_devid}" ]] || \
        f_json_error "Source ${f_old} is no block device and no recorded member of ${f_mnt}. Pass the devid shown by 'btrfs filesystem show ${f_mnt}'."
      f_source="${f_devid}"
      f_opts=(-r)
    fi
    if [[ "${f_source}" == "${f_old}" ]]
    then
      f_log "Replacing ${f_old} with ${f_new} on ${f_mnt}"
    else
      f_log "Replacing missing member devid ${f_source} (recorded as ${f_old}) with ${f_new} on ${f_mnt}"
    fi
    if ! f_out=$(btrfs replace start "${f_opts[@]}" "${f_source}" "${f_new}" "${f_mnt}" 2>&1)
    then
      f_out="${f_out//$'\n'/ }"
      f_json_error "btrfs replace failed: ${f_out}"
    fi
    f_log "Waiting for replace to finish..."
    # While a replace runs, `btrfs replace status` polls internally and only
    # returns when it ends - so every call is wrapped in `timeout`: while the
    # replace is alive we get progress lines (backspace/carriage-return
    # separated, normalized by f_replace_status_line), once it is done the
    # command returns by itself with a final line that says "finished on"
    # or "canceled on". A canceled replace (ENOSPC on a nearly full
    # filesystem) must never be reported as success.
    local f_status="" f_wait=0
    while true
    do
      f_status=$(f_replace_status_line "${f_mnt}" 25)
      [[ "${f_status}" == *"finished on"* ]] && break
      [[ "${f_status}" == *"canceled on"* ]] && break
      if [[ "${f_status}" == *"% done"* ]]
      then
        f_log "${f_status}"
      elif [[ "${f_wait}" -ge 120 ]]
      then
        f_json_error "btrfs replace did not start: ${f_status:-no status}"
      fi
      f_wait=$(( f_wait + 30 ))
      sleep 30
    done
    if [[ "${f_status}" == *"canceled on"* ]]
    then
      f_json_error "btrfs replace was canceled: ${f_status} (a nearly full filesystem fails with ENOSPC - check 'dmesg | grep -i btrfs', free space and start again)"
    fi
    # Error counters are part of the final status line; anything above zero
    # means the target disk (write errs) or both mirrors (uncorr. reads)
    # have a problem - never report that as a clean replace.
    local f_werr f_rerr
    f_werr=$(grep -oE '[0-9]+ write errs' <<< "${f_status}" | awk '{print $1}' || true)
    f_rerr=$(grep -oE '[0-9]+ uncorr' <<< "${f_status}" | awk '{print $1}' || true)
    if [[ "${f_werr:-0}" -gt 0 ]] || [[ "${f_rerr:-0}" -gt 0 ]]
    then
      f_json_error "btrfs replace finished with errors: ${f_status}"
    fi
    # Leftover single/dup block groups are not converted by a dev-replace.
    # Convert them to RAID1 in the background so the replace job can finish
    # and the WebUI does not block for hours. The page locks/refreshes while
    # the detached balance runs.
    local f_bdf_rep
    f_bdf_rep=$(btrfs filesystem df "${f_mnt}" 2>/dev/null || true)
    if [[ -n "${f_bdf_rep}" ]] && \
       echo "${f_bdf_rep}" | grep -qE '^(Data|Metadata|System),[[:space:]]*(single|dup)' && \
       echo "${f_bdf_rep}" | grep -qE '^(Data|Metadata|System),[[:space:]]*RAID1'
    then
      local f_rep_uuid8 f_rep_self
      f_rep_uuid8=$(btrfs filesystem show "${f_mnt}" 2>/dev/null | \
        grep -m1 -oE '[0-9a-f]{8}' | head -1)
      f_rep_self=$(readlink -f "$0")
      f_log "Converting remaining single/dup chunks to RAID1 in background..."
      systemd-run --unit="symbios-btrfs-balance-auto-${f_rep_uuid8:-$$}" \
        --collect --no-block </dev/null >/dev/null 2>&1 /bin/bash -c "btrfs balance start -dconvert=raid1 -mconvert=raid1 -sconvert=raid1 '${f_mnt}'" || true
      f_json_ok "\"message\":$(printf 'Device replaced: %s. Converting remaining single/dup chunks to RAID1 in the background (may take hours).' "${f_status}" | f_json_escape)"
    else
      f_json_ok "\"message\":$(printf 'Device replaced: %s' "${f_status}" | f_json_escape)"
    fi
    ;;

  add)
    f_need_btrfs
    local f_mnt="${1:-}" f_dev="${2:-}" f_out
    [[ -z "${f_mnt}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 add <mountpoint> <device>"
    if ! f_out=$(btrfs device add "${f_dev}" "${f_mnt}" 2>&1)
    then
      f_out="${f_out//$'\n'/ }"
      f_json_error "btrfs device add failed: ${f_out}"
    fi
    f_log "Rebalancing after add (may take a while)..."
    # -sconvert=raid1 matters: System chunks are created as "single" by
    # some kernels and would otherwise stay without a mirror forever.
    if ! f_out=$(btrfs balance start -dconvert=raid1 -mconvert=raid1 -sconvert=raid1 \
      "${f_mnt}" 2>&1)
    then
      f_out="${f_out//$'\n'/ }"
      f_json_error "Device added, but the rebalance to raid1 failed: ${f_out}"
    fi
    f_json_ok '"message":"Device added and balanced to raid1."'
    ;;

  remove)
    # No balance needed afterwards: btrfs relocates the removed
    # device's extents onto the remaining devices by itself.
    f_need_btrfs
    local f_mnt="${1:-}" f_dev="${2:-}" f_out
    [[ -z "${f_mnt}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 remove <mountpoint> <device>"
    if ! f_out=$(btrfs device remove "${f_dev}" "${f_mnt}" 2>&1)
    then
      # Flatten btrfs' multi-line output: the JSON escape of this script
      # only covers a single line.
      f_out="${f_out//$'\n'/ }"
      # A RAID1 filesystem with two members cannot shrink to one: btrfs
      # refuses before it moves any data ("unable to go below two devices
      # on raid1"). Swapping a disk is a replace, not a remove - the
      # profile needs a second device at all times.
      if grep -qi "unable to go below two devices" <<< "${f_out}"
      then
        f_json_error "btrfs refuses to shrink ${f_mnt} to a single device: a raid1 filesystem needs at least two. To swap a disk, prepare the new disk as a member and use Replace a Disk (btrfs replace). btrfs said: ${f_out}"
      fi
      # Relocation to the remaining devices fails when they have no room
      # for the moved extents; keep btrfs' own wording.
      f_json_error "btrfs device remove failed: ${f_out}"
    fi
    f_json_ok '"message":"Device removed."'
    ;;

  scrub)
    f_need_btrfs
    local f_mnt="${1:-}" f_op="${2:-status}"
    [[ -z "${f_mnt}" ]] && f_json_error "Usage: $0 scrub <mountpoint> [start|cancel|status]"
    case "${f_op}" in
      start)
        local f_started f_out
        f_started=$(date -u +%FT%TZ)
        if ! f_out=$(btrfs scrub start "${f_mnt}" 2>&1)
        then
          f_out="${f_out//$'\n'/ }"
          f_json_error "scrub start failed: ${f_out}"
        fi
        # Record the result when the scrub ends, so a manual scrub counts for
        # the monthly freshness check instead of leaving the old state behind.
        f_scrub_record_start "${f_mnt}" "${f_started}"
        f_json_ok '"message":"Scrub started - the result is recorded automatically when it finishes."'
        ;;
      cancel)
        btrfs scrub cancel "${f_mnt}" 2>&1 || f_json_error "scrub cancel failed"
        f_json_ok '"message":"Scrub cancelled."'
        ;;
      record)
        # Internal: started detached by f_scrub_record_start.
        f_scrub_record "${f_mnt}" "${3:-$(date -u +%FT%TZ)}"
        ;;
      *)
        btrfs scrub status "${f_mnt}" 2>&1 || f_json_error "scrub status failed"
        ;;
    esac
    ;;

  balance)
    f_need_btrfs
    local f_mnt="${1:-}" f_out
    [[ -z "${f_mnt}" ]] && f_json_error "Usage: $0 balance <mountpoint>"
    # Convert every profile, System included: those chunks are created as
    # "single" by some kernels and stay unmirrored until a balance names
    # them explicitly.
    if ! f_out=$(btrfs balance start -dconvert=raid1 -mconvert=raid1 -sconvert=raid1 \
      "${f_mnt}" 2>&1)
    then
      f_out="${f_out//$'\n'/ }"
      f_json_error "btrfs balance failed: ${f_out} (the conversion needs unallocated space on every member - on a nearly full filesystem free space first and start again)"
    fi
    f_json_ok '"message":"Balance finished."'
    ;;

  locate)
    local f_dev="${1:-}" f_secs="${2:-30}"
    [[ -z "${f_dev}" ]] && f_json_error "Usage: $0 locate <device> [seconds]"
    [[ "${f_dev}" == /dev/* ]] || f_json_error "Invalid device path"
    [[ "${f_secs}" =~ ^[0-9]+$ ]] || f_secs=30
    [[ "${f_secs}" -gt 120 ]] && f_secs=120
    f_log "Reading ${f_dev} for ${f_secs}s - watch the activity LED or listen"
    timeout "${f_secs}" dd "if=${f_dev}" of=/dev/null bs=1M iflag=direct 2>&1 | tail -2 || true
    f_json_ok '"message":"Locate read finished."'
    ;;

  help|-h|--help)
    f_usage
    ;;

  *)
    f_json_error "Usage: $0 {status|replace|add|remove|scrub|balance|locate}"
    ;;
  esac
}

f_main "$@"
