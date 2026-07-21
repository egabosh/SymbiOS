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

# docs:
#   short_description: Manage /home partition (create, encrypt, mount)
#   description: Creates, copies, optionally encrypts and mounts a dedicated /home partition. All operations output JSON.
#   author: SymbiOS Contributors
#   version: '1.0'
#   license: GPLv3
#   copyright: Copyright 2026, SymbiOS Contributors
#   min_ansible_version: '2.11'
#   platforms:
#   - name: Debian
#     versions:
#     - '13'
#   category: Disk / Management
#   actions:
#   - name: list
#     command: /usr/local/sbin/symbios-home-partition.sh list
#     description: List block devices
#   - name: status
#     command: /usr/local/sbin/symbios-home-partition.sh status
#     description: Show /home mount and LUKS status
#   - name: setup
#     command: /usr/local/sbin/symbios-home-partition.sh setup <device> [encrypt=yes] [password=<pass>]
#     description: Format, optionally encrypt, and mount a disk as /home
#   - name: umount
#     command: /usr/local/sbin/symbios-home-partition.sh umount
#     description: Unmount /home and close LUKS volume

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

json_escape() {
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null
}

json_error() {
  local msg="$1"
  printf '{"ok":false,"error":%s}\n' "$(echo "$msg" | json_escape)"
  exit 1
}

json_ok() {
  local data="$1"
  printf '{"ok":true,%s}\n' "$data"
}

# ---------------------------------------------------------------------------
# action: list
# ---------------------------------------------------------------------------

action_list() {
  local raw
  raw=$(lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,UUID,TRAN,RM 2>&1) || \
    json_error "lsblk failed: $raw"
  echo "$raw"
}

# ---------------------------------------------------------------------------
# action: status
# ---------------------------------------------------------------------------

action_status() {
  local home_device="" home_fstype="" home_size="" home_used="" home_avail=""
  local luks_name="" luks_device="" luks_open="false" needs_unlock="false"

  # What is /home mounted on?
  local df_out
  df_out=$(df -hT /home 2>/dev/null | tail -1) || true
  if [ -n "$df_out" ]; then
    local parts
    parts=($df_out)
    if [ ${#parts[@]} -ge 7 ]; then
      home_device="${parts[0]}"
      home_fstype="${parts[1]}"
      home_size="${parts[2]}"
      home_used="${parts[3]}"
      home_avail="${parts[4]}"
    fi
  fi

  # Check LUKS in block device tree
  local lsblk_out
  lsblk_out=$(lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT,UUID 2>/dev/null) || true
  if [ -n "$lsblk_out" ]; then
    local found
    found=$(echo "$lsblk_out" | python3 -c "
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
    if [ -n "$found" ]; then
      luks_name=$(echo "$found" | head -1)
      local luks_uuid
      luks_uuid=$(echo "$found" | tail -1)
      luks_device="/dev/$luks_name"

      # Check if LUKS is open
      local cs_out
      cs_out=$(cryptsetup status "$luks_name" 2>/dev/null | head -1) || true
      if echo "$cs_out" | grep -q "is active"; then
        luks_open="true"
      elif echo "$cs_out" | grep -qi "not found"; then
        needs_unlock="true"
      fi
    fi
  fi

  # Also check mapper for open LUKS
  if [ "$luks_open" = "false" ]; then
    if ls /dev/mapper/ 2>/dev/null | grep -qE 'home|luks'; then
      luks_open="true"
    fi
  fi

  cat <<EOF
"home_device":"$home_device",
"home_fstype":"$home_fstype",
"home_size":"$home_size",
"home_used":"$home_used",
"home_avail":"$home_avail",
"luks_name":"$luks_name",
"luks_device":"$luks_device",
"luks_open":$luks_open,
"needs_unlock":$needs_unlock
EOF
}

# ---------------------------------------------------------------------------
# action: setup
# ---------------------------------------------------------------------------

action_setup() {
  local device="${1:-}"
  local encrypt="${2:-no}"
  local password="${3:-}"

  # --- Validation ----------------------------------------------------------
  [ -z "$device" ] && json_error "No device selected"
  [[ "$device" == /dev/* ]] || json_error "Invalid device path"
  [ "$encrypt" = "yes" ] && [ -z "$password" ] && json_error "Password required for LUKS encryption"

  # Safety: not the root device
  local root_dev
  root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || true
  if [ -n "$root_dev" ]; then
    if [[ "$device" == *"$root_dev"* ]] || [[ "$root_dev" == *"$device"* ]]; then
      json_error "Cannot format the root device!"
    fi
  fi

  # Safety: not mounted (except as /home itself)
  local cur_mount
  cur_mount=$(findmnt -n -o TARGET "$device" 2>/dev/null) || true
  if [ -n "$cur_mount" ]; then
    if [ "$cur_mount" = "/home" ]; then
      json_error "This device is already mounted as /home"
    fi
    json_error "Device is mounted at $cur_mount. Unmount it first."
  fi

  # Size check
  local home_size disk_size
  home_size=$(du -sb /home/ 2>/dev/null | awk '{print $1}') || home_size=0
  disk_size=$(blockdev --getsize64 "$device" 2>/dev/null) || disk_size=0

  if [ "$home_size" -eq 0 ] 2>/dev/null; then
    json_error "Could not determine /home size"
  fi
  if [ "$disk_size" -eq 0 ] 2>/dev/null; then
    json_error "Could not determine disk size"
  fi

  # LUKS metadata overhead ~16MB, ext4 ~1%, add 5% safety margin
  local overhead=$(( 16 * 1024 * 1024 ))
  local home_margin=$(( home_size / 20 ))
  [ "$home_margin" -gt "$overhead" ] && overhead=$home_margin
  local needed=$(( home_size + overhead ))

  if [ "$disk_size" -lt "$needed" ]; then
    local home_gb disk_gb needed_gb
    home_gb=$(python3 -c "print(f'{$home_size/1024**3:.1f}')")
    disk_gb=$(python3 -c "print(f'{$disk_size/1024**3:.1f}')")
    needed_gb=$(python3 -c "print(f'{$needed/1024**3:.1f}')")
    json_error "Disk too small! /home is ${home_gb}G but disk is only ${disk_gb}G. Need at least ${needed_gb}G."
  fi

  # --- Execute setup -------------------------------------------------------
  local luks_name="home-luks"
  local target

  # Unmount if mounted anywhere
  umount "$device" 2>/dev/null || true

  if [ "$encrypt" = "yes" ]; then
    echo "$password" | cryptsetup luksFormat --batch-mode "$device" || \
      json_error "LUKS format failed"
    echo "$password" | cryptsetup open "$device" "$luks_name" || \
      json_error "LUKS open failed"
    target="/dev/mapper/$luks_name"
  else
    target="$device"
  fi

  # Format as ext4
  mkfs.ext4 -F "$target" 2>&1 || json_error "mkfs.ext4 failed"

  # Mount temporarily and copy data
  mkdir -p /home.new
  mount "$target" /home.new || json_error "Mount /home.new failed"

  rsync -av --exclude=docker/var-lib-docker --exclude=docker/var-lib-containerd \
    --exclude='.trashed-*' /home/ /home.new/ 2>&1 || {
    umount /home.new 2>/dev/null || true
    json_error "rsync failed"
  }

  # Get UUID for fstab
  local uuid
  uuid=$(blkid -s UUID -o value "$device" 2>/dev/null) || \
    json_error "blkid failed"

  # Unmount old /home
  umount /home 2>/dev/null || true

  # Remove old /home contents if it was on root fs
  rm -rf /home/* 2>/dev/null || true

  # Update fstab: remove existing /home entry, add new one
  sed -i '\#.*[[:space:]]/home[[:space:]]#d' /etc/fstab
  echo "UUID=$uuid /home ext4 defaults,noatime 0 2" >> /etc/fstab

  # Mount new /home
  mount /home || json_error "Mount /home failed"

  # Store LUKS name for boot unlock
  if [ "$encrypt" = "yes" ]; then
    echo "$luks_name" > /config/.luks-name 2>/dev/null || true
  fi

  json_ok '"message":"Disk setup complete. /home is now on the new partition."'
}

# ---------------------------------------------------------------------------
# action: umount
# ---------------------------------------------------------------------------

action_umount() {
  umount /home 2>/dev/null || true
  cryptsetup close home-luks 2>/dev/null || true
  json_ok '"message":"/home unmounted and LUKS volume closed."'
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

ACTION="${1:-}"
shift 2>/dev/null || true

case "$ACTION" in
  list)
    action_list
    ;;
  status)
    printf '{'
    action_status
    printf '}\n'
    ;;
  setup)
    action_setup "$@"
    ;;
  umount)
    action_umount
    ;;
  *)
    json_error "Usage: $0 {list|status|setup <device> [encrypt=yes] [password=pass]|umount}"
    ;;
esac
