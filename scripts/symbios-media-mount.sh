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

# symbios-media-mount.sh - Mount the optional SYMBIOS_MEDIA volume at boot.
#
# Called from /etc/rc.local after /symbios is mounted (the LUKS keyfile
# lives there, so this helper cannot run before the data volume is up).
# Everything is label-triggered: LUKS label CRYPT_LUKS_SYMBIOS_MEDIA,
# filesystem label SYMBIOS_MEDIA. No matching device means no media
# volume - that is a normal state, not an error.
#
# Like everything at boot: never block, never fail the boot. All failures
# are warnings, exit code is always 0. Containers use
# bind.create_host_path=false, so a missing volume fails closed instead
# of serving empty libraries.

g_fs_label="SYMBIOS_MEDIA"
g_luks_label="CRYPT_LUKS_SYMBIOS_MEDIA"
g_mapper_base="symbios-media"
g_mountpoint="/symbios/media"
g_keyfile="/symbios/.keys/media-volume.key"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  echo "Usage: $(basename "$0")"
  echo ""
  echo "Mount the optional SYMBIOS_MEDIA volume (LUKS label"
  echo "${g_luks_label}, filesystem label ${g_fs_label}) at"
  echo "${g_mountpoint}. No matching device: silent no-op, exit 0."
  exit 0
fi
if [[ $# -gt 0 ]]
then
  echo "Unknown arguments (see --help)" >&2
  exit 0
fi

# Only the compat bind target is configurable (inventory media_compat_bind,
# empty by default). symbios-lib.sh runs fine here: /symbios is already
# mounted when rc.local reaches this helper.
g_compat=""
if [[ -r /symbios/git/SymbiOS/scripts/symbios-lib.sh ]]
then
  # shellcheck disable=SC1091
  source /symbios/git/SymbiOS/scripts/symbios-lib.sh 2>/dev/null || true
  if command -v f_symbios_var >/dev/null 2>&1
  then
    g_compat="$(f_symbios_var media_compat_bind "")"
    # The mount target follows the inventory media root (default
    # /symbios/media) so hosts with overrides mount the right place.
    if [[ -n "${g_media_root:-}" ]]
    then
      g_mountpoint="${g_media_root}"
    fi
  fi
fi

# Ensure the legacy compat bind and leave. Shared by the early exits so a
# reboot never loses the compat path while the primary mount is fine.
function f_compat_bind {
  [[ -n "${g_compat}" ]] || return 0
  mkdir -p "${g_compat}" 2>/dev/null || return 0
  mountpoint -q "${g_compat}" 2>/dev/null && return 0
  mount --bind "${g_mountpoint}" "${g_compat}" 2>/dev/null || \
    echo "WARN: compat bind ${g_mountpoint} -> ${g_compat} failed"
  return 0
}

if mountpoint -q "${g_mountpoint}" 2>/dev/null
then
  f_compat_bind
  exit 0
fi

# Open every LUKS partition carrying our label, numbered uniformly from 1
# (symbios-media-1, symbios-media-2, ...). Multi-device volumes (e.g. btrfs
# RAID1 on two LUKS partitions) need every member open; single disks are
# simply member 1, so setup and boot always agree on the names.
function f_open_luks {
  local f_dev f_idx=1 f_mapper
  while read -r f_dev
  do
    [[ -z "${f_dev}" ]] && continue
    f_mapper="${g_mapper_base}-${f_idx}"
    if [[ ! -b "/dev/mapper/${f_mapper}" ]]
    then
      if [[ ! -s "${g_keyfile}" ]]
      then
        echo "WARN: ${f_dev} needs a passphrase (no keyfile at ${g_keyfile}) - skipping media volume"
        return 1
      fi
      cryptsetup open --key-file "${g_keyfile}" "/dev/${f_dev}" "${f_mapper}" 2>/dev/null || {
        echo "WARN: could not open ${f_dev} as ${f_mapper} - skipping media volume"
        return 1
      }
    fi
    f_idx=$((f_idx + 1))
  done < <(lsblk -n -l -o FSTYPE,LABEL,NAME 2>/dev/null | \
    awk -v label="${g_luks_label}" '$1 == "crypto_LUKS" && $2 == label {print $3}')
  return 0
}

f_open_luks || exit 0
# A multi-device btrfs only assembles once all members are visible
btrfs device scan >/dev/null 2>&1 || true

if ! blkid -L "${g_fs_label}" >/dev/null 2>&1
then
  # No media filesystem anywhere (no LUKS label either, or unlock failed
  # with warnings above): optional volume simply absent.
  exit 0
fi

mkdir -p "${g_mountpoint}" 2>/dev/null || true
f_fs_type=$(blkid -s TYPE -o value "$(blkid -L "${g_fs_label}")" 2>/dev/null || true)
if [[ "${f_fs_type}" == "btrfs" ]]
then
  if ! mount -t btrfs -o relatime,noatime,commit=60,space_cache=v2 "LABEL=${g_fs_label}" "${g_mountpoint}" 2>/dev/null
  then
    # Normal mount failed (probably a missing member disk) - try degraded
    if mount -t btrfs -o relatime,noatime,commit=60,space_cache=v2,degraded "LABEL=${g_fs_label}" "${g_mountpoint}" 2>/dev/null
    then
      echo "WARN: ${g_mountpoint} mounted DEGRADED (member missing - replace disk, then scrub + balance)"
    else
      echo "WARN: ${g_mountpoint} mount failed"
      exit 0
    fi
  fi
else
  mount "LABEL=${g_fs_label}" "${g_mountpoint}" 2>/dev/null || {
    echo "WARN: ${g_mountpoint} mount failed"
    exit 0
  }
fi

f_compat_bind
exit 0
