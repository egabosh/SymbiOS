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

# symbios-media-partition.sh - Manage the optional SYMBIOS_MEDIA volume.
#
# The media volume holds the shared media libraries below /symbios/media
# on its own (optionally LUKS-encrypted) disk. Everything is identified by
# labels (LUKS: CRYPT_LUKS_SYMBIOS_MEDIA, filesystem: SYMBIOS_MEDIA), so
# the boot mount needs no fstab entry - see symbios-media-mount.sh.
#
# Unlike the data volume this never needs a reboot: after setup/adopt only
# the media consumers (navidrome, sftp-share, ...) pick up the new mount
# (recreate them via their playbook or docker compose up -d).
#
# Actions:
#   status                        Show /symbios/media mount + LUKS status (JSON)
#   setup <device> [encrypt=yes] [password-file=path]   Format + migrate media
#   adopt <device> [--copy] [--check]   Use existing fs/mapper as media volume
#   unlock <device> <password-file>   Open a LUKS device for inspection
#   lock <mapper|device>          Close an opened LUKS volume again
#   luks                          List LUKS devices + open state (JSON)
#   rollback                      Undo last migration, restore previous media
#   save-key <password-file>     Store the LUKS passphrase as boot keyfile
#   change-password <current-pw-file> <new-pw-file>   Change LUKS passphrase
#
# State file for rollback: /symbios/.symbios-media-migration.state

function f_usage {
  cat << EOF
Usage: $(basename "$0") <action> [args...]

Manage the optional SYMBIOS_MEDIA volume (labels SYMBIOS_MEDIA /
CRYPT_LUKS_SYMBIOS_MEDIA, mount /symbios/media, no fstab entry).

Actions:
  status                        Show mount + LUKS status (JSON)
  setup <device> [encrypt=yes] [password-file=path]
                                Format a disk/array and migrate media onto it
  adopt <device> [--copy] [--check]
                                Use an existing filesystem (or open LUKS
                                mapper) as media volume without formatting.
                                --copy migrates current media onto it,
                                --check only reports what would happen.
  unlock <device> <password-file>
                                Open a LUKS device for inspection (no
                                mount, no formatting)
  lock <mapper|device>          Close an opened LUKS volume again
  luks                          List LUKS devices + open state (JSON)
  rollback                      Undo the last migration
  save-key <password-file>     Store the LUKS passphrase as boot keyfile
  change-password <current-pw-file> <new-pw-file>
                                Change the LUKS passphrase
  help                          Show this help

State file for rollback: /symbios/.symbios-media-migration.state

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

# Labels used when creating LUKS partition and media filesystem.
# Boot and WebUI identify the volume by these labels (exact match only).
g_luks_label="CRYPT_LUKS_SYMBIOS_MEDIA"
g_data_label="SYMBIOS_MEDIA"

# Mount point and LUKS mapper name for the media volume
g_mountpoint="/symbios/media"
g_mapper_name="symbios-media"

# The data volume labels: a media setup target must never carry those
# (formatting one would destroy /symbios).
g_data_fs_label="SYMBIOS_DATA"
g_data_luks_label="CRYPT_LUKS_SYMBIOS_DATA"

f_state_file="/symbios/.symbios-media-migration.state"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

function f_log_ok {
  f_log "OK: $*"
}

function f_log_error {
  f_log "ERROR: $*"
}

function f_log_step {
  f_log "--- STEP: $* ---"
}

# Find the media LUKS device by exact label (never a foreign volume).
function f_find_luks {
  local f_dev
  f_dev=$(lsblk -n -l -o FSTYPE,LABEL,NAME 2>/dev/null | \
    awk -v label="$g_luks_label" \
      '$1 == "crypto_LUKS" && $2 == label {print $3; exit}')
  echo "$f_dev"
}

# Mount the media volume explicitly by device path (no fstab entry - the
# boot mounts by LABEL via symbios-media-mount.sh).
function f_mount_media {
  local f_dev="$1" f_fs="$2"
  mkdir -p "${g_mountpoint}" 2>/dev/null || true
  case "${f_fs}" in
    btrfs)
      mount -t btrfs -o relatime,noatime,commit=60,space_cache=v2 "${f_dev}" "${g_mountpoint}" || \
        mount -t btrfs -o relatime,noatime,commit=60,space_cache=v2,degraded "${f_dev}" "${g_mountpoint}"
      ;;
    ext4)
      # prjquota needs the quota+project mkfs features (setup formats that
      # way); adopted foreign filesystems may lack them - then plain mount.
      mount -t ext4 -o defaults,noatime,prjquota "${f_dev}" "${g_mountpoint}" 2>/dev/null || \
        mount -t ext4 -o defaults,noatime "${f_dev}" "${g_mountpoint}"
      ;;
    *)
      mount "${f_dev}" "${g_mountpoint}"
      ;;
  esac
}

# Rename our canonical labels on a retired device to non-canonical names
# (X-SYMBIOS_MEDIA fits the 16-char ext4 limit). The boot mount matches
# labels exactly, so a retired disk can stay attached safely.
function f_retire_old_labels {
  local f_dev="$1"
  local f_retired="X-${g_data_label}" f_retired_luks="X-${g_luks_label}"
  [[ "${f_dev}" == /dev/mapper/* ]] && return 1
  local f_type
  f_type=$(blkid -s TYPE -o value "${f_dev}" 2>/dev/null || true)
  case "${f_type}" in
    crypto_LUKS)
      cryptsetup config "${f_dev}" --label "${f_retired_luks}" 2>/dev/null || return 1
      ;;
    ext4)
      e2label "${f_dev}" "${f_retired}" 2>/dev/null || return 1
      ;;
    btrfs)
      mkdir -p /symbios-media.oldlabel
      mount -o ro "${f_dev}" /symbios-media.oldlabel 2>/dev/null || return 1
      btrfs filesystem label /symbios-media.oldlabel "${f_retired}" 2>/dev/null || {
         umount /symbios-media.oldlabel 2>/dev/null || true
        return 1
      }
       umount /symbios-media.oldlabel 2>/dev/null || true
      ;;
    *)
      return 1
      ;;
  esac
  # Exact match with quotes - retired X- names contain the base as substring.
  if blkid "${f_dev}" 2>/dev/null | grep -q "LABEL=\"${g_data_label}\"\|LABEL=\"${g_luks_label}\""
  then
    return 1
  fi
  return 0
}

# Restore canonical labels on a device (rollback counterpart).
function f_restore_old_labels {
  local f_dev="$1"
  [[ "${f_dev}" == /dev/mapper/* ]] && return 1
  local f_type
  f_type=$(blkid -s TYPE -o value "${f_dev}" 2>/dev/null || true)
  case "${f_type}" in
    crypto_LUKS)
      cryptsetup config "${f_dev}" --label "${g_luks_label}" 2>/dev/null || return 1
      ;;
    ext4)
      e2label "${f_dev}" "${g_data_label}" 2>/dev/null || return 1
      ;;
    btrfs)
      mkdir -p /symbios-media.oldlabel
      mount -o ro "${f_dev}" /symbios-media.oldlabel 2>/dev/null || return 1
      btrfs filesystem label /symbios-media.oldlabel "${g_data_label}" 2>/dev/null || {
         umount /symbios-media.oldlabel 2>/dev/null || true
        return 1
      }
       umount /symbios-media.oldlabel 2>/dev/null || true
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# State file helpers (used only in setup / rollback)
# ---------------------------------------------------------------------------

function f_save_state {
  local f_old_is_mount="$1" f_old_device="$2" f_old_fstype="$3" f_new_device="$4"
  local f_encrypt="$5" f_luks_name="$6"
  cat > "${f_state_file}" <<EOF
old_is_mount=${f_old_is_mount}
old_device=${f_old_device}
old_fstype=${f_old_fstype}
new_device=${f_new_device}
encrypt=${f_encrypt}
luks_name=${f_luks_name}
timestamp=$(date -Iseconds)
EOF
  chmod 600 "${f_state_file}"
}

function f_load_state {
  if [[ ! -f "${f_state_file}" ]]
  then
    return 1
  fi
  # Read known variables explicitly instead of sourcing the file
  # to prevent code execution through a tampered state file
  f_old_is_mount=$(grep '^old_is_mount=' "${f_state_file}" | cut -d= -f2-)
  f_old_device=$(grep '^old_device=' "${f_state_file}" | cut -d= -f2-)
  f_old_fstype=$(grep '^old_fstype=' "${f_state_file}" | cut -d= -f2-)
  f_new_device=$(grep '^new_device=' "${f_state_file}" | cut -d= -f2-)
  f_encrypt=$(grep '^encrypt=' "${f_state_file}" | cut -d= -f2-)
  f_luks_name=$(grep '^luks_name=' "${f_state_file}" | cut -d= -f2-)
  f_migration_timestamp=$(grep '^timestamp=' "${f_state_file}" | cut -d= -f2-)
  return 0
}

function f_clear_state {
  rm -f "${f_state_file}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Shared rollback logic (called from rollback action AND setup error handler)
# ---------------------------------------------------------------------------

function f_do_rollback {
  local f_old_is_mount="" f_old_device="" f_old_fstype="" f_new_device=""
  local f_encrypt="" f_luks_name=""

  if ! f_load_state
  then
    f_json_error "No migration state found. Nothing to rollback."
  fi

  f_log_step "Rolling back media migration"
  f_log "Previous media: ${f_old_device} (${f_old_fstype})"
  f_log "New device: ${f_new_device}"

   umount "${g_mountpoint}" 2>/dev/null || true
  f_log_ok "Current ${g_mountpoint} unmounted"

  if [[ "${f_encrypt}" == "yes" ]] && [[ -n "${f_luks_name}" ]]
  then
    f_log_step "Closing LUKS volume ${f_luks_name}"
    cryptsetup close "${f_luks_name}" 2>/dev/null || true
    f_log_ok "LUKS volume closed"
  fi

  # Swap the labels back so the label-based boot mount finds the previous
  # volume again. No fstab handling (media mounts never had an entry).
  if [[ "${f_old_is_mount}" == "yes" ]]
  then
    f_retire_old_labels "${f_new_device}" 2>/dev/null || \
      f_log_error "Could not retire labels on ${f_new_device} - remove or relabel it manually."
    if ! f_restore_old_labels "${f_old_device}"
    then
      f_json_error "Rollback failed: could not restore labels on ${f_old_device}. Check manually."
    fi
    f_log_ok "Labels swapped back to ${f_old_device}"
    f_log_step "Mounting previous ${g_mountpoint}"
    f_mount_media "${f_old_device}" "${f_old_fstype}" 2>/dev/null || {
      f_json_error "Rollback failed: could not mount previous ${g_mountpoint} from ${f_old_device}."
    }
    f_log_ok "Previous ${g_mountpoint} mounted"
  else
    # Media lived on the host dir before: clear our labels from the new
    # disk so the boot mount ignores it, the covered dir reappears alone.
    f_retire_old_labels "${f_new_device}" 2>/dev/null || \
      f_log_error "Could not retire labels on ${f_new_device} - remove or relabel it manually."
    f_log_ok "${g_mountpoint} returns to host directory"
  fi

  f_clear_state

  f_log_step "Rollback complete!"
  f_json_ok '"message":"Rollback complete. Media volume restored to previous state.","can_rollback":false'
}

# Error handler for setup - rolls back and exits.
function f_setup_error {
  local f_msg="$1"
  f_log_error "$f_msg"
  f_log "Attempting automatic rollback..."
  f_do_rollback >/dev/null 2>&1 || f_log_error "Rollback also failed"
  f_json_error "$f_msg (rolled back)"
}

# Refuse targets that would destroy the data volume or the running
# system: anything carrying the SYMBIOS_DATA labels, RAID members,
# LUKS/LVM holders, active swap, or mounts in the /symbios subtree.
function f_guard_target {
  local f_device="$1"
  local f_tree
  f_tree=$(lsblk -n -l -o NAME,TYPE,FSTYPE,LABEL,MOUNTPOINT "$f_device" 2>/dev/null) || \
    f_json_error "Cannot inspect $f_device"
  [[ -z "$f_tree" ]] && f_json_error "Unknown device: $f_device"
  local f_top_type
  f_top_type=$(echo "$f_tree" | head -1 | awk '{print $2}')
  if [[ "${f_top_type}" != "disk" ]] && [[ "${f_top_type}" != "raid" ]]
  then
    f_json_error "$f_device is not a whole disk or RAID array."
  fi
  local f_row f_name f_type f_fstype f_label f_mount
  while read -r f_name f_type f_fstype f_label f_mount
  do
    if [[ "${f_label}" == "${g_data_fs_label}" ]] || \
       [[ "${f_label}" == "${g_data_luks_label}" ]] || \
       [[ "${f_label}" == "${g_data_label}" ]] || \
       [[ "${f_label}" == "${g_luks_label}" ]]
    then
      f_json_error "/dev/${f_name} carries label ${f_label} - refusing to touch a SymbiOS data or media volume."
    fi
    [[ -n "${f_mount}" ]] && \
      f_json_error "/dev/${f_name} is mounted at ${f_mount}. Unmount it first."
    case "${f_fstype}" in
      linux_raid_member)
        f_json_error "/dev/${f_name} is an mdadm RAID member - break up the array first."
        ;;
      LVM2_member)
        f_json_error "/dev/${f_name} holds an LVM volume group - remove it first."
        ;;
      crypto_LUKS)
        f_json_error "/dev/${f_name} holds encrypted (LUKS) data - unlock and wipe it first if you really want this disk."
        ;;
      swap)
        if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/dev/${f_name}"
        then
          f_json_error "/dev/${f_name} is active swap - swap it off first."
        fi
        ;;
      btrfs)
        f_bdevs=$(btrfs filesystem show 2>/dev/null | awk -v dev="/dev/${f_name}" '
          /^Label:/ { label=$0; sub(/^.*Label: \x27/, "", label); sub(/\x27.*$/, "", label); devs=""; }
          /Total devices/ { devs=$3; }
          $0 ~ "path " dev "( |$)" { print devs "|" label; exit; }')
        if [[ -n "${f_bdevs}" ]] && [[ "${f_bdevs%%|*}" != "1" ]] && [[ "${f_bdevs%%|*}" != "" ]]
        then
          f_json_error "/dev/${f_name} is a member of btrfs filesystem ${f_bdevs##*|} (${f_bdevs%%|*} devices) - formatting it destroys the whole array."
        fi
        ;;
    esac
  done <<< "$f_tree"
}

# ---------------------------------------------------------------------------
# Dispatch (flat - each action lives directly in its case branch)
# ---------------------------------------------------------------------------

function f_main {
  g_action="${1:-}"
  shift 2>/dev/null || true

  case "$g_action" in

  # ------------------------------------------------------------------
  status)
    local f_media_source="" f_media_fstype="" f_media_size=""
    local f_media_used="" f_media_avail="" f_mounted="false"
    local f_luks_dev="" f_luks_open="false" f_can_rollback="false"

    [[ -f "${f_state_file}" ]] && f_can_rollback="true"

    if mountpoint -q "${g_mountpoint}" 2>/dev/null
    then
      f_mounted="true"
      f_media_source=$(findmnt -n -o SOURCE "${g_mountpoint}" 2>/dev/null || true)
      f_media_fstype=$(findmnt -n -o FSTYPE "${g_mountpoint}" 2>/dev/null || true)
      local f_df_out
      f_df_out=$(df -hT "${g_mountpoint}" 2>/dev/null | tail -1) || true
      if [[ -n "$f_df_out" ]]
      then
        set -- $f_df_out
        if [[ $# -ge 7 ]]
        then
          f_media_size="$3"
          f_media_used="$4"
          f_media_avail="$5"
        fi
      fi
    fi

    local f_luks_name
    f_luks_name=$(f_find_luks)
    if [[ -n "$f_luks_name" ]]
    then
      f_luks_dev="/dev/$f_luks_name"
      if cryptsetup status "$g_mapper_name" 2>/dev/null | head -1 | grep -q "is active"
      then
        f_luks_open="true"
      fi
    fi

    cat <<EOF
{"ok":true,"mounted":$f_mounted,"media_source":"$f_media_source","media_fstype":"$f_media_fstype","media_size":"$f_media_size","media_used":"$f_media_used","media_avail":"$f_media_avail","luks_device":"$f_luks_dev","luks_open":$f_luks_open,"can_rollback":$f_can_rollback}
EOF
    ;;

  # ------------------------------------------------------------------
  setup)
    local f_device="${1:-}" f_encrypt="${2:-no}" f_password_file="${3:-}"
    local f_password=""

    [[ -z "$f_device" ]] && f_json_error "No device selected"
    [[ "$f_device" == /dev/* ]] || f_json_error "Invalid device path"

    if [[ "$f_encrypt" == "yes" ]] && [[ -n "$f_password_file" ]]
    then
      if [[ -f "$f_password_file" ]]
      then
        # read exits nonzero when the file has no trailing newline -
        # tolerate that, the empty-check below reports a proper error.
        IFS= read -rs f_password < "$f_password_file" || true
        rm -f "$f_password_file" 2>/dev/null
      fi
    fi
    [[ "$f_encrypt" == "yes" ]] && [[ -z "$f_password" ]] && \
      f_json_error "Password required for LUKS encryption"

    # Never format the system disk or anything mounted below /symbios
    local f_root_dev
    f_root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || true
    if [[ -n "$f_root_dev" ]]
    then
      if [[ "$f_device" == *"$f_root_dev"* ]] || [[ "$f_root_dev" == *"$f_device"* ]]
      then
        f_json_error "Cannot format the root device!"
      fi
    fi
    if findmnt -n -o TARGET "$f_device" 2>/dev/null | grep -qx "${g_mountpoint}"
    then
      f_json_error "This device is already mounted as ${g_mountpoint}"
    fi
    local f_symbios_src
    f_symbios_src=$(findmnt -n -o SOURCE /symbios 2>/dev/null || true)
    if [[ -n "${f_symbios_src}" ]] && [[ "$f_device" == *"${f_symbios_src#/dev/mapper/}"* ]]
    then
      f_json_error "This device holds the mounted /symbios data volume - refusing."
    fi

    f_guard_target "$f_device"

    local f_media_size f_disk_size
    f_media_size=$(du -sb "${g_mountpoint}/" 2>/dev/null | awk '{print $1}') || f_media_size=0
    f_disk_size=$(blockdev --getsize64 "$f_device" 2>/dev/null) || f_disk_size=0

    [[ "$f_disk_size" -eq 0 ]] 2>/dev/null && \
      f_json_error "Could not determine disk size"

    local f_overhead=$(( 256 * 1024 * 1024 ))
    local f_needed=$(( f_media_size + f_overhead ))

    if [[ "$f_disk_size" -lt "$f_needed" ]]
    then
      local f_media_gb f_disk_gb f_needed_gb
      f_media_gb=$(awk "BEGIN {printf \"%.1f\", $f_media_size/1073741824}")
      f_disk_gb=$(awk "BEGIN {printf \"%.1f\", $f_disk_size/1073741824}")
      f_needed_gb=$(awk "BEGIN {printf \"%.1f\", $f_needed/1073741824}")
      f_json_error "Disk too small! Media is ${f_media_gb}G but disk is only ${f_disk_gb}G. Need at least ${f_needed_gb}G."
    fi

    f_log_step "Saving state for rollback"

    local f_old_is_mount="no" f_old_src="" f_old_fs=""
    if mountpoint -q "${g_mountpoint}" 2>/dev/null
    then
      f_old_is_mount="yes"
      f_old_src=$(findmnt -n -o SOURCE "${g_mountpoint}" 2>/dev/null || echo "")
      f_old_fs=$(findmnt -n -o FSTYPE "${g_mountpoint}" 2>/dev/null || echo "")
      if [[ "${f_old_src}" == /dev/mapper/* ]]
      then
        f_clear_state 2>/dev/null || true
        f_json_error "Current ${g_mountpoint} is a LUKS mapper (${f_old_src}). Second migrations from an encrypted volume need manual label handling - retire the old disk first."
      fi
    fi

    f_save_state "${f_old_is_mount}" "${f_old_src}" "${f_old_fs}" "$f_device" \
      "$f_encrypt" ${g_mapper_name}
    f_log_ok "State saved (can rollback later)"

    f_log_step "Preparing device"
     umount "$f_device" 2>/dev/null || true

    local f_luks_name=${g_mapper_name} f_target

    if [[ "$f_encrypt" == "yes" ]]
    then
      f_log_step "Formatting device with LUKS encryption"
      echo "$f_password" | cryptsetup luksFormat --label "$g_luks_label" \
        --batch-mode "$f_device" || {
        f_setup_error "LUKS format failed"
      }
      f_log_ok "LUKS format complete"

      f_log_step "Opening LUKS volume"
      echo "$f_password" | cryptsetup open "$f_device" "$f_luks_name" || {
        f_setup_error "LUKS open failed"
      }
      f_log_ok "LUKS volume opened as $f_luks_name"
      f_target="/dev/mapper/$f_luks_name"

      # Store the passphrase as boot keyfile so the volume unlocks
      # automatically once /symbios is mounted (at rest the keyfile is
      # protected by the encrypted data volume itself, never mounted
      # into containers).
      mkdir -p /symbios/.keys 2>/dev/null || f_setup_error "Cannot create /symbios/.keys"
      chmod 700 /symbios/.keys
      printf '%s' "$f_password" > /symbios/.keys/media-volume.key || \
        f_setup_error "Cannot write boot keyfile"
      chmod 600 /symbios/.keys/media-volume.key
      f_password=""
      f_log_ok "Boot keyfile stored"
    else
      f_target="$f_device"
    fi

    f_log_step "Formatting $f_device as ext4"
    # quota+project enable ext4 project quotas for the media directories
    # (enforced per-directory limits, see base-services/media.yml).
    mkfs.ext4 -F -O quota,project -L "$g_data_label" "$f_target" 2>&1 || {
      f_setup_error "mkfs.ext4 failed"
    }
    f_log_ok "ext4 filesystem created"

    f_log_step "Copying current media to new volume (rsync)"
    mkdir -p /symbios-media.new
    mount -t ext4 -o defaults,noatime,prjquota "$f_target" /symbios-media.new || {
      f_setup_error "Mount /symbios-media.new failed"
    }
    f_log_ok "Temporary mount at /symbios-media.new"

    rsync -av --progress \
      --exclude='.trashed-*' \
      --exclude='.symbios-media-migration.state' \
      "${g_mountpoint}/" /symbios-media.new/ 2>&1 || {
      f_setup_error "rsync failed"
    }
    f_log_ok "Media copy complete"

    f_log_step "Switching ${g_mountpoint} to new volume (explicit, no fstab)"
     umount "${g_mountpoint}" 2>/dev/null || true
    f_mount_media "$f_target" "ext4" || {
      f_setup_error "Mount ${g_mountpoint} failed"
    }
    f_log_ok "${g_mountpoint} is now on $f_device"

     umount /symbios-media.new 2>/dev/null || true
    rm -rf /symbios-media.new 2>/dev/null || true

    # Retire our labels on the previous volume so the label-based boot
    # mount can never pick the old disk while both are attached.
    if [[ "${f_old_is_mount}" == "yes" ]]
    then
      if f_retire_old_labels "${f_old_src}"
      then
        f_log_ok "Labels retired on previous device ${f_old_src}"
      else
        f_log_error "Could not retire labels on ${f_old_src} - remove or relabel it manually (duplicate labels confuse the boot mount)."
      fi
    fi

    f_log_step "Migration complete (no reboot needed)"
    f_log_ok "${g_mountpoint} is now on $f_device"
    f_log "Recreate the media consumers so they pick up the new mount (re-run their playbooks or docker compose up -d)."
    if [[ "$f_encrypt" == "yes" ]]
    then
      f_log "The volume unlocks automatically at boot via the keyfile on /symbios (see base-services/media-volume.yml)."
    fi

    f_json_ok '"message":"Media migration complete. Recreate the media consumers (playbook reapply) so they pick up the new mount.","can_rollback":true'
    ;;

  # ------------------------------------------------------------------
  adopt)
    # Use an existing filesystem or open mapper as media volume without
    # formatting. A whole disk with a directly usable filesystem is fine,
    # a partitioned disk needs its partition named explicitly.
    local f_device="${1:-}" f_copy="no" f_check="no" f_arg
    shift 1 2>/dev/null || true
    [[ -z "${f_device}" ]] && f_json_error "No device selected"
    [[ "${f_device}" == /dev/* ]] || f_json_error "Invalid device path"
    for f_arg in "$@"
    do
      if [[ "${f_arg}" == "--copy" ]]
      then
        f_copy="yes"
      elif [[ "${f_arg}" == "--check" ]]
      then
        f_check="yes"
      fi
    done
    local f_adopt_type=""
    if [[ "${f_device}" == /dev/md* ]] || [[ "${f_device}" == /dev/mapper/* ]]
    then
      f_adopt_type="virtual"
    else
      f_adopt_type=$(lsblk -n -l -o TYPE "${f_device}" 2>/dev/null | head -1) || \
        f_json_error "Unknown device: ${f_device}"
    fi
    local f_adopt_fs f_adopt_label
    f_adopt_fs=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    f_adopt_label=$(blkid -s LABEL -o value "${f_device}" 2>/dev/null || true)
    case "${f_adopt_type}" in
      part|loop|virtual)
        ;;
      disk)
        if [[ "${f_adopt_fs}" != "ext4" ]] && [[ "${f_adopt_fs}" != "btrfs" ]]
        then
          f_json_error "${f_device} is a whole disk without a directly usable filesystem - adopt needs a partition, md array or open LUKS mapper."
        fi
        ;;
      *)
        f_json_error "${f_device} is a ${f_adopt_type:-unknown device} - adopt needs a partition, loop device, md array or open LUKS mapper."
        ;;
    esac
    [[ -z "${f_adopt_fs}" ]] && f_json_error "${f_device} has no detectable filesystem. Format it via setup first."
    case "${f_adopt_fs}" in
      ext4|btrfs)
        ;;
      crypto_LUKS|swap|LVM2_member|linux_raid_member)
        f_json_error "${f_device} holds ${f_adopt_fs} - unlock or break it up first, then adopt the filesystem inside."
        ;;
      *)
        f_json_error "${f_device} has filesystem ${f_adopt_fs} - only ext4 or btrfs can hold the media volume."
        ;;
    esac
    # Never adopt the data volume (or the current media volume) as media
    if [[ "${f_adopt_label}" == "${g_data_fs_label}" ]] || \
       [[ "${f_adopt_label}" == "${g_data_luks_label}" ]]
    then
      f_json_error "${f_device} carries label ${f_adopt_label} - refusing to adopt the data volume as media."
    fi
    local f_cur_mount
    f_cur_mount=$(findmnt -n -o TARGET "${f_device}" 2>/dev/null || true)
    if [[ -n "${f_cur_mount}" ]] && [[ "${f_cur_mount}" != "${g_mountpoint}" ]]
    then
      f_json_error "${f_device} is mounted at ${f_cur_mount}. Unmount it first."
    fi
    if [[ "${f_cur_mount}" == "${g_mountpoint}" ]]
    then
      f_json_ok '"message":"This device is already mounted as media volume.","can_rollback":false'
    fi
    mkdir -p /symbios-media.new
    if ! mount -o ro "${f_device}" /symbios-media.new 2>/dev/null
    then
      f_json_error "${f_device} could not be mounted read-only. Check the filesystem (fsck/btrfs check) first."
    fi
     umount /symbios-media.new 2>/dev/null || true
    local f_old_is_mount="no" f_old_src="" f_old_fs=""
    if mountpoint -q "${g_mountpoint}" 2>/dev/null
    then
      f_old_is_mount="yes"
      f_old_src=$(findmnt -n -o SOURCE "${g_mountpoint}" 2>/dev/null || echo "")
      f_old_fs=$(findmnt -n -o FSTYPE "${g_mountpoint}" 2>/dev/null || echo "")
    fi
    if [[ "${f_check}" == "yes" ]]
    then
      local f_adopt_size
      f_adopt_size=$(blockdev --getsize64 "${f_device}" 2>/dev/null || echo 0)
      f_json_ok "\"message\":\"Adopt check OK: ${f_adopt_fs} filesystem (${f_adopt_size} bytes) can become the media volume.\",\"fstype\":\"${f_adopt_fs}\",\"label\":\"${f_adopt_label}\",\"copy\":\"${f_copy}\""
    fi
    f_save_state "${f_old_is_mount}" "${f_old_src}" "${f_old_fs}" "${f_device}" \
      "no" ""
    f_log_ok "State saved (can rollback later)"
    if [[ "${f_copy}" == "yes" ]]
    then
      f_log_step "Copying current media onto adopted device"
      mkdir -p /symbios-media.new
      mount "${f_device}" /symbios-media.new || f_setup_error "Mount adopted device failed"
      rsync -av --progress \
        --exclude='.trashed-*' \
        --exclude='.symbios-media-migration.state' \
        "${g_mountpoint}/" /symbios-media.new/ 2>&1 || {
         umount /symbios-media.new 2>/dev/null || true
        f_setup_error "rsync failed"
      }
       umount /symbios-media.new 2>/dev/null || true
      f_log_ok "Media copy complete"
    fi
    f_log_step "Switching ${g_mountpoint} to adopted device (explicit, no fstab)"
     umount "${g_mountpoint}" 2>/dev/null || true
    f_mount_media "${f_device}" "${f_adopt_fs}" || f_setup_error "Mount ${g_mountpoint} failed"
    f_log_ok "${g_mountpoint} is now on ${f_device} (${f_adopt_fs}, data kept)"
    if [[ "${f_copy}" == "yes" ]] && [[ "${f_old_is_mount}" == "yes" ]]
    then
      if [[ "${f_old_src}" == /dev/mapper/* ]]
      then
        f_log_error "Previous media was a LUKS mapper (${f_old_src}) - retire its labels manually."
      elif f_retire_old_labels "${f_old_src}"
      then
        f_log_ok "Labels retired on previous device ${f_old_src}"
      else
        f_log_error "Could not retire labels on ${f_old_src} - remove or relabel it manually."
      fi
    fi
    f_log "Recreate the media consumers so they pick up the new mount (re-run their playbooks or docker compose up -d)."
    f_json_ok '"message":"Adopted existing filesystem as media volume without formatting.","can_rollback":true'
    ;;

  # ------------------------------------------------------------------
  unlock)
    # Open a media LUKS device for inspection only: no mount, no formatting.
    local f_device="${1:-}" f_pw_file="${2:-}" f_password=""
    [[ -z "${f_device}" ]] && f_json_error "No device selected"
    [[ "${f_device}" == /dev/* ]] || f_json_error "Invalid device path"
    [[ -z "${f_pw_file}" ]] && f_json_error "Password file is required"
    local f_unlock_fs
    f_unlock_fs=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    [[ "${f_unlock_fs}" == "crypto_LUKS" ]] || \
      f_json_error "${f_device} is not a LUKS device (found: ${f_unlock_fs:-nothing})."
    if [[ "$(blkid -s LABEL -o value "${f_device}" 2>/dev/null || true)" != "${g_luks_label}" ]]
    then
      f_json_error "${f_device} does not carry the media label ${g_luks_label} - use the data disk page for foreign volumes."
    fi
    if [[ -f "${f_pw_file}" ]]
    then
      IFS= read -rs f_password < "${f_pw_file}" || true
      rm -f "${f_pw_file}" 2>/dev/null || true
    fi
    [[ -z "${f_password}" ]] && f_json_error "Passphrase is required"
    if [[ -e "/dev/mapper/${g_mapper_name}" ]]
    then
      f_log_ok "${f_device} already open as ${g_mapper_name}"
    else
      f_log_step "Opening ${f_device} as ${g_mapper_name}"
      printf '%s' "${f_password}" | cryptsetup open "${f_device}" "${g_mapper_name}" || \
        f_json_error "Failed to open ${f_device}. Is the passphrase correct?"
      f_log_ok "LUKS volume opened"
    fi
    f_password=""
    local f_mapper_dev="/dev/mapper/${g_mapper_name}"
    local f_inner_fs
    f_inner_fs=$(blkid -s TYPE -o value "${f_mapper_dev}" 2>/dev/null || true)
    [[ -z "${f_inner_fs}" ]] && f_inner_fs="unknown (still encrypted or empty)"
    f_json_ok "\"message\":\"${f_device} opened as ${f_mapper_dev} (${f_inner_fs}) - nothing mounted, nothing formatted.\",\"mapper\":\"${f_mapper_dev}\",\"fstype\":\"${f_inner_fs}\""
    ;;

  # ------------------------------------------------------------------
  lock)
    # Close the media LUKS mapper again (by mapper name or source device).
    local f_target="${1:-}"
    [[ -z "${f_target}" ]] && f_json_error "No mapper or device given"
    local f_mapper="${f_target##*/}"
    if [[ "${f_target}" == /dev/mapper/* ]]
    then
      f_mapper="${f_target#/dev/mapper/}"
    elif [[ "${f_target}" == /dev/* ]]
    then
      f_mapper=$(lsblk -n -l -o NAME,TYPE "${f_target}" 2>/dev/null | \
        awk '$2 == "crypt" {print $1; exit}')
      [[ -z "${f_mapper}" ]] && f_json_error "${f_target} is not open."
    fi
    [[ "${f_mapper}" == "${g_mapper_name}"* ]] || \
      f_json_error "This is not a media mapper - use the data disk page."
    mountpoint -q "${g_mountpoint}" 2>/dev/null && \
      f_json_error "The mapper holds the mounted media volume - unmount it first."
    cryptsetup close "${f_mapper}" 2>&1 || \
      f_json_error "Could not close ${f_mapper} (still mounted?)."
    f_json_ok "\"message\":\"${f_mapper} closed.\""
    ;;

  # ------------------------------------------------------------------
  luks)
    # List media LUKS devices with label/uuid/size and open state as JSON.
    local f_luks_out="" f_luks_first="yes"
    local f_l_name f_l_size f_l_label f_l_uuid f_l_mapper f_l_open
    while read -r f_l_name f_l_size
    do
      [[ -z "${f_l_name}" ]] && continue
      f_l_label=$(blkid -s LABEL -o value "/dev/${f_l_name}" 2>/dev/null || true)
      [[ "${f_l_label}" == "${g_luks_label}" ]] || continue
      f_l_uuid=$(blkid -s UUID -o value "/dev/${f_l_name}" 2>/dev/null || true)
      f_l_mapper=$(lsblk -n -l -o NAME,TYPE "/dev/${f_l_name}" 2>/dev/null | \
        awk '$2 == "crypt" {print $1; exit}')
      f_l_open="false"
      [[ -n "${f_l_mapper}" ]] && f_l_open="true"
      [[ "${f_luks_first}" == "yes" ]] || f_luks_out="${f_luks_out}, "
      f_luks_first="no"
      f_luks_out="${f_luks_out}{\"device\":\"/dev/${f_l_name}\""
      f_luks_out="${f_luks_out},\"size_bytes\":${f_l_size:-0}"
      f_luks_out="${f_luks_out},\"label\":$(printf '%s' "${f_l_label}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"uuid\":$(printf '%s' "${f_l_uuid}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"open\":${f_l_open}"
      f_luks_out="${f_luks_out},\"mapper\":$(printf '%s' "${f_l_mapper}" | f_json_escape)}"
    done < <(lsblk -n -l -b -o NAME,SIZE,FSTYPE 2>/dev/null | \
      awk '$3 == "crypto_LUKS" {print $1, $2}' || true)
    f_json_ok "\"devices\":[${f_luks_out}]"
    ;;

  # ------------------------------------------------------------------
  rollback)
    f_do_rollback
    ;;

  # ------------------------------------------------------------------
  umount)
    umount "${g_mountpoint}" 2>/dev/null || true
    cryptsetup close ${g_mapper_name} 2>/dev/null || true
    cryptsetup close ${g_mapper_name}-2 2>/dev/null || true
    cryptsetup close ${g_mapper_name}-3 2>/dev/null || true
    f_json_ok '"message":"Media volume unmounted and LUKS closed."'
    ;;

  # ------------------------------------------------------------------
  save-key)
    # Store a LUKS passphrase as the boot keyfile so the volume unlocks
    # automatically once /symbios is mounted. The keyfile lives below
    # /symbios itself (encrypted at rest by the data volume) and is never
    # mounted into containers - host scripts only.
    local f_pw_file="${1:-}" f_password=""
    [[ -z "${f_pw_file}" ]] && f_json_error "Password file is required"
    if [[ -f "${f_pw_file}" ]]
    then
      IFS= read -rs f_password < "${f_pw_file}" || true
      rm -f "${f_pw_file}" 2>/dev/null || true
    fi
    [[ -z "${f_password}" ]] && f_json_error "Passphrase is required"
    mkdir -p /symbios/.keys 2>/dev/null || f_json_error "Cannot create /symbios/.keys"
    chmod 700 /symbios/.keys
    printf '%s' "${f_password}" > /symbios/.keys/media-volume.key || \
      f_json_error "Cannot write keyfile"
    chmod 600 /symbios/.keys/media-volume.key
    f_password=""
    f_json_ok '"message":"Boot keyfile stored (0600, /symbios/.keys/media-volume.key)."'
    ;;

  # ------------------------------------------------------------------
  change-password)
    local f_current_pw_file="${1:-}" f_new_pw_file="${2:-}"
    local f_current_password="" f_new_password=""

    [[ -z "$f_current_pw_file" ]] && f_json_error "Current password file is required"
    [[ -z "$f_new_pw_file" ]] && f_json_error "New password file is required"

    if [[ -f "$f_current_pw_file" ]]
    then
      IFS= read -rs f_current_password < "$f_current_pw_file" || true
      rm -f "$f_current_pw_file" 2>/dev/null
    fi
    if [[ -f "$f_new_pw_file" ]]
    then
      IFS= read -rs f_new_password < "$f_new_pw_file" || true
      rm -f "$f_new_pw_file" 2>/dev/null
    fi

    [[ -z "$f_current_password" ]] && f_json_error "Current password is required"
    [[ -z "$f_new_password" ]] && f_json_error "New password is required"
    [[ "$f_current_password" == "$f_new_password" ]] && \
      f_json_error "New password must differ from current password"

    local f_luks_dev
    f_luks_dev=$(f_find_luks)
    [[ -z "$f_luks_dev" ]] && f_json_error "No media LUKS device found"
    f_luks_dev="/dev/$f_luks_dev"

    f_log_step "Changing media LUKS passphrase on $f_luks_dev"

    local f_tmp_key
    f_tmp_key=$(mktemp /tmp/.symbios-media-key.XXXXXX)
    chmod 600 "$f_tmp_key"
    printf '%s' "$f_current_password" > "$f_tmp_key"

    echo "$f_new_password" | cryptsetup luksChangeKey \
      --key-file "$f_tmp_key" \
      "$f_luks_dev" 2>&1
    local f_rc=$?
    rm -f "$f_tmp_key"

    if [[ "$f_rc" -ne 0 ]]
    then
      f_log_error "Failed to change LUKS passphrase (wrong current password?)"
      f_json_error "Failed to change LUKS passphrase. Is the current password correct?"
    fi

    f_log_ok "Media LUKS passphrase changed successfully"
    f_json_ok '"message":"Media LUKS passphrase changed successfully."'
    ;;

  help|-h|--help)
    f_usage
    ;;

  *)
    f_json_error "Usage: $0 {status|setup|adopt|unlock|lock|luks|rollback|umount|save-key|change-password}"
    ;;
  esac
}

f_main "$@"
