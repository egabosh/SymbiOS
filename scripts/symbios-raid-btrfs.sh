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
#   replace <mnt> <old> <new>   Replace a member device
#   add <mnt> <device>          Add a device + rebalance
#   remove <mnt> <device>       Remove a device
#   scrub <mnt> [start|cancel|status]  Control data scrubbing
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
  replace <mnt> <old> <new>   Replace a member device
  add <mnt> <device>          Add a device and rebalance
  remove <mnt> <device>       Remove a device
  scrub <mnt> [start|cancel|status]
                              Control data scrubbing
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
    local f_b_label="" f_b_uuid="" f_b_missing="false" f_b_members=""
    f_btrfs_emit() {
      [[ -z "${f_b_uuid}" ]] && return 0
      local f_b_mount f_b_df f_b_data f_b_meta f_b_stats f_b_scrub
      local f_b_scrub_running="false" f_b_scrub_pct="-1"
      f_b_mount=$(findmnt -n -o TARGET "UUID=${f_b_uuid}" 2>/dev/null || true)
      f_b_df=""
      f_b_data="unknown"
      f_b_meta="unknown"
      f_b_stats="-"
      f_b_scrub="-"
      if [[ -n "${f_b_mount}" ]]
      then
        f_b_df=$(btrfs filesystem df "${f_b_mount}" 2>/dev/null || true)
        f_b_data=$(echo "${f_b_df}" | awk '/^Data, /{gsub(/:.*/,"",$2); print $2; exit}')
        f_b_meta=$(echo "${f_b_df}" | awk '/^Metadata, /{gsub(/:.*/,"",$2); print $2; exit}')
        [[ -z "${f_b_data}" ]] && f_b_data="unknown"
        [[ -z "${f_b_meta}" ]] && f_b_meta="unknown"
        f_b_stats=$(btrfs device stats "${f_b_mount}" 2>/dev/null | awk '
          /write_io_errs/   { g_w += $2 }
          /read_io_errs/    { g_r += $2 }
          /flush_io_errs/   { g_f += $2 }
          /corruption_errs/ { g_c += $2 }
          /generation_errs/ { g_g += $2 }
          END { print "w=" g_w+0 " r=" g_r+0 " f=" g_f+0 " c=" g_c+0 " g=" g_g+0 }')
        local f_b_scrub_raw
        f_b_scrub_raw=$(btrfs scrub status "${f_b_mount}" 2>/dev/null || true)
        f_b_scrub=$(echo "${f_b_scrub_raw}" | grep -E 'Status|Duration|Total' | tr '\n' ';' || true)
        # Running scrub: report percent = data_bytes_scrubbed / FS bytes
        # used (btrfs prints no percentage itself, only byte counters).
        if echo "${f_b_scrub_raw}" | grep -qi "running"
        then
          f_b_scrub_running="true"
          local f_b_done f_b_used_h f_b_used
          f_b_done=$(echo "${f_b_scrub_raw}" | grep -oE 'data_bytes_scrubbed: [0-9]+' | awk '{print $2; exit}')
          f_b_used_h=$(btrfs filesystem show "${f_b_uuid}" 2>/dev/null | \
            grep -oE 'FS bytes used [0-9.]+[KMGTPE]?i?B' | awk '{print $4; exit}')
          f_b_used=$(numfmt --from=iec "${f_b_used_h}" 2>/dev/null || echo 0)
          if [[ "${f_b_done:-0}" -gt 0 ]] 2>/dev/null && [[ "${f_b_used:-0}" -gt 0 ]] 2>/dev/null
          then
            f_b_scrub_pct=$(( f_b_done * 100 / f_b_used ))
            [[ "${f_b_scrub_pct}" -gt 100 ]] && f_b_scrub_pct=100
          else
            f_b_scrub_pct=0
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
      f_out="${f_out},\"device_stats\":$(printf '%s' "${f_b_stats}" | f_json_escape)"
      f_out="${f_out},\"scrub\":$(printf '%s' "${f_b_scrub}" | f_json_escape)"
      f_out="${f_out},\"scrub_running\":${f_b_scrub_running}"
      f_out="${f_out},\"scrub_percent\":${f_b_scrub_pct}"
      f_out="${f_out},\"degraded\":${f_b_missing}"
      f_out="${f_out},\"members\":[${f_b_members}]}"
      f_b_label="" f_b_uuid="" f_b_missing="false" f_b_members=""
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
      elif [[ "${f_line}" == *"Some devices missing"* ]]
      then
        f_b_missing="true"
      elif [[ "${f_line}" == *"path /dev/"* ]]
      then
        local f_b_path="/dev/${f_line##*path /dev/}"
        f_b_path="${f_b_path%% *}"
        [[ -n "${f_b_members}" ]] && f_b_members="${f_b_members}, "
        f_b_members="${f_b_members}$(printf '%s' "${f_b_path}" | f_json_escape)"
      fi
    done < <(btrfs filesystem show 2>/dev/null || true)
    f_btrfs_emit
    f_json_ok "\"filesystems\":[${f_out}]"
    ;;

  replace)
    f_need_btrfs
    local f_mnt="${1:-}" f_old="${2:-}" f_new="${3:-}"
    [[ -z "${f_mnt}" || -z "${f_old}" || -z "${f_new}" ]] && \
      f_json_error "Usage: $0 replace <mountpoint> <old-device> <new-device>"
    [[ -e "${f_new}" ]] || f_json_error "New device ${f_new} does not exist"
    f_log "Replacing ${f_old} with ${f_new} on ${f_mnt}"
    btrfs replace start "${f_old}" "${f_new}" "${f_mnt}" 2>&1 || \
      f_json_error "btrfs replace failed"
    f_log "Waiting for replace to finish..."
    while btrfs replace status "${f_mnt}" 2>/dev/null | grep -qi "in progress"
    do
      btrfs replace status "${f_mnt}" 2>/dev/null | head -3 || true
      sleep 30
    done
    f_json_ok '"message":"Device replaced."'
    ;;

  add)
    f_need_btrfs
    local f_mnt="${1:-}" f_dev="${2:-}"
    [[ -z "${f_mnt}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 add <mountpoint> <device>"
    btrfs device add "${f_dev}" "${f_mnt}" 2>&1 || \
      f_json_error "btrfs device add failed"
    f_log "Rebalancing after add (may take a while)..."
    btrfs balance start -dconvert=raid1 -mconvert=raid1 "${f_mnt}" 2>&1 || true
    f_json_ok '"message":"Device added and balanced to raid1."'
    ;;

  remove)
    # No balance needed afterwards: btrfs relocates the removed
    # device's extents onto the remaining devices by itself.
    f_need_btrfs
    local f_mnt="${1:-}" f_dev="${2:-}"
    [[ -z "${f_mnt}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 remove <mountpoint> <device>"
    btrfs device remove "${f_dev}" "${f_mnt}" 2>&1 || \
      f_json_error "btrfs device remove failed (not enough space elsewhere?)"
    f_json_ok '"message":"Device removed."'
    ;;

  scrub)
    f_need_btrfs
    local f_mnt="${1:-}" f_op="${2:-status}"
    [[ -z "${f_mnt}" ]] && f_json_error "Usage: $0 scrub <mountpoint> [start|cancel|status]"
    case "${f_op}" in
      start)
        btrfs scrub start "${f_mnt}" 2>&1 || f_json_error "scrub start failed"
        f_json_ok '"message":"Scrub started."'
        ;;
      cancel)
        btrfs scrub cancel "${f_mnt}" 2>&1 || f_json_error "scrub cancel failed"
        f_json_ok '"message":"Scrub cancelled."'
        ;;
      *)
        btrfs scrub status "${f_mnt}" 2>&1 || f_json_error "scrub status failed"
        ;;
    esac
    ;;

  balance)
    f_need_btrfs
    local f_mnt="${1:-}"
    [[ -z "${f_mnt}" ]] && f_json_error "Usage: $0 balance <mountpoint>"
    btrfs balance start -dconvert=raid1 -mconvert=raid1 "${f_mnt}" 2>&1 || \
      f_json_error "balance failed"
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
