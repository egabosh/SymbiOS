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

# symbios-raid-md.sh - Manage mdadm RAID arrays (status, replace, grow, create, locate)
#
# Actions:
#   status [--json]             Show arrays + health (JSON by default)
#   replace <array> <old> <new> Replace a member (fail/remove/add, waits for sync)
#   add <array> <device>        Add a spare/member to an array
#   remove <array> <device>     Remove a failed/spare member
#   grow <array>                Grow array + filesystem after adding members
#   create <level> <dev...>      Create new array (raid1/raid5) with ext4
#   help                        Show this help
#
# Disk location (identify by activity LED) lives on the Data Disk page.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <action> [args...]

Manage mdadm RAID arrays (status, replace, grow, create, locate). All
destructive actions run in the foreground so the WebUI exec modal can
stream progress; replace/grow may take hours on large arrays.

Actions:
  status [--json]             Show arrays + health (JSON by default)
  replace <array> <old> <new>
                              Replace a member: fail + remove <old>,
                              add <new>, wait for resync
  add <array> <device>        Add a spare/member to an array
  remove <array> <device>     Remove a failed or spare member
  grow <array>                Grow array and filesystem after adding members
  create <level> <dev...>
                              Create a new array (level raid1/raid5,
                              always ext4) from whole disks or partitions
  help                        Show this help

Disk location lives on the Data Disk page (Locate a Disk card).

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

function f_need_mdadm {
  command -v mdadm >/dev/null 2>&1 || f_json_error "mdadm is not installed"
}

function f_guard_device {
  # Refuse members that are mounted, LUKS holders or active swap.
  local f_dev="$1"
  [[ "${f_dev}" == /dev/* ]] || f_json_error "Invalid device path: ${f_dev}"
  local f_mount
  f_mount=$(findmnt -n -o TARGET "${f_dev}" 2>/dev/null || true)
  [[ -n "${f_mount}" ]] && f_json_error "${f_dev} is mounted at ${f_mount}. Unmount it first."
  local f_fs
  f_fs=$(blkid -s TYPE -o value "${f_dev}" 2>/dev/null || true)
  if [[ "${f_fs}" == "crypto_LUKS" ]]
  then
    f_json_error "${f_dev} holds LUKS data - unlock/wipe it first."
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${f_dev}"
  then
    f_json_error "${f_dev} is active swap - swap it off first."
  fi
}

function f_main {
  g_action="${1:-}"
  shift 2>/dev/null || true

  case "${g_action}" in

  status)
    f_need_mdadm
    local f_out="" f_first="yes" f_mdstat
    f_mdstat=$(cat /proc/mdstat 2>/dev/null || true)
    while IFS= read -r f_line
    do
      if [[ "${f_line}" =~ ^(md[0-9]+)[[:space:]]*:[[:space:]]*([a-z]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]
      then
        local f_name="/dev/${BASH_REMATCH[1]}" f_state="${BASH_REMATCH[2]}"
        local f_level="${BASH_REMATCH[3]}" f_rest="${BASH_REMATCH[4]}"
        local f_members="" f_tok
        for f_tok in ${f_rest}
        do
          [[ "${f_tok}" == *\[*\]* ]] || continue
          f_tok="${f_tok%%\[*}"
          [[ -n "${f_members}" ]] && f_members="${f_members}, "
          f_members="${f_members}$(printf '/dev/%s' "${f_tok}" | f_json_escape)"
        done
        local f_mount f_sync f_detail
        f_mount=$(findmnt -n -o TARGET "${f_name}" 2>/dev/null || true)
        f_sync=$(grep -oE '(resync|recovery|reshape) *= *[0-9.]+%' /proc/mdstat 2>/dev/null | head -1 || true)
        f_detail=$(mdadm --detail "${f_name}" 2>/dev/null | grep -E 'State|Active Devices|Failed Devices|Spare Devices' | tr '\n' ';' || true)
        [[ "${f_first}" == "yes" ]] || f_out="${f_out}, "
        f_first="no"
        f_out="${f_out}{\"device\":$(printf '%s' "${f_name}" | f_json_escape)"
        f_out="${f_out},\"state\":$(printf '%s' "${f_state}" | f_json_escape)"
        f_out="${f_out},\"level\":$(printf '%s' "${f_level}" | f_json_escape)"
        f_out="${f_out},\"mountpoint\":$(printf '%s' "${f_mount}" | f_json_escape)"
        f_out="${f_out},\"sync\":$(printf '%s' "${f_sync}" | f_json_escape)"
        f_out="${f_out},\"detail\":$(printf '%s' "${f_detail}" | f_json_escape)"
        f_out="${f_out},\"members\":[${f_members}]}"
      fi
    done < <(echo "${f_mdstat}")
    if [[ "$*" == *--json* ]] || [[ -z "$*" ]]
    then
      f_json_ok "\"arrays\":[${f_out}]"
    else
      echo "${f_mdstat}"
    fi
    ;;

  replace)
    f_need_mdadm
    local f_array="${1:-}" f_old="${2:-}" f_new="${3:-}"
    [[ -z "${f_array}" || -z "${f_old}" || -z "${f_new}" ]] && \
      f_json_error "Usage: $0 replace <array> <old-device> <new-device>"
    f_guard_device "${f_new}"
    f_log "Marking ${f_old} as faulty in ${f_array}"
    mdadm "${f_array}" --fail "${f_old}" 2>&1 || true
    f_log "Removing ${f_old} from ${f_array}"
    mdadm "${f_array}" --remove "${f_old}" 2>&1 || \
      f_json_error "Could not remove ${f_old} from ${f_array}"
    f_log "Adding ${f_new} to ${f_array}"
    mdadm "${f_array}" --add "${f_new}" 2>&1 || \
      f_json_error "Could not add ${f_new} to ${f_array}"
    f_log "Waiting for resync (this may take hours)..."
    while grep -qE '(resync|recovery|reshape)' /proc/mdstat 2>/dev/null
    do
      grep -oE '(resync|recovery|reshape) *= *[0-9.]+%' /proc/mdstat 2>/dev/null | head -1 || true
      sleep 30
    done
    f_log "Replace complete"
    f_json_ok '"message":"Disk replaced and resync finished."'
    ;;

  add)
    f_need_mdadm
    local f_array="${1:-}" f_dev="${2:-}"
    [[ -z "${f_array}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 add <array> <device>"
    f_guard_device "${f_dev}"
    mdadm "${f_array}" --add "${f_dev}" 2>&1 || \
      f_json_error "Could not add ${f_dev} to ${f_array}"
    f_json_ok '"message":"Device added to array."'
    ;;

  remove)
    f_need_mdadm
    local f_array="${1:-}" f_dev="${2:-}"
    [[ -z "${f_array}" || -z "${f_dev}" ]] && \
      f_json_error "Usage: $0 remove <array> <device>"
    mdadm "${f_array}" --fail "${f_dev}" 2>&1 || true
    mdadm "${f_array}" --remove "${f_dev}" 2>&1 || \
      f_json_error "Could not remove ${f_dev} from ${f_array}"
    f_json_ok '"message":"Device removed from array."'
    ;;

  grow)
    f_need_mdadm
    local f_array="${1:-}"
    [[ -z "${f_array}" ]] && f_json_error "Usage: $0 grow <array>"
    local f_ndev
    f_ndev=$(mdadm --detail "${f_array}" 2>/dev/null | grep -cE '/dev/sd|/dev/nvme|/dev/vd' || true)
    f_log "Growing ${f_array} to use all space (${f_ndev} devices)"
    mdadm --grow "${f_array}" --size=max 2>&1 || \
      f_json_error "mdadm --grow failed"
    local f_mount f_fs
    f_mount=$(findmnt -n -o TARGET "${f_array}" 2>/dev/null || true)
    if [[ -n "${f_mount}" ]]
    then
      f_fs=$(findmnt -n -o FSTYPE "${f_array}" 2>/dev/null || true)
      if [[ "${f_fs}" == "ext4" ]]
      then
        resize2fs "${f_array}" 2>&1 || f_json_error "resize2fs failed"
      elif [[ "${f_fs}" == "btrfs" ]]
      then
        btrfs filesystem resize max "${f_mount}" 2>&1 || f_json_error "btrfs resize failed"
      fi
    fi
    f_json_ok '"message":"Array grown (filesystem resized where mounted)."'
    ;;

  create)
    # New arrays are always raid1/raid5 with ext4 (btrfs users take the
    # btrfs page, which keeps its own profiles - no mkfs choice needed).
    f_need_mdadm
    local f_level="${1:-}"
    shift 1 2>/dev/null || f_json_error "Usage: $0 create <raid1|raid5> <dev...>"
    [[ "$#" -ge 2 ]] || f_json_error "Need at least 2 devices"
    case "${f_level}" in
      raid1|raid5)
        ;;
      *)
        f_json_error "Level must be raid1 or raid5"
        ;;
    esac
    local f_dev
    for f_dev in "$@"
    do
      f_guard_device "${f_dev}"
    done
    local f_count=$#
    f_log "Creating ${f_level} array with ${f_count} devices (ext4)"
    mdadm --create /dev/md0 --level="${f_level//raid/}" \
      --raid-devices="${f_count}" "$@" 2>&1 || \
      f_json_error "mdadm --create failed"
    mkfs.ext4 -F /dev/md0 2>&1 || f_json_error "mkfs.ext4 failed"
    f_json_ok '"message":"RAID array /dev/md0 created (ext4).","device":"/dev/md0"'
    ;;

  help|-h|--help)
    f_usage
    ;;

  *)
    f_json_error "Usage: $0 {status|replace|add|remove|grow|create}"
    ;;
  esac
}

f_main "$@"
