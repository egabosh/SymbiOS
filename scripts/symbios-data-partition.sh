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

# symbios-data-partition.sh — Manage /symbios data partition (create, encrypt, mount, rollback)
#
# The /symbios data root holds all SymbiOS data (git repo, docker stacks,
# docker/containerd data dirs, homes, backups). Moving it to a separate
# (optionally LUKS-encrypted) disk keeps sensitive data off the root FS.
#
# Actions:
#   list                          List block devices (JSON)
#   status                        Show /symbios mount + LUKS status (JSON)
#   setup <device> [encrypt=yes] [password=pw]   Migrate /symbios to new disk
#   rollback                      Undo last migration, restore original /symbios
#                           Unmount /symbios and close LUKS
#   change-password               Change LUKS passphrase
#
# State file for rollback: /symbios/.symbios-data-migration.state

set -euo pipefail

# Labels used when creating LUKS partition and ext4 data filesystem.
# Scripts and WebUI identify disks by these labels (robust even with
# multiple storage devices attached).
g_luks_label="CRYPT_LUKS_SYMBIOS_DATA"
g_data_label="SYMBIOS_DATA"

# Mount point and LUKS mapper name for the /symbios data root
g_mountpoint="/symbios"
g_mapper_name="symbios-luks"

f_state_file="/symbios/.symbios-data-migration.state"

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

  f_log_step "Rolling back /symbios migration"
  f_log "Original device: ${f_old_device} (${f_old_fstype})"
  f_log "New device: ${f_new_device}"

   umount "${g_mountpoint}" 2>/dev/null || true
  f_log_ok "Current ${g_mountpoint} unmounted"

  if [[ "${f_encrypt}" == "yes" ]] && [[ -n "${f_luks_name}" ]]
  then
    f_log_step "Closing LUKS volume ${f_luks_name}"
    cryptsetup close "${f_luks_name}" 2>/dev/null || true
    f_log_ok "LUKS volume closed"
  fi

  f_log_step "Restoring /etc/fstab"
  sed -i '\#.*[[:space:]]/symbios[[:space:]]#d' /etc/fstab
  if [[ -n "${f_old_fstab_line}" ]]
  then
    echo "${f_old_fstab_line}" >> /etc/fstab
    f_log_ok "fstab restored from backup"
  else
    f_log_ok "No previous ${g_mountpoint} fstab entry (was on root filesystem)"
  fi

  f_log_step "Mounting original ${g_mountpoint}"
  if [[ "${f_old_fstype}" == "rootfs" ]]
  then
    f_log_ok "${g_mountpoint} returns to root filesystem"
  else
    mount "${g_mountpoint}" 2>/dev/null || {
      f_log_error "Failed to mount original ${g_mountpoint}! Check /etc/fstab manually."
      f_json_error "Rollback failed: could not mount original ${g_mountpoint}. Check /etc/fstab."
    }
    f_log_ok "Original ${g_mountpoint} mounted"
  fi

  rm -rf /symbios.new 2>/dev/null || true
  rm -f /config/.luks-name 2>/dev/null || true
  f_clear_state

  f_log_step "Rollback complete!"
  f_log_ok "${g_mountpoint} has been restored to its original location"
  f_json_ok '"message":"Rollback complete. ${g_mountpoint} restored to original location.","can_rollback":false'
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

function f_main {
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
    local f_data_device="" f_data_fstype="" f_data_size=""
    local f_data_used="" f_data_avail=""
    local f_luks_name="" f_luks_device="" f_luks_open="false"
    local f_needs_unlock="false" f_can_rollback="false"

    [[ -f "${f_state_file}" ]] && f_can_rollback="true"

    local f_df_out
    f_df_out=$(df -hT "${g_mountpoint}" 2>/dev/null | tail -1) || true
    if [[ -n "$f_df_out" ]]
    then
      set -- $f_df_out
      if [[ $# -ge 7 ]]
      then
        f_data_device="$1"
        f_data_fstype="$2"
        f_data_size="$3"
        f_data_used="$4"
        f_data_avail="$5"
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
      ls /dev/mapper/ 2>/dev/null | grep -qE 'symbios|luks' && f_luks_open="true"
    fi

    cat <<EOF
{"ok":true,"data_device":"$f_data_device","data_fstype":"$f_data_fstype","data_size":"$f_data_size","data_used":"$f_data_used","data_avail":"$f_data_avail","luks_name":"$f_luks_name","luks_device":"$f_luks_device","luks_open":$f_luks_open,"needs_unlock":$f_needs_unlock,"can_rollback":$f_can_rollback}
EOF
    ;;

  # ------------------------------------------------------------------
  setup)
    local f_device="${1:-}" f_encrypt="${2:-no}" f_password="${3:-}"

    [[ -z "$f_device" ]] && f_json_error "No device selected"
    [[ "$f_device" == /dev/* ]] || f_json_error "Invalid device path"

    # Read the LUKS passphrase from stdin when it was not passed as an
    # argument. The WebUI sends it via stdin so it never appears on the
    # command line (and thus not in `ps`, audit logs, or the exec overlay).
    if [[ "$f_encrypt" == "yes" ]] && [[ -z "$f_password" ]]
    then
      IFS= read -rs f_password || true
    fi
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
      if [[ "$f_cur_mount" == "${g_mountpoint}" ]]
      then
        f_json_error "This device is already mounted as ${g_mountpoint}"
      fi
      f_json_error "Device is mounted at $f_cur_mount. Unmount it first."
    fi

    local f_data_size f_disk_size
    f_data_size=$(du -sb "${g_mountpoint}/" 2>/dev/null | awk '{print $1}') || f_data_size=0
    f_disk_size=$(blockdev --getsize64 "$f_device" 2>/dev/null) || f_disk_size=0

    [[ "$f_data_size" -eq 0 ]] 2>/dev/null && \
      f_json_error "Could not determine ${g_mountpoint} size"
    [[ "$f_disk_size" -eq 0 ]] 2>/dev/null && \
      f_json_error "Could not determine disk size"

    local f_overhead=$(( 16 * 1024 * 1024 ))
    local f_data_margin=$(( f_data_size / 20 ))
    [[ "$f_data_margin" -gt "$f_overhead" ]] && f_overhead=$f_data_margin
    local f_needed=$(( f_data_size + f_overhead ))

    if [[ "$f_disk_size" -lt "$f_needed" ]]
    then
      local f_data_gb f_disk_gb f_needed_gb
      f_data_gb=$(awk "BEGIN {printf \"%.1f\", $f_data_size/1073741824}")
      f_disk_gb=$(awk "BEGIN {printf \"%.1f\", $f_disk_size/1073741824}")
      f_needed_gb=$(awk "BEGIN {printf \"%.1f\", $f_needed/1073741824}")
      f_json_error "Disk too small! ${g_mountpoint} is ${f_data_gb}G but disk is only ${f_disk_gb}G. Need at least ${f_needed_gb}G."
    fi

    f_log_step "Saving state for rollback"

    local f_old_fstab_line
    f_old_fstab_line=$(grep -E '[[:space:]]/symbios[[:space:]]' /etc/fstab 2>/dev/null || echo "")
    local f_old_home_device="" f_old_home_fstype=""
    if [[ -n "$f_root_dev" ]]
    then
      f_old_home_device="$f_root_dev"
      f_old_home_fstype="rootfs"
    else
      f_old_home_device=$(findmnt -n -o SOURCE "${g_mountpoint}" 2>/dev/null || echo "")
      f_old_home_fstype=$(findmnt -n -o FSTYPE "${g_mountpoint}" 2>/dev/null || echo "")
    fi

    f_save_state "$f_old_home_device" "$f_old_home_fstype" "$f_device" \
      "$f_encrypt" ${g_mapper_name} "$f_old_fstab_line"
    f_log_ok "State saved (can rollback later)"

    # Resume detection: if a previous run was interrupted (state file present,
    # the LUKS volume already open and /symbios.new mounted), we continue the
    # idempotent rsync instead of wiping the disk and copying from scratch.
    # This makes the migration robust against SSH drops / WebUI restarts.
    local f_resume=false f_new_source=""
    if f_load_state && [[ "$f_old_home_device" == "$old_device" ]]
    then
      f_new_source=$(findmnt -n -o SOURCE /symbios.new 2>/dev/null || true)
      if [[ "$f_encrypt" == "yes" ]] && [[ "$f_new_source" == "/dev/mapper/${g_mapper_name}" ]]
      then
        f_resume=true
      elif [[ "$f_encrypt" == "no" ]] && [[ -n "$f_new_source" ]]
      then
        f_resume=true
      fi
    fi
    if [[ "$f_resume" == "true" ]]
    then
      f_log "Interrupted migration detected - resuming copy (rsync continues where it stopped)"
    fi

    f_log_step "Preparing device"
     umount "$f_device" 2>/dev/null || true

    local f_luks_name=${g_mapper_name} f_target

    if [[ "$f_encrypt" == "yes" ]]
    then
      if [[ "$f_resume" == "true" ]]
      then
        f_log_ok "LUKS volume ${f_luks_name} already open - keeping it"
        f_target="/dev/mapper/$f_luks_name"
      else
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
      fi
    else
      f_target="$f_device"
    fi

    if [[ "$f_resume" == "true" ]]
    then
      f_log_ok "Temporary mount /symbios.new already present - keeping it"
    else
      f_log_step "Formatting $f_device as ext4"
      mkfs.ext4 -F -L "$g_data_label" "$f_target" 2>&1 || {
        f_setup_error "mkfs.ext4 failed"
      }
      f_log_ok "ext4 filesystem created"

      f_log_step "Mounting temporary partition"
      mkdir -p /symbios.new
      mount "$f_target" /symbios.new || {
        f_setup_error "Mount /symbios.new failed"
      }
      f_log_ok "Temporary mount at /symbios.new"
    fi

    f_log_step "Copying data from ${g_mountpoint} to new partition (rsync)"
    f_log "This may take a while for large ${g_mountpoint} directories..."

    # Docker/containerd data lives directly in ${g_mountpoint}/docker and
    # ${g_mountpoint}/containerd. Stop all containers so the data is consistent
    # and can be copied together with everything else. The WebUI container
    # (symbios-webui) must stay up — this script runs through its SSH exec
    # gateway, so stopping it would kill the migration mid-copy. OpenLDAP
    # keeps running too so the WebUI stays functional while it is stopped.
    if command -v docker &>/dev/null
    then
      f_log_step "Stopping non-essential Docker services for consistent copy"
      # Snapshot OpenLDAP before the copy so the data on the new disk is
      # consistent even though the LDAP container stays up during rsync.
      if docker ps --format '{{.Names}}' | grep -qx openldap
      then
        mkdir -p "${g_mountpoint}/backups"
        docker exec openldap slapcat -F /ldap-config/slapd.d \
          > "${g_mountpoint}/backups/ldap-pre-migration.ldif" 2>/dev/null || true
        f_log_ok "OpenLDAP snapshot saved to ${g_mountpoint}/backups"
      fi
      local f_cid f_cname
      for f_cid in $(docker ps -q)
      do
        f_cname=$(docker inspect --format '{{.Name}}' "$f_cid" 2>/dev/null)
        case "$f_cname" in
          */symbios-webui|*/openldap)
            f_log "Keeping $f_cname running"
            ;;
          *)
            docker stop "$f_cid" >/dev/null 2>&1 || true
            f_log "Stopped $f_cname"
            ;;
        esac
      done
      f_log_ok "Docker services stopped (symbios-webui and openldap kept running)"
    fi

    rsync -av --progress \
      --exclude='.trashed-*' \
      --exclude='.symbios-data-migration.state' \
      "${g_mountpoint}/" /symbios.new/ 2>&1 || {
      f_setup_error "rsync failed"
    }
    f_log_ok "Data copy complete"

    f_log_step "Unmounting old ${g_mountpoint}"
     umount "${g_mountpoint}" 2>/dev/null || true
    f_log_ok "Old ${g_mountpoint} unmounted"

    f_log_step "Cleaning old ${g_mountpoint} mount point"
    rm -rf "${g_mountpoint}"/* 2>/dev/null || true
    f_log_ok "Old ${g_mountpoint} cleaned"

    f_log_step "Updating /etc/fstab"
    sed -i '\#.*[[:space:]]/symbios[[:space:]]#d' /etc/fstab
    if [[ "$f_encrypt" == "yes" ]]
    then
      echo "/dev/mapper/$f_luks_name ${g_mountpoint} ext4 defaults,noatime,noauto 0 2" >> /etc/fstab
    else
      local f_uuid
      f_uuid=$(blkid -s UUID -o value "$f_device" 2>/dev/null) || {
        f_setup_error "blkid failed"
      }
      echo "UUID=$f_uuid ${g_mountpoint} ext4 defaults,noatime,noauto 0 2" >> /etc/fstab
    fi
    f_log_ok "fstab updated"

    f_log_step "Mounting new ${g_mountpoint}"
    mount "${g_mountpoint}" || {
      f_setup_error "Mount ${g_mountpoint} failed"
    }
    f_log_ok "${g_mountpoint} is now on new partition"

    if [[ "$f_encrypt" == "yes" ]]
    then
      echo "$f_luks_name" > /config/.luks-name 2>/dev/null || true
    fi

     umount /symbios.new 2>/dev/null || true
    rm -rf /symbios.new 2>/dev/null || true

    f_log_step "Migration complete!"
    f_log_ok "${g_mountpoint} is now on $f_device"
    f_log "Server will reboot in 1 minute to finalize. All services will restart automatically."
    if [[ "$f_encrypt" == "yes" ]]
    then
      f_log "You will need to enter your LUKS passphrase at the boot screen."
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
    umount "${g_mountpoint}" 2>/dev/null || true
    cryptsetup close ${g_mapper_name} 2>/dev/null || true
    f_json_ok '"message":"${g_mountpoint} unmounted and LUKS volume closed."'
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
    f_json_error "Usage: $0 {list|status|setup|rollback||change-password}"
    ;;
  esac
}

f_main "$@"
