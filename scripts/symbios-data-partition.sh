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

# symbios-data-partition.sh - Manage /symbios data partition (create, encrypt, mount, rollback)
#
# The /symbios data root holds all SymbiOS data (git repo, docker stacks,
# docker/containerd data dirs, homes, backups). Moving it to a separate
# (optionally LUKS-encrypted) disk keeps sensitive data off the root FS.
#
# Actions:
#   list                          List block devices (JSON, incl. serials)
#   byid                          Persistent /dev/disk/by-id names (JSON)
#   raid                          List RAID arrays + active swaps (JSON)
#   status                        Show /symbios mount + LUKS status (JSON)
#   setup <device> [encrypt=yes] [password-file=path]   Migrate /symbios to new disk
#   unlock <device> <password-file>   Open a LUKS device for inspection
#   lock <mapper|device>          Close an opened LUKS volume again
#   luks                          List LUKS devices + open state (JSON)
#   locate <device> [seconds]     Identify a disk by sustained reads
#   adopt <device> [--copy] [--check]   Use existing partition/mapper as /symbios
#   wipe <device> <mode>          Erase a disk (quick|zero|random|discard)
#   rollback                      Undo last migration, restore original /symbios
#                           Unmount /symbios and close LUKS
#   change-password <current-pw-file> <new-pw-file>   Change LUKS passphrase
#
# State file for rollback: /symbios/.symbios-data-migration.state

function f_usage {
  cat << EOF
Usage: $(basename "$0") <action> [args...]

Manage the /symbios data partition (create, encrypt, mount, rollback). The
/symbios data root holds all SymbiOS data (git repo, docker stacks,
docker/containerd data dirs, homes, backups). Moving it to a separate
(optionally LUKS-encrypted) disk keeps sensitive data off the root FS.

Actions:
  list                          List block devices (JSON, incl. serials)
  byid                          Persistent /dev/disk/by-id names (JSON)
  raid                          List RAID arrays + active swaps (JSON)
  status                        Show /symbios mount + LUKS status (JSON)
  setup <device> [encrypt=yes] [password-file=path]
                                Migrate /symbios to a new disk
  unlock <device> <password-file>
                                Open a LUKS device for inspection (no
                                mount, no formatting - use Adopt to make
                                it /symbios)
  lock <mapper|device>          Close an opened LUKS volume again
  luks                          List LUKS devices + open state (JSON)
  locate <device> [seconds]     Identify a disk by sustained reads
                                (dd, default 30s, max 120s)
  adopt <device> [--copy] [--check]
                                Use an existing partition (or open LUKS
                                mapper) as /symbios without formatting.
                                --copy migrates current data onto it,
                                --check only reports what would happen.
  wipe <device> <quick|zero|random|discard>
                                Erase a disk or partition for reuse
                                (RAID/LUKS members allowed on purpose,
                                the running system is refused)
  rollback                      Undo the last migration, restore original
                                /symbios (unmounts /symbios, closes LUKS)
  change-password <current-pw-file> <new-pw-file>
                                Change the LUKS passphrase
  help                          Show this help

State file for rollback: /symbios/.symbios-data-migration.state

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

# Append one locked-LUKS group to the raid JSON under construction
# (globals f_raid_luks/f_raid_luks_first, group in f_luks_group with
# f_luks_group_count members of f_luks_prev_size bytes). Groups of 2+
# become pair candidates; single devices are reported separately as
# f_raid_luks_single (e.g. a lone encrypted disk is not half a pair).
# Resets the group vars.
function f_luks_flush {
  if [[ "${f_luks_group_count}" -eq 1 ]]
  then
    local f_human
    f_human=$(numfmt --to=iec "${f_luks_prev_size}" 2>/dev/null || echo "${f_luks_prev_size}")
    [[ "${f_raid_luks_single_first}" == "yes" ]] || f_raid_luks_single="${f_raid_luks_single}, "
    f_raid_luks_single_first="no"
    f_raid_luks_single="${f_raid_luks_single}{\"size\":$(printf '%s' "${f_human}" | f_json_escape)"
    f_raid_luks_single="${f_raid_luks_single},\"device\":$(printf '/dev/%s' "${f_luks_prev_name}" | f_json_escape)}"
    f_luks_group="" f_luks_group_count=0 f_luks_parents="" f_luks_prev_name=""
    return 0
  fi
  [[ "${f_luks_group_count}" -ge 2 ]] || return 0
  local f_human
  f_human=$(numfmt --to=iec "${f_luks_prev_size}" 2>/dev/null || echo "${f_luks_prev_size}")
  [[ "${f_raid_luks_first}" == "yes" ]] || f_raid_luks="${f_raid_luks}, "
  f_raid_luks_first="no"
  f_raid_luks="${f_raid_luks}{\"size\":$(printf '%s' "${f_human}" | f_json_escape)"
  f_raid_luks="${f_raid_luks},\"members\":[${f_luks_group}]}"
  f_luks_group="" f_luks_group_count=0 f_luks_parents="" f_luks_prev_name=""
}

# Append one parsed `btrfs filesystem show` block to the raid JSON under
# construction (globals f_raid_btrfs/f_raid_btrfs_first, block data in
# f_b_label/f_b_uuid/f_b_devices/f_b_members). Resets the block vars.
function f_btrfs_flush {
  [[ -z "${f_b_uuid}" ]] && return 0
  local f_b_level="unknown" f_b_mount="" f_b_df=""
  f_b_mount=$(findmnt -n -o TARGET "UUID=${f_b_uuid}" 2>/dev/null || true)
  if [[ -n "${f_b_mount}" ]]
  then
    f_b_df=$(btrfs filesystem df "${f_b_mount}" 2>/dev/null | \
      awk '/^Data, /{gsub(/:.*/,"",$2); print $2; exit}' || true)
    [[ -n "${f_b_df}" ]] && f_b_level="${f_b_df}"
  fi
  [[ "${f_raid_btrfs_first}" == "yes" ]] || f_raid_btrfs="${f_raid_btrfs}, "
  f_raid_btrfs_first="no"
  f_raid_btrfs="${f_raid_btrfs}{\"label\":$(printf '%s' "${f_b_label}" | f_json_escape)"
  f_raid_btrfs="${f_raid_btrfs},\"uuid\":$(printf '%s' "${f_b_uuid}" | f_json_escape)"
  f_raid_btrfs="${f_raid_btrfs},\"devices\":\"${f_b_devices}\""
  f_raid_btrfs="${f_raid_btrfs},\"level\":$(printf '%s' "${f_b_level}" | f_json_escape)"
  f_raid_btrfs="${f_raid_btrfs},\"mountpoint\":$(printf '%s' "${f_b_mount}" | f_json_escape)"
  f_raid_btrfs="${f_raid_btrfs},\"members\":[${f_b_members}]}"
  f_b_label="" f_b_uuid="" f_b_devices="" f_b_members=""
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
  chmod 600 "${f_state_file}"
}

function f_load_state {
  if [[ ! -f "${f_state_file}" ]]
  then
    return 1
  fi
  # Read known variables explicitly instead of sourcing the file
  # to prevent code execution through a tampered state file
  f_old_device=$(grep '^old_device=' "${f_state_file}" | cut -d= -f2-)
  f_old_fstype=$(grep '^old_fstype=' "${f_state_file}" | cut -d= -f2-)
  f_new_device=$(grep '^new_device=' "${f_state_file}" | cut -d= -f2-)
  f_encrypt=$(grep '^encrypt=' "${f_state_file}" | cut -d= -f2-)
  f_luks_name=$(grep '^luks_name=' "${f_state_file}" | cut -d= -f2-)
  f_old_fstab_line=$(grep '^old_fstab_line=' "${f_state_file}" | cut -d= -f2-)
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

# Error handler for setup - rolls back and exits.
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
# Dispatch (flat - each action lives directly in its case branch)
# ---------------------------------------------------------------------------

function f_main {
  g_action="${1:-}"
  shift 2>/dev/null || true

  case "$g_action" in

  # ------------------------------------------------------------------
  list)
    # Major 7 (loop) is NOT excluded: loopback devices are the supported
    # way to try RAID/LUKS flows in the WebUI without touching real disks.
    # SERIAL tells identical models apart (e.g. two WD80EFZX with
    # different serials); /dev/disk/by-id names come from `byid`.
    lsblk -e 1,11,252 -J \
      -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,UUID,LABEL,TRAN,RM,SERIAL 2>&1 || \
      f_json_error "lsblk failed"
    ;;

  # ------------------------------------------------------------------
  byid)
    # Persistent /dev/disk/by-id names per device path as JSON. Unique
    # even for identical models (ata-WDC_WD80EFZX-..._VJH5312X vs
    # ..._VJH5VZKX). First pass takes readable ata/nvme/usb/mmc names,
    # the second pass fills gaps (wwn, ...). dm/lvm/md aliases never win.
    local f_byid_out="" f_byid_first="yes" f_byid_seen=""
    local f_b f_tgt f_devname f_short
    f_byid_add() {
      case " ${f_byid_seen} " in
        *" ${f_devname} "*) return 1 ;;
      esac
      f_byid_seen="${f_byid_seen} ${f_devname}"
      [[ "${f_byid_first}" == "yes" ]] || f_byid_out="${f_byid_out}, "
      f_byid_first="no"
      f_byid_out="${f_byid_out}$(printf '%s' "${f_devname}" | f_json_escape)"
      f_byid_out="${f_byid_out}:$(printf '%s' "${f_short}" | f_json_escape)"
      return 0
    }
    for f_b in /dev/disk/by-id/*
    do
      [[ -L "${f_b}" ]] || continue
      f_tgt=$(readlink "${f_b}") || continue
      f_devname="/dev/${f_tgt##*/}"
      f_short="${f_b##*/}"
      case "${f_short}" in
        ata-*|nvme-*|usb-*|mmc-*) f_byid_add || true ;;
      esac
    done
    for f_b in /dev/disk/by-id/*
    do
      [[ -L "${f_b}" ]] || continue
      f_tgt=$(readlink "${f_b}") || continue
      f_devname="/dev/${f_tgt##*/}"
      f_short="${f_b##*/}"
      case "${f_short}" in
        dm-*|lvm-*|md-*) continue ;;
      esac
      f_byid_add || true
    done
    f_json_ok "\"byid\":{${f_byid_out}}"
    ;;

  # ------------------------------------------------------------------
  raid)
    # Report RAID arrays (btrfs multi-device + mdadm) and active swaps
    # as JSON, so the WebUI can hide member disks from the setup target
    # select: formatting a member destroys the whole array, not just
    # that disk. Members are matched by /dev path in the caller.
    f_raid_btrfs=""
    f_raid_btrfs_first="yes"
    f_b_label="" f_b_uuid="" f_b_devices="" f_b_members=""
    while IFS= read -r f_line
    do
      if [[ "${f_line}" == Label:* ]]
      then
        f_btrfs_flush
        f_b_label="${f_line#*Label: }"
        f_b_label="${f_b_label%%  uuid:*}"
        f_b_label="${f_b_label//\'/}"
        f_b_uuid="${f_line##*uuid: }"
      elif [[ "${f_line}" == *"Total devices"* ]]
      then
        f_b_devices="${f_line#*Total devices }"
        f_b_devices="${f_b_devices%% *}"
      elif [[ "${f_line}" == *"path /dev/"* ]]
      then
        f_b_path="/dev/${f_line##*path /dev/}"
        f_b_path="${f_b_path%% *}"
        [[ -n "${f_b_members}" ]] && f_b_members="${f_b_members}, "
        f_b_members="${f_b_members}$(printf '%s' "${f_b_path}" | f_json_escape)"
      fi
    done < <(btrfs filesystem show 2>/dev/null || true)
    f_btrfs_flush
    f_raid_md=""
    f_raid_md_first="yes"
    if [[ -r /proc/mdstat ]]
    then
      while IFS= read -r f_line
      do
        if [[ "${f_line}" =~ ^(md[0-9]+)[[:space:]]*:[[:space:]]*active[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]
        then
          f_m_dev="/dev/${BASH_REMATCH[1]}"
          f_m_level="${BASH_REMATCH[2]}"
          f_m_rest="${BASH_REMATCH[3]}"
          f_m_members=""
          for f_m_tok in ${f_m_rest}
          do
            [[ "${f_m_tok}" == *\[*\]* ]] || continue
            f_m_tok="${f_m_tok%%\[*}"
            [[ -n "${f_m_members}" ]] && f_m_members="${f_m_members}, "
            f_m_members="${f_m_members}$(printf '/dev/%s' "${f_m_tok}" | f_json_escape)"
          done
          f_m_mount=$(findmnt -n -o TARGET "${f_m_dev}" 2>/dev/null || true)
          [[ "${f_raid_md_first}" == "yes" ]] || f_raid_md="${f_raid_md}, "
          f_raid_md_first="no"
          f_raid_md="${f_raid_md}{\"device\":$(printf '%s' "${f_m_dev}" | f_json_escape)"
          f_raid_md="${f_raid_md},\"level\":$(printf '%s' "${f_m_level}" | f_json_escape)"
          f_raid_md="${f_raid_md},\"mountpoint\":$(printf '%s' "${f_m_mount}" | f_json_escape)"
          f_raid_md="${f_raid_md},\"members\":[${f_m_members}]}"
        fi
      done < /proc/mdstat
    fi
    f_raid_swaps=""
    f_raid_swaps_first="yes"
    while IFS= read -r f_swap
    do
      [[ -z "${f_swap}" ]] && continue
      [[ "${f_raid_swaps_first}" == "yes" ]] || f_raid_swaps="${f_raid_swaps}, "
      f_raid_swaps_first="no"
      f_raid_swaps="${f_raid_swaps}$(printf '%s' "${f_swap}" | f_json_escape)"
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
    # Locked LUKS pairs: same-size crypto_LUKS partitions on different
    # disks are likely one encrypted RAID/filesystem, but locked devices
    # hide their content (btrfs/mdadm cannot see them). Report as
    # unverified candidates - never as fact. Swap partitions are
    # excluded (same-size swap pairs are normal, not RAID).
    f_raid_luks=""
    f_raid_luks_first="yes"
    f_raid_luks_single=""
    f_raid_luks_single_first="yes"
    f_luks_prev_size="" f_luks_group="" f_luks_group_count=0
    f_luks_parents="" f_luks_prev_name=""
    # Column order NAME,SIZE,FSTYPE,PKNAME: the parent may be empty
    # (loop/whole-disk LUKS) and a trailing empty field survives read,
    # while an empty middle field would shift everything (loop6 bug).
    while read -r f_l_name f_l_size f_l_fstype f_l_parent
    do
      [[ "${f_l_fstype}" == "crypto_LUKS" ]] || continue
      # Open (unlocked) LUKS shows its content via btrfs/mdadm already -
      # only still-locked devices belong into pairs/singles.
      if lsblk -n -l -o TYPE "/dev/${f_l_name}" 2>/dev/null | grep -qx "crypt"
      then
        continue
      fi
      # Whole-disk LUKS has no parent: use its own name so two such
      # disks can still pair, while same-disk partitions never do.
      [[ -z "${f_l_parent}" ]] && f_l_parent="${f_l_name}"
      if [[ -n "${f_luks_prev_size}" ]] && [[ "${f_l_size}" == "${f_luks_prev_size}" ]] && \
         [[ " ${f_luks_parents} " != *" ${f_l_parent} "* ]]
      then
        if [[ "${f_luks_group_count}" -eq 1 ]]
        then
          f_luks_group="$(printf '/dev/%s' "${f_luks_prev_name}" | f_json_escape), "
        fi
        f_luks_group="${f_luks_group}$(printf '/dev/%s' "${f_l_name}" | f_json_escape)"
        f_luks_group_count=$((f_luks_group_count + 1))
        f_luks_parents="${f_luks_parents} ${f_l_parent}"
      else
        f_luks_flush
        f_luks_prev_size="${f_l_size}"
        f_luks_parents=" ${f_l_parent} "
        f_luks_prev_name="${f_l_name}" f_luks_group="" f_luks_group_count=1
      fi
    done < <(lsblk -n -l -b -o NAME,SIZE,FSTYPE,PKNAME 2>/dev/null | sort -k2,2n -k1,1 || true)
    f_luks_flush
    f_json_ok "\"btrfs\":[${f_raid_btrfs}],\"mdadm\":[${f_raid_md}],\"active_swaps\":[${f_raid_swaps}],\"luks_pairs\":[${f_raid_luks}],\"luks_singles\":[${f_raid_luks_single}]"
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
    local f_device="${1:-}" f_encrypt="${2:-no}" f_password_file="${3:-}"
    local f_password=""

    [[ -z "$f_device" ]] && f_json_error "No device selected"
    [[ "$f_device" == /dev/* ]] || f_json_error "Invalid device path"

    # Read the LUKS passphrase from the secret file if provided
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

    # Refuse targets whose formatting would destroy data beyond the
    # selected device: RAID members (kills the whole array, possibly on
    # other disks), LUKS/LVM holders (encrypted data), active swap,
    # anything mounted anywhere in the subtree, and devices that are
    # neither a whole disk nor an mdadm array. Whole mdadm arrays ARE
    # valid targets (migrating /symbios onto a RAID) - formatting one
    # only affects the array itself, never its former members' data
    # beyond it. The WebUI hides refused devices from the target
    # select; this is the server-side backstop against forged requests.
    local f_tree
    f_tree=$(lsblk -n -l -o NAME,TYPE,FSTYPE,MOUNTPOINT "$f_device" 2>/dev/null) || \
      f_json_error "Cannot inspect $f_device"
    [[ -z "$f_tree" ]] && f_json_error "Unknown device: $f_device"
    local f_top_type f_top_label
    f_top_type=$(echo "$f_tree" | head -1 | awk '{print $2}')
    f_top_label="${f_top_type}"
    [[ "${f_top_type}" == "part" ]] && f_top_label="partition"
    [[ "${f_top_type}" == "raid" ]] && f_top_label="RAID array"
    if [[ "${f_top_type}" != "disk" ]] && [[ "${f_top_type}" != "raid" ]]
    then
      f_json_error "$f_device is a ${f_top_label}, not a whole disk or RAID array."
    fi
    local f_row f_name f_type f_fstype f_mount
    while read -r f_name f_type f_fstype f_mount
    do
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
    if f_load_state && [[ "$f_old_home_device" == "$f_old_device" ]]
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
      # quota+project enable ext4 project quotas for the media directories
      # (enforced per-directory limits, see base-services/media.yml).
      mkfs.ext4 -F -O quota,project -L "$g_data_label" "$f_target" 2>&1 || {
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
    # (symbios-base-webui) must stay up - this script runs through its SSH exec
    # gateway, so stopping it would kill the migration mid-copy. OpenLDAP
    # keeps running too so the WebUI stays functional while it is stopped.
    if command -v docker &>/dev/null
    then
      f_log_step "Stopping non-essential Docker services for consistent copy"
      # Snapshot OpenLDAP before the copy so the data on the new disk is
      # consistent even though the LDAP container stays up during rsync.
      if docker ps --format '{{.Names}}' | grep -qx symbios-base-ldap
      then
        mkdir -p "${g_mountpoint}/backups"
        docker exec symbios-base-ldap slapcat -F /ldap-config/slapd.d \
          > "${g_mountpoint}/backups/ldap-pre-migration.ldif" 2>/dev/null || true
        f_log_ok "OpenLDAP snapshot saved to ${g_mountpoint}/backups"
      fi
      local f_cid f_cname
      for f_cid in $(docker ps -q)
      do
        f_cname=$(docker inspect --format '{{.Name}}' "$f_cid" 2>/dev/null)
        case "$f_cname" in
          */symbios-base-webui|*/symbios-base-ldap)
            f_log "Keeping $f_cname running"
            ;;
          *)
            docker stop "$f_cid" >/dev/null 2>&1 || true
            f_log "Stopped $f_cname"
            ;;
        esac
      done
      f_log_ok "Docker services stopped (symbios-base-webui and symbios-base-ldap kept running)"
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
      # nofail: never wait at boot for a locked/missing volume (boot-unlock
      # via console prompt or web page happens after boot, see symbios-boot-unlock).
      echo "/dev/mapper/$f_luks_name ${g_mountpoint} ext4 defaults,noatime,nofail,noauto,prjquota 0 2" >> /etc/fstab
    else
      local f_uuid
      f_uuid=$(blkid -s UUID -o value "$f_device" 2>/dev/null) || {
        f_setup_error "blkid failed"
      }
      echo "UUID=$f_uuid ${g_mountpoint} ext4 defaults,noatime,nofail,noauto,prjquota 0 2" >> /etc/fstab
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
    shutdown -r +1 "Disk migration complete - rebooting." 2>/dev/null || true
    f_log_ok "Reboot scheduled in 1 minute"

    f_json_ok '"message":"Disk migration complete. The server will reboot in about 1 minute. All services will restart automatically. You will need to enter your LUKS passphrase at the boot screen.","can_rollback":true'
    ;;

  # ------------------------------------------------------------------
  unlock)
    # Open a LUKS device for inspection only: no mount, no formatting.
    # The caller picks the exact device (several LUKS volumes may exist).
    # Mapper: symbios-luks for the SymbiOS data volume, unlock-<name>
    # for anything else. Report the mapper so the WebUI can point at
    # the RAID pages for a look inside.
    local f_device="${1:-}" f_pw_file="${2:-}" f_password=""
    [[ -z "${f_device}" ]] && f_json_error "No device selected"
    [[ "${f_device}" == /dev/* ]] || f_json_error "Invalid device path"
    [[ -z "${f_pw_file}" ]] && f_json_error "Password file is required"
    local f_unlock_fs
    f_unlock_fs=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    [[ "${f_unlock_fs}" == "crypto_LUKS" ]] || \
      f_json_error "${f_device} is not a LUKS device (found: ${f_unlock_fs:-nothing})."
    if [[ -f "${f_pw_file}" ]]
    then
      IFS= read -rs f_password < "${f_pw_file}" || true
      rm -f "${f_pw_file}" 2>/dev/null || true
    fi
    [[ -z "${f_password}" ]] && f_json_error "Passphrase is required"
    local f_want_mapper="${g_mapper_name}"
    local f_data_luks
    f_data_luks=$(f_find_luks)
    if [[ -n "${f_data_luks}" ]] && [[ "${f_device}" != "/dev/${f_data_luks}" ]]
    then
      # Bash expansion (not basename|tr): basename's trailing newline
      # was translated into a "-" suffix (unlock-sdb3- bug).
      local f_base="${f_device##*/}"
      f_base="${f_base//[^a-zA-Z0-9]/-}"
      f_base="${f_base%-}"
      f_want_mapper="unlock-${f_base}"
    fi
    if [[ -e "/dev/mapper/${f_want_mapper}" ]]
    then
      f_log_ok "${f_device} already open as ${f_want_mapper}"
    else
      f_log_step "Opening ${f_device} as ${f_want_mapper}"
      printf '%s' "${f_password}" | cryptsetup open "${f_device}" "${f_want_mapper}" || \
        f_json_error "Failed to open ${f_device}. Is the passphrase correct?"
      f_log_ok "LUKS volume opened"
    fi
    f_password=""
    local f_mapper_dev="/dev/mapper/${f_want_mapper}"
    local f_inner_fs
    f_inner_fs=$(blkid -s TYPE -o value "${f_mapper_dev}" 2>/dev/null || true)
    [[ -z "${f_inner_fs}" ]] && f_inner_fs="unknown (still encrypted or empty)"
    f_json_ok "\"message\":\"${f_device} opened as ${f_mapper_dev} (${f_inner_fs}) - nothing mounted, nothing formatted.\",\"mapper\":\"${f_mapper_dev}\",\"fstype\":\"${f_inner_fs}\""
    ;;

  # ------------------------------------------------------------------
  lock)
    # Close an opened LUKS mapper again (by mapper name or source device).
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
    [[ "${f_mapper}" == "${g_mapper_name}" ]] && \
      findmnt -n -o TARGET "${g_mountpoint}" 2>/dev/null | grep -qx "${g_mountpoint}" && \
      f_json_error "This mapper holds the mounted /symbios - unmount it first."
    cryptsetup close "${f_mapper}" 2>&1 || \
      f_json_error "Could not close ${f_mapper} (still mounted?)."
    f_json_ok "\"message\":\"${f_mapper} closed.\""
    ;;

  # ------------------------------------------------------------------
  luks)
    # List all LUKS devices with label/uuid/size and open state as JSON,
    # so the WebUI unlock dialog can offer an explicit device choice.
    local f_luks_out="" f_luks_first="yes"
    local f_l_name f_l_size f_l_label f_l_uuid f_l_mapper f_l_open
    while read -r f_l_name f_l_size
    do
      [[ -z "${f_l_name}" ]] && continue
      f_l_label=$(blkid -s LABEL -o value "/dev/${f_l_name}" 2>/dev/null || true)
      f_l_uuid=$(blkid -s UUID -o value "/dev/${f_l_name}" 2>/dev/null || true)
      f_l_mapper=$(lsblk -n -l -o NAME,TYPE "/dev/${f_l_name}" 2>/dev/null | \
        awk '$2 == "crypt" {print $1; exit}')
      f_l_open="false"
      [[ -n "${f_l_mapper}" ]] && f_l_open="true"
      [[ "${f_luks_first}" == "yes" ]] || f_luks_out="${f_luks_out}, "
      f_luks_first="no"
      # Parent disk identity (model/serial/by-id): partitions of
      # identical disks (sdb3 vs sdc3) are otherwise indistinguishable.
      local f_l_parent f_l_model f_l_serial f_l_byid
      f_l_parent=$(lsblk -n -l -o PKNAME "/dev/${f_l_name}" 2>/dev/null | head -1 || true)
      f_l_model=""
      f_l_serial=""
      f_l_byid=""
      if [[ -n "${f_l_parent}" ]]
      then
        f_l_model=$(lsblk -n -l -o MODEL "/dev/${f_l_parent}" 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//' || true)
        f_l_serial=$(lsblk -n -l -o SERIAL "/dev/${f_l_parent}" 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//' || true)
        f_l_byid=""
        for f_b in /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-* /dev/disk/by-id/usb-* /dev/disk/by-id/mmc-*
        do
          [[ -L "${f_b}" ]] || continue
          if [[ "$(readlink "${f_b}" 2>/dev/null)" == *"${f_l_parent}" ]]
          then
            f_l_byid=$(basename "${f_b}")
            break
          fi
        done 2>/dev/null
      fi
      f_luks_out="${f_luks_out}{\"device\":\"/dev/${f_l_name}\""
      f_luks_out="${f_luks_out},\"size_bytes\":${f_l_size:-0}"
      f_luks_out="${f_luks_out},\"label\":$(printf '%s' "${f_l_label}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"uuid\":$(printf '%s' "${f_l_uuid}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"open\":${f_l_open}"
      f_luks_out="${f_luks_out},\"mapper\":$(printf '%s' "${f_l_mapper}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"parent\":$(printf '%s' "${f_l_parent}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"model\":$(printf '%s' "${f_l_model}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"serial\":$(printf '%s' "${f_l_serial}" | f_json_escape)"
      f_luks_out="${f_luks_out},\"byid\":$(printf '%s' "${f_l_byid}" | f_json_escape)}"
    done < <(lsblk -n -l -b -o NAME,SIZE,FSTYPE 2>/dev/null | \
      awk '$3 == "crypto_LUKS" {print $1, $2}' || true)
    f_json_ok "\"devices\":[${f_luks_out}]"
    ;;

  # ------------------------------------------------------------------
  adopt)
    # Use an existing partition or open mapper as /symbios without formatting.
    local f_device="${1:-}" f_copy="no" f_check="no" f_arg
    # Shift ONE (the device): shifting more would silently drop --copy
    # and --check and turn a dry run into a real adopt (seen live once).
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
    # Adopt works on a partition, a loop device (testing), an md array
    # or an open mapper - never on a bare disk with a partition table
    # (mounting that would hide the partitions). A disk carrying a
    # filesystem directly (e.g. a USB stick) is fine.
    local f_adopt_type=""
    if [[ "${f_device}" == /dev/md* ]] || [[ "${f_device}" == /dev/mapper/* ]]
    then
      f_adopt_type="virtual"
    else
      f_adopt_type=$(lsblk -n -l -o TYPE "${f_device}" 2>/dev/null | head -1) || \
        f_json_error "Unknown device: ${f_device}"
    fi
    local f_adopt_fs f_adopt_label f_adopt_uuid
    f_adopt_fs=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    f_adopt_label=$(blkid -s LABEL -o value "${f_device}" 2>/dev/null || true)
    f_adopt_uuid=$(blkid -s UUID -o value "${f_device}" 2>/dev/null || true)
    case "${f_adopt_type}" in
      part|loop|virtual)
        ;;
      disk)
        # Bare disk only when it holds the filesystem directly.
        if [[ "${f_adopt_fs}" != "ext4" ]] && [[ "${f_adopt_fs}" != "btrfs" ]]
        then
          f_json_error "${f_device} is a whole disk without a directly usable filesystem - adopt needs a partition, md array or open LUKS mapper."
        fi
        ;;
      *)
        f_json_error "${f_device} is a ${f_adopt_type:-unknown device} - adopt needs a partition, loop device, md array or open LUKS mapper."
        ;;
    esac
    [[ -z "${f_adopt_fs}" ]] && f_json_error "${f_device} has no detectable filesystem. Format it via Move Data first."
    case "${f_adopt_fs}" in
      ext4|btrfs)
        ;;
      crypto_LUKS|swap|LVM2_member|linux_raid_member)
        f_json_error "${f_device} holds ${f_adopt_fs} - unlock or break it up first, then adopt the filesystem inside."
        ;;
      *)
        f_json_error "${f_device} has filesystem ${f_adopt_fs} - only ext4 or btrfs can hold /symbios."
        ;;
    esac
    local f_cur_mount
    f_cur_mount=$(findmnt -n -o TARGET "${f_device}" 2>/dev/null || true)
    if [[ -n "${f_cur_mount}" ]] && [[ "${f_cur_mount}" != "${g_mountpoint}" ]]
    then
      f_json_error "${f_device} is mounted at ${f_cur_mount}. Unmount it first."
    fi
    if [[ "${f_cur_mount}" == "${g_mountpoint}" ]]
    then
      f_json_ok '"message":"This device is already mounted as /symbios.","can_rollback":false'
    fi
    # Trial mount read-only to verify the filesystem opens cleanly.
    mkdir -p /symbios.new
    if ! mount -o ro "${f_device}" /symbios.new 2>/dev/null
    then
      f_json_error "${f_device} could not be mounted read-only. Check the filesystem (fsck/btrfs check) first."
    fi
     umount /symbios.new 2>/dev/null || true
    # Without --copy the current data stays where it is as a fallback -
    # so adopting away from a rootfs-backed /symbios without copying
    # would orphan live data: refuse that combination outright. This
    # runs before --check so a dry run reports the real outcome.
    local f_old_fstab_line f_old_home_device f_old_home_fstype f_old_is_mount
    f_old_fstab_line=$(grep -E '[[:space:]]/symbios[[:space:]]' /etc/fstab 2>/dev/null || echo "")
    f_old_home_device=$(findmnt -n -o SOURCE "${g_mountpoint}" 2>/dev/null || echo "")
    f_old_home_fstype=$(findmnt -n -o FSTYPE "${g_mountpoint}" 2>/dev/null || echo "rootfs")
    f_old_is_mount="yes"
    if [[ -z "${f_old_home_device}" ]]
    then
      f_old_is_mount="no"
      f_old_home_device=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    fi
    if [[ "${f_old_is_mount}" == "no" ]] && [[ "${f_copy}" == "no" ]]
    then
      f_json_error "/symbios currently lives on the root filesystem. Adopting without --copy would orphan that data - rerun with Copy enabled."
    fi
    if [[ "${f_check}" == "yes" ]]
    then
      local f_adopt_size
      f_adopt_size=$(blockdev --getsize64 "${f_device}" 2>/dev/null || echo 0)
      f_json_ok "\"message\":\"Adopt check OK: ${f_adopt_fs} filesystem (${f_adopt_size} bytes) can become /symbios.\",\"fstype\":\"${f_adopt_fs}\",\"label\":\"${f_adopt_label}\",\"copy\":\"${f_copy}\""
    fi
    # Save rollback state, then switch fstab to the adopted device.
    f_save_state "${f_old_home_device}" "${f_old_home_fstype}" "${f_device}" \
      "no" "" "${f_old_fstab_line}"
    f_log_ok "State saved (can rollback later)"
    if [[ "${f_copy}" == "yes" ]]
    then
      f_log_step "Copying current ${g_mountpoint} onto adopted device"
      mkdir -p /symbios.new
      mount "${f_device}" /symbios.new || f_setup_error "Mount adopted device failed"
      rsync -av --progress \
        --exclude='.trashed-*' \
        --exclude='.symbios-data-migration.state' \
        "${g_mountpoint}/" /symbios.new/ 2>&1 || {
         umount /symbios.new 2>/dev/null || true
        f_setup_error "rsync failed"
      }
       umount /symbios.new 2>/dev/null || true
      f_log_ok "Data copy complete"
    fi
    f_log_step "Switching ${g_mountpoint} to adopted device"
     umount "${g_mountpoint}" 2>/dev/null || true
    # Only clean the old mountpoint when the data was just copied onto
    # the new device. Without --copy the old location is the fallback
    # and must never be deleted (deleting it destroyed a live system
    # once - the old data is simply covered by the new mount instead).
    if [[ "${f_copy}" == "yes" ]]
    then
      rm -rf "${g_mountpoint}"/* 2>/dev/null || true
    fi
    sed -i '\#.*[[:space:]]/symbios[[:space:]]#d' /etc/fstab
    if [[ "${f_device}" == /dev/mapper/* ]]
    then
      echo "${f_device} ${g_mountpoint} ${f_adopt_fs} defaults,noatime,nofail,noauto 0 2" >> /etc/fstab
    elif [[ -n "${f_adopt_uuid}" ]]
    then
      echo "UUID=${f_adopt_uuid} ${g_mountpoint} ${f_adopt_fs} defaults,noatime,nofail,noauto 0 2" >> /etc/fstab
    else
      echo "${f_device} ${g_mountpoint} ${f_adopt_fs} defaults,noatime,nofail,noauto 0 2" >> /etc/fstab
    fi
    mount "${g_mountpoint}" || f_setup_error "Mount ${g_mountpoint} failed"
    f_log_ok "${g_mountpoint} is now on ${f_device} (${f_adopt_fs}, data kept)"
    f_json_ok '"message":"Adopted existing filesystem as /symbios without formatting.","can_rollback":true'
    ;;

  # ------------------------------------------------------------------
  locate)
    # Identify a physical disk by sustained reads: watch the activity
    # LED or listen. Single home for disk location (was duplicated on
    # both RAID pages before).
    local f_dev="${1:-}" f_secs="${2:-30}"
    [[ -z "${f_dev}" ]] && f_json_error "Usage: $0 locate <device> [seconds]"
    [[ "${f_dev}" == /dev/* ]] || f_json_error "Invalid device path"
    [[ "${f_secs}" =~ ^[0-9]+$ ]] || f_secs=30
    [[ "${f_secs}" -gt 120 ]] && f_secs=120
    f_log "Reading ${f_dev} for ${f_secs}s - watch the activity LED or listen"
    timeout "${f_secs}" dd "if=${f_dev}" of=/dev/null bs=1M iflag=direct 2>&1 | tail -2 || true
    f_json_ok '"message":"Locate read finished."'
    ;;

  # ------------------------------------------------------------------
  wipe)
    # Destroy all data on a disk or partition so it can be reused
    # (e.g. as a Move Data target): quick (signatures + first 10MiB),
    # zero (whole disk zeros), random (whole disk urandom) or discard
    # (instant blkdiscard for SSD/NVMe, fails cleanly on HDDs).
    # RAID members and LUKS holders are ALLOWED on purpose - clearing
    # them is the job. Only the running system is untouchable.
    local f_device="${1:-}" f_w_mode="${2:-}"
    [[ -z "${f_device}" ]] && f_json_error "No device selected"
    [[ "${f_device}" == /dev/* ]] || f_json_error "Invalid device path"
    case "${f_w_mode}" in
      quick|zero|random|discard)
        ;;
      *)
        f_json_error "Mode must be quick, zero, random or discard"
        ;;
    esac
    local f_w_type
    f_w_type=$(lsblk -n -l -o TYPE "${f_device}" 2>/dev/null | head -1) || \
      f_json_error "Unknown device: ${f_device}"
    case "${f_w_type}" in
      disk|part|loop)
        ;;
      *)
        f_json_error "${f_device} is a ${f_w_type:-unknown device} - wipe needs a disk, partition or loop device."
        ;;
    esac
    # Never touch the disk the running system lives on.
    local f_w_root_src f_w_root_disk f_w_dev_disk
    f_w_root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    f_w_root_disk=$(lsblk -n -l -o PKNAME "${f_w_root_src}" 2>/dev/null | head -1 || true)
    [[ -z "${f_w_root_disk}" ]] && f_w_root_disk=$(basename "${f_w_root_src}" | sed 's/p\?[0-9]*$//')
    if [[ "${f_w_type}" == "disk" || "${f_w_type}" == "loop" ]]
    then
      f_w_dev_disk=$(basename "${f_device}")
    else
      f_w_dev_disk=$(lsblk -n -l -o PKNAME "${f_device}" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "${f_w_root_disk}" ]] && [[ "${f_w_dev_disk}" == "${f_w_root_disk}" ]]
    then
      f_json_error "${f_device} lives on the system disk (${f_w_root_disk}) - wiping it would kill the running system."
    fi
    # Refuse anything mounted (self or children) and active swap.
    local f_w_mounts
    f_w_mounts=$(lsblk -n -l -o MOUNTPOINT "${f_device}" 2>/dev/null | grep -v '^$' || true)
    if [[ -n "${f_w_mounts}" ]]
    then
      f_json_error "${f_device} is mounted (${f_w_mounts//$'\n'/, }) - unmount it first."
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${f_device}"
    then
      f_json_error "${f_device} is active swap - swap it off first."
    fi
    local f_w_was
    f_w_was=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    [[ -z "${f_w_was}" ]] && f_w_was="unformatted"
    if [[ "${f_w_mode}" == "discard" ]]
    then
      # blkdiscard only works where the device supports it (SSD/NVMe).
      if ! blkdiscard "${f_device}" 2>&1
      then
        f_json_error "blkdiscard not supported on ${f_device} - use zero or random instead."
      fi
      f_log_ok "Discard complete"
    else
      if [[ "${f_w_mode}" == "quick" ]]
      then
        f_log_step "Removing signatures on ${f_device}"
        wipefs -a "${f_device}" 2>&1 || f_json_error "wipefs failed"
        f_log_step "Zeroing first 10MiB on ${f_device}"
        dd if=/dev/zero "of=${f_device}" bs=1M count=10 conv=fsync status=progress 2>&1 | tail -2 || \
          f_json_error "dd failed"
      elif [[ "${f_w_mode}" == "zero" ]]
      then
        f_log_step "Zeroing ${f_device} completely (takes a while)"
        dd if=/dev/zero "of=${f_device}" bs=4M conv=fsync status=progress 2>&1 | tail -2 || \
          f_json_error "dd failed"
      else
        f_log_step "Overwriting ${f_device} with random data (takes a long while)"
        dd if=/dev/urandom "of=${f_device}" bs=4M conv=fsync status=progress 2>&1 | tail -2 || \
          f_json_error "dd failed"
      fi
      f_log_ok "Write complete"
    fi
    blockdev --rereadpt "${f_device}" 2>/dev/null || partprobe "${f_device}" 2>/dev/null || true
    local f_w_now
    f_w_now=$(blkid -s TYPE -o value "${f_device}" 2>/dev/null || true)
    if [[ -n "${f_w_now}" ]]
    then
      f_json_error "Wipe ran but ${f_device} still shows ${f_w_now} - inspect manually."
    fi
    f_json_ok "\"message\":\"${f_device} wiped (${f_w_mode}; was: ${f_w_was}) - ready to reuse.\""
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
    local f_current_pw_file="${1:-}" f_new_pw_file="${2:-}"
    local f_current_password="" f_new_password=""

    [[ -z "$f_current_pw_file" ]] && f_json_error "Current password file is required"
    [[ -z "$f_new_pw_file" ]] && f_json_error "New password file is required"

    # Read passwords from secret files
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

  help|-h|--help)
    f_usage
    ;;

  *)
    f_json_error "Usage: $0 {list|byid|raid|status|setup|unlock|lock|luks|locate|adopt|wipe|rollback|change-password}"
    ;;
  esac
}

f_main "$@"
