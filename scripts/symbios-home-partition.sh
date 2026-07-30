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

# symbios-home-partition.sh — Manage /home partition (create, encrypt, mount, rollback)
#
# Actions:
#   list                          List block devices (JSON)
#   status                        Show /home mount + LUKS status (JSON)
#   setup <device> [encrypt=yes] [password=pw]   Migrate /home to new disk
#   rollback                      Undo last migration, restore original /home
#   umount                        Unmount /home and close LUKS
#   change-password               Change LUKS passphrase
#
# State file for rollback: /home/.symbios-home-migration.state

set -euo pipefail

# Labels used when creating LUKS partition and ext4 data filesystem.
# Scripts and WebUI identify disks by these labels (robust even with
# multiple storage devices attached).
g_luks_label="CRYPT_LUKS_SYMBIOS_DATA"
g_data_label="SYMBIOS_DATA"

f_state_file="/home/.symbios-home-migration.state"

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

# ---------------------------------------------------------------------------
# State file helpers (used only in setup / rollback)
# ---------------------------------------------------------------------------

function f_save_state {
  local f_old_device="$1" f_old_fstype="$2" f_new_device="$3"
  local f_encrypt="$4" f_luks_name="$5" f_old_fstab_line="$6"
  cat > "${f_state_file}" <<EOF
old_device=${f_old_device}
old_fstype=${f_old_fstype}
new_device=${f_new_device}
encrypt=${f_encrypt}
luks_name=${f_luks_name}
old_fstab_line=${f_old_fstab_line}
timestamp=$(date -Iseconds)
EOF
  chmod 644 "${f_state_file}"
}

function f_load_state {
  if [[ ! -f "${f_state_file}" ]]
  then
    return 1
  fi
  source "${f_state_file}"
  return 0
}

function f_clear_state {
  rm -f "${f_state_file}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Shared rollback logic (called from rollback action AND setup error handler)
# ---------------------------------------------------------------------------

function f_do_rollback {
  local f_old_device="" f_old_fstype="" f_new_device="" f_encrypt=""
  local f_luks_name="" f_old_fstab_line=""

  if ! f_load_state
  then
    f_json_error "No migration state found. Nothing to rollback."
  fi

  f_log_step "Rolling back /home migration"
  f_log "Original device: ${f_old_device} (${f_old_fstype})"
  f_log "New device: ${f_new_device}"

  umount /home 2>/dev/null || true
  f_log_ok "Current /home unmounted"

  if [[ "${f_encrypt}" == "yes" ]] && [[ -n "${f_luks_name}" ]]
  then
    f_log_step "Closing LUKS volume ${f_luks_name}"
    cryptsetup close "${f_luks_name}" 2>/dev/null || true
    f_log_ok "LUKS volume closed"
  fi

  f_log_step "Restoring /etc/fstab"
  sed -i '\#.*[[:space:]]/home[[:space:]]#d' /etc/fstab
  if [[ -n "${f_old_fstab_line}" ]]
  then
    echo "${f_old_fstab_line}" >> /etc/fstab
    f_log_ok "fstab restored from backup"
  else
    f_log_ok "No previous /home fstab entry (was on root filesystem)"
  fi

  f_log_step "Mounting original /home"
  if [[ "${f_old_fstype}" == "rootfs" ]]
  then
    f_log_ok "/home returns to root filesystem"
  else
    mount /home 2>/dev/null || {
      f_log_error "Failed to mount original /home! Check /etc/fstab manually."
      f_json_error "Rollback failed: could not mount original /home. Check /etc/fstab."
    }
    f_log_ok "Original /home mounted"
  fi

  rm -rf /home.new 2>/dev/null || true
  rm -f /config/.luks-name 2>/dev/null || true
  f_clear_state

  f_log_step "Rollback complete!"
  f_log_ok "/home has been restored to its original location"
  f_json_ok '"message":"Rollback complete. /home restored to original location.","can_rollback":false'
}

# Error handler for setup — rolls back and exits.
function f_setup_error {
  local f_msg="$1"
  f_log_error "$f_msg"
  f_log "Attempting automatic rollback..."
  f_do_rollback >/dev/null 2>&1 || f_log_error "Rollback also failed"
  f_json_error "$f_msg (rolled back)"
}

# ---------------------------------------------------------------------------
# Helper: find LUKS device by label (with fallback to any crypto_LUKS)
# ---------------------------------------------------------------------------

function f_find_luks {
  # Prints device name (e.g. sda1) or empty string
  local f_dev
  f_dev=$(lsblk -n -l -o FSTYPE,LABEL,NAME 2>/dev/null | \
    awk -v label="$g_luks_label" \
      '$1 == "crypto_LUKS" && ($2 == label || $2 == "") {print $3; exit}')
  if [[ -z "$f_dev" ]]
  then
    f_dev=$(lsblk -n -l -o FSTYPE,NAME 2>/dev/null | \
      awk '$1 == "crypto_LUKS" {print $2; exit}')
  fi
  echo "$f_dev"
}

# ---------------------------------------------------------------------------
# Dispatch (flat — each action lives directly in its case branch)
# ---------------------------------------------------------------------------

g_action="${1:-}"
shift 2>/dev/null || true

case "$g_action" in

  # ------------------------------------------------------------------
  list)
    lsblk -e 1,7,11,252 -J \
      -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,UUID,LABEL,TRAN,RM 2>&1 || \
      f_json_error "lsblk failed"
    ;;

  # ------------------------------------------------------------------
  status)
    local f_home_device="" f_home_fstype="" f_home_size=""
    local f_home_used="" f_home_avail=""
    local f_luks_name="" f_luks_device="" f_luks_open="false"
    local f_needs_unlock="false" f_can_rollback="false"

    [[ -f "${f_state_file}" ]] && f_can_rollback="true"

    local f_df_out
    f_df_out=$(df -hT /home 2>/dev/null | tail -1) || true
    if [[ -n "$f_df_out" ]]
    then
      set -- $f_df_out
      if [[ $# -ge 7 ]]
      then
        f_home_device="$1"
        f_home_fstype="$2"
        f_home_size="$3"
        f_home_used="$4"
        f_home_avail="$5"
      fi
    fi

    f_luks_name=$(f_find_luks)
    if [[ -n "$f_luks_name" ]]
    then
      f_luks_device="/dev/$f_luks_name"
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

    if [[ "$f_luks_open" == "false" ]]
    then
      ls /dev/mapper/ 2>/dev/null | grep -qE 'home|luks' && f_luks_open="true"
    fi

    cat <<EOF
{"ok":true,"home_device":"$f_home_device","home_fstype":"$f_home_fstype","home_size":"$f_home_size","home_used":"$f_home_used","home_avail":"$f_home_avail","luks_name":"$f_luks_name","luks_device":"$f_luks_device","luks_open":$f_luks_open,"needs_unlock":$f_needs_unlock,"can_rollback":$f_can_rollback}
EOF
    ;;

  # ------------------------------------------------------------------
  setup)
    local f_device="${1:-}" f_encrypt="${2:-no}" f_password="${3:-}"

    [[ -z "$f_device" ]] && f_json_error "No device selected"
    [[ "$f_device" == /dev/* ]] || f_json_error "Invalid device path"
    [[ "$f_encrypt" == "yes" ]] && [[ -z "$f_password" ]] && \
      f_json_error "Password required for LUKS encryption"

    local f_root_dev
    f_root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || true
    if [[ -n "$f_root_dev" ]]
    then
      if [[ "$f_device" == *"$f_root_dev"* ]] || [[ "$f_root_dev" == *"$f_device"* ]]
      then
        f_json_error "Cannot format the root device!"
      fi
    fi

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

    local f_home_size f_disk_size
    f_home_size=$(du -sb /home/ 2>/dev/null | awk '{print $1}') || f_home_size=0
    f_disk_size=$(blockdev --getsize64 "$f_device" 2>/dev/null) || f_disk_size=0

    [[ "$f_home_size" -eq 0 ]] 2>/dev/null && \
      f_json_error "Could not determine /home size"
    [[ "$f_disk_size" -eq 0 ]] 2>/dev/null && \
      f_json_error "Could not determine disk size"

    local f_overhead=$(( 16 * 1024 * 1024 ))
    local f_home_margin=$(( f_home_size / 20 ))
    [[ "$f_home_margin" -gt "$f_overhead" ]] && f_overhead=$f_home_margin
    local f_needed=$(( f_home_size + f_overhead ))

    if [[ "$f_disk_size" -lt "$f_needed" ]]
    then
      local f_home_gb f_disk_gb f_needed_gb
      f_home_gb=$(awk "BEGIN {printf \"%.1f\", $f_home_size/1073741824}")
      f_disk_gb=$(awk "BEGIN {printf \"%.1f\", $f_disk_size/1073741824}")
      f_needed_gb=$(awk "BEGIN {printf \"%.1f\", $f_needed/1073741824}")
      f_json_error "Disk too small! /home is ${f_home_gb}G but disk is only ${f_disk_gb}G. Need at least ${f_needed_gb}G."
    fi

    f_log_step "Saving state for rollback"

    local f_old_fstab_line
    f_old_fstab_line=$(grep -E '[[:space:]]/home[[:space:]]' /etc/fstab 2>/dev/null || echo "")
    local f_old_home_device="" f_old_home_fstype=""
    if [[ -n "$f_root_dev" ]]
    then
      f_old_home_device="$f_root_dev"
      f_old_home_fstype="rootfs"
    else
      f_old_home_device=$(findmnt -n -o SOURCE /home 2>/dev/null || echo "")
      f_old_home_fstype=$(findmnt -n -o FSTYPE /home 2>/dev/null || echo "")
    fi

    f_save_state "$f_old_home_device" "$f_old_home_fstype" "$f_device" \
      "$f_encrypt" "home-luks" "$f_old_fstab_line"
    f_log_ok "State saved (can rollback later)"

    f_log_step "Preparing device"
    umount "$f_device" 2>/dev/null || true

    local f_luks_name="home-luks" f_target

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
    else
      f_target="$f_device"
    fi

    f_log_step "Formatting $f_device as ext4"
    mkfs.ext4 -F -L "$g_data_label" "$f_target" 2>&1 || {
      f_setup_error "mkfs.ext4 failed"
    }
    f_log_ok "ext4 filesystem created"

    f_log_step "Mounting temporary partition"
    mkdir -p /home.new
    mount "$f_target" /home.new || {
      f_setup_error "Mount /home.new failed"
    }
    f_log_ok "Temporary mount at /home.new"

    f_log_step "Copying data from /home to new partition (rsync)"
    f_log "This may take a while for large /home directories..."
    rsync -av --progress \
      --exclude=docker/var-lib-docker \
      --exclude=docker/var-lib-containerd \
      --exclude='.trashed-*' \
      /home/ /home.new/ 2>&1 || {
      umount /home.new 2>/dev/null || true
      f_setup_error "rsync failed"
    }
    f_log_ok "Data copy complete"

    f_log_step "Unmounting old /home"
    umount /home 2>/dev/null || true
    f_log_ok "Old /home unmounted"

    f_log_step "Cleaning old /home mount point"
    rm -rf /home/* 2>/dev/null || true
    f_log_ok "Old /home cleaned"

    f_log_step "Updating /etc/fstab"
    sed -i '\#.*[[:space:]]/home[[:space:]]#d' /etc/fstab
    if [[ "$f_encrypt" == "yes" ]]
    then
      echo "/dev/mapper/$f_luks_name /home ext4 defaults,noatime,noauto 0 2" >> /etc/fstab
    else
      local f_uuid
      f_uuid=$(blkid -s UUID -o value "$f_device" 2>/dev/null) || {
        f_setup_error "blkid failed"
      }
      echo "UUID=$f_uuid /home ext4 defaults,noatime,noauto 0 2" >> /etc/fstab
    fi
    f_log_ok "fstab updated"

    f_log_step "Mounting new /home"
    mount /home || {
      f_setup_error "Mount /home failed"
    }
    f_log_ok "/home is now on new partition"

    if [[ "$f_encrypt" == "yes" ]]
    then
      echo "$f_luks_name" > /config/.luks-name 2>/dev/null || true
    fi

    umount /home.new 2>/dev/null || true
    rm -rf /home.new 2>/dev/null || true

    shutdown -r +30 "Disk migration safety-net reboot" 2>/dev/null || true

    f_log_step "Migration complete!"
    f_log_ok "/home is now on $f_device"
    f_log "Server will reboot in 1 minute to finalize. All services will restart automatically."
    if [[ "$f_encrypt" == "yes" ]]
    then
      f_log "You will need to enter your LUKS passphrase at the boot screen."
    fi

    f_log_step "Stopping Docker services for reboot"
    if command -v docker &>/dev/null
    then
      docker stop $(docker ps -q) 2>/dev/null || true
      f_log_ok "Docker services stopped"
    fi

    shutdown -c 2>/dev/null || true
    shutdown -r +1 "Disk migration complete — rebooting." 2>/dev/null || true
    f_log_ok "Reboot scheduled in 1 minute"

    f_json_ok '"message":"Disk migration complete. The server will reboot in about 1 minute. All services will restart automatically. You will need to enter your LUKS passphrase at the boot screen.","can_rollback":true'
    ;;

  # ------------------------------------------------------------------
  rollback)
    f_do_rollback
    ;;

  # ------------------------------------------------------------------
  umount)
    umount /home 2>/dev/null || true
    cryptsetup close home-luks 2>/dev/null || true
    f_json_ok '"message":"/home unmounted and LUKS volume closed."'
    ;;

  # ------------------------------------------------------------------
  change-password)
    local f_current_password="${1:-}" f_new_password="${2:-}"

    [[ -z "$f_current_password" ]] && f_json_error "Current password is required"
    [[ -z "$f_new_password" ]] && f_json_error "New password is required"
    [[ "$f_current_password" == "$f_new_password" ]] && \
      f_json_error "New password must differ from current password"

    local f_luks_dev
    f_luks_dev=$(f_find_luks)
    [[ -z "$f_luks_dev" ]] && f_json_error "No LUKS device found"
    f_luks_dev="/dev/$f_luks_dev"

    f_log_step "Changing LUKS passphrase on $f_luks_dev"

    local f_tmp_key
    f_tmp_key=$(mktemp /tmp/.symbios-key.XXXXXX)
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

    f_log_ok "LUKS passphrase changed successfully"
    f_json_ok '"message":"LUKS passphrase changed successfully."'
    ;;

  *)
    f_json_error "Usage: $0 {list|status|setup|rollback|umount|change-password}"
    ;;
esac
