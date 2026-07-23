#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

# symbios-home-partition.sh — Manage /home partition (create, encrypt, mount)
# All operations output JSON.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function f_json_escape {
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null
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

# ---------------------------------------------------------------------------
# action: list
# ---------------------------------------------------------------------------

function f_action_list {
  local f_raw
  f_raw=$(lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,UUID,TRAN,RM 2>&1) || \
    f_json_error "lsblk failed: $f_raw"
  echo "$f_raw"
}

# ---------------------------------------------------------------------------
# action: status
# ---------------------------------------------------------------------------

function f_action_status {
  local f_home_device="" f_home_fstype="" f_home_size="" f_home_used="" f_home_avail=""
  local f_luks_name="" f_luks_device="" f_luks_open="false" f_needs_unlock="false"

  # What is /home mounted on?
  local f_df_out
  f_df_out=$(df -hT /home 2>/dev/null | tail -1) || true
  if [[ -n "$f_df_out" ]]
  then
    local f_parts
    f_parts=($f_df_out)
    if [[ ${#f_parts[@]} -ge 7 ]]
    then
      f_home_device="${f_parts[0]}"
      f_home_fstype="${f_parts[1]}"
      f_home_size="${f_parts[2]}"
      f_home_used="${f_parts[3]}"
      f_home_avail="${f_parts[4]}"
    fi
  fi

  # Check LUKS in block device tree
  local f_lsblk_out
  f_lsblk_out=$(lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT,UUID 2>/dev/null) || true
  if [[ -n "$f_lsblk_out" ]]
  then
    local f_found
    f_found=$(echo "$f_lsblk_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)

def scan(devs):
    name = ''
    fstype = ''
    uuid = ''
    for d in devs:
        ft = d.get('fstype') or ''
        if ft == 'crypto_LUKS':
            name = d.get('name','')
            uuid = d.get('uuid','')
            break
        children = d.get('children') or []
        if children:
            r = scan(children)
            if r:
                name, uuid = r
                break
    return (name, uuid) if name else None

result = scan(data.get('blockdevices', []))
if result:
    print(result[0])
    print(result[1])
" 2>/dev/null) || true
    if [[ -n "$f_found" ]]
    then
      f_luks_name=$(echo "$f_found" | head -1)
      local f_luks_uuid
      f_luks_uuid=$(echo "$f_found" | tail -1)
      f_luks_device="/dev/$f_luks_name"

      # Check if LUKS is open
      local f_cs_out
      f_cs_out=$(cryptsetup status "$f_luks_name" 2>/dev/null | head -1) || true
      if echo "$f_cs_out" | grep -q "is active"
      then
        f_luks_open="true"
      elif echo "$f_cs_out" | grep -qi "not found"
      then
        f_needs_unlock="true"
      fi
    fi
  fi

  # Also check mapper for open LUKS
  if [[ "$f_luks_open" == "false" ]]
  then
    if ls /dev/mapper/ 2>/dev/null | grep -qE 'home|luks'
    then
      f_luks_open="true"
    fi
  fi

  cat <<EOF
"home_device":"$f_home_device",
"home_fstype":"$f_home_fstype",
"home_size":"$f_home_size",
"home_used":"$f_home_used",
"home_avail":"$f_home_avail",
"luks_name":"$f_luks_name",
"luks_device":"$f_luks_device",
"luks_open":$f_luks_open,
"needs_unlock":$f_needs_unlock
EOF
}

# ---------------------------------------------------------------------------
# action: setup
# ---------------------------------------------------------------------------

function f_action_setup {
  local f_device="${1:-}"
  local f_encrypt="${2:-no}"
  local f_password="${3:-}"

  # Validation
  [[ -z "$f_device" ]] && f_json_error "No device selected"
  [[ "$f_device" == /dev/* ]] || f_json_error "Invalid device path"
  [[ "$f_encrypt" == "yes" ]] && [[ -z "$f_password" ]] && f_json_error "Password required for LUKS encryption"

  # Safety: not the root device
  local f_root_dev
  f_root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || true
  if [[ -n "$f_root_dev" ]]
  then
    if [[ "$f_device" == *"$f_root_dev"* ]] || [[ "$f_root_dev" == *"$f_device"* ]]
    then
      f_json_error "Cannot format the root device!"
    fi
  fi

  # Safety: not mounted (except as /home itself)
  local f_cur_mount
  f_cur_mount=$(findmnt -n -o TARGET "$f_device" 2>/dev/null) || true
  if [[ -n "$f_cur_mount" ]]
  then
    if [[ "$f_cur_mount" == "/home" ]]
    then
      f_json_error "This device is already mounted as /home"
    fi
    f_json_error "Device is mounted at $f_cur_mount. Unmount it first."
  fi

  # Size check
  local f_home_size f_disk_size
  f_home_size=$(du -sb /home/ 2>/dev/null | awk '{print $1}') || f_home_size=0
  f_disk_size=$(blockdev --getsize64 "$f_device" 2>/dev/null) || f_disk_size=0

  if [[ "$f_home_size" -eq 0 ]] 2>/dev/null
  then
    f_json_error "Could not determine /home size"
  fi
  if [[ "$f_disk_size" -eq 0 ]] 2>/dev/null
  then
    f_json_error "Could not determine disk size"
  fi

  # LUKS metadata overhead ~16MB, ext4 ~1%, add 5% safety margin
  local f_overhead=$(( 16 * 1024 * 1024 ))
  local f_home_margin=$(( f_home_size / 20 ))
  [[ "$f_home_margin" -gt "$f_overhead" ]] && f_overhead=$f_home_margin
  local f_needed=$(( f_home_size + f_overhead ))

  if [[ "$f_disk_size" -lt "$f_needed" ]]
  then
    local f_home_gb f_disk_gb f_needed_gb
    f_home_gb=$(python3 -c "print(f'{$f_home_size/1024**3:.1f}')")
    f_disk_gb=$(python3 -c "print(f'{$f_disk_size/1024**3:.1f}')")
    f_needed_gb=$(python3 -c "print(f'{$f_needed/1024**3:.1f}')")
    f_json_error "Disk too small! /home is ${f_home_gb}G but disk is only ${f_disk_gb}G. Need at least ${f_needed_gb}G."
  fi

  # Execute setup
  local f_luks_name="home-luks"
  local f_target

  # Unmount if mounted anywhere
  umount "$f_device" 2>/dev/null || true

  if [[ "$f_encrypt" == "yes" ]]
  then
    echo "$f_password" | cryptsetup luksFormat --batch-mode "$f_device" || \
      f_json_error "LUKS format failed"
    echo "$f_password" | cryptsetup open "$f_device" "$f_luks_name" || \
      f_json_error "LUKS open failed"
    f_target="/dev/mapper/$f_luks_name"
  else
    f_target="$f_device"
  fi

  # Format as ext4
  mkfs.ext4 -F "$f_target" 2>&1 || f_json_error "mkfs.ext4 failed"

  # Mount temporarily and copy data
  mkdir -p /home.new
  mount "$f_target" /home.new || f_json_error "Mount /home.new failed"

  rsync -av --exclude=docker/var-lib-docker --exclude=docker/var-lib-containerd \
    --exclude='.trashed-*' /home/ /home.new/ 2>&1 || {
    umount /home.new 2>/dev/null || true
    f_json_error "rsync failed"
  }

  # Get UUID for fstab
  local f_uuid
  f_uuid=$(blkid -s UUID -o value "$f_device" 2>/dev/null) || \
    f_json_error "blkid failed"

  # Unmount old /home
  umount /home 2>/dev/null || true

  # Remove old /home contents if it was on root fs
  rm -rf /home/* 2>/dev/null || true

  # Update fstab: remove existing /home entry, add new one
  sed -i '\#.*[[:space:]]/home[[:space:]]#d' /etc/fstab
  if [[ "$f_encrypt" == "yes" ]]
  then
    echo "/dev/mapper/$f_luks_name /home ext4 defaults,noatime 0 2" >> /etc/fstab
  else
    echo "UUID=$f_uuid /home ext4 defaults,noatime 0 2" >> /etc/fstab
  fi

  # Mount new /home
  mount /home || f_json_error "Mount /home failed"

  # Store LUKS name for boot unlock
  if [[ "$f_encrypt" == "yes" ]]
  then
    echo "$f_luks_name" > /config/.luks-name 2>/dev/null || true
  fi

  f_json_ok '"message":"Disk setup complete. /home is now on the new partition."'
}

# ---------------------------------------------------------------------------
# action: umount
# ---------------------------------------------------------------------------

function f_action_umount {
  umount /home 2>/dev/null || true
  cryptsetup close home-luks 2>/dev/null || true
  f_json_ok '"message":"/home unmounted and LUKS volume closed."'
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

g_action="${1:-}"
shift 2>/dev/null || true

case "$g_action" in
  list)
    f_action_list
    ;;
  status)
    printf '{'
    f_action_status
    printf '}\n'
    ;;
  setup)
    f_action_setup "$@"
    ;;
  umount)
    f_action_umount
    ;;
  *)
    f_json_error "Usage: $0 {list|status|setup <device> [encrypt=yes] [password=pass]|umount}"
    ;;
esac
