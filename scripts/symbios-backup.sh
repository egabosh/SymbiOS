#!/bin/bash
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
#
# symbios-backup.sh - SymbiOS main backup engine.
#
# Backs up the whole data root (/symbios - configuration, services, docker
# volumes and the pre-run database dumps from backup.d/):
#
#   - No restic target configured : local hardlink snapshot below
#                                   ${data_root}/backup (g_backup fallback)
#   - Restic target(s) configured : restic snapshot over SFTP to every
#                                   configured server (primary + the
#                                   backup_servers list), each with its own
#                                   retention policy and a repository in
#                                   PATH/$(hostname)/
#
# Called by scripts/backup.sh (cron /etc/cron.d/backup_local, nightly 00:05).
# Status is written to ${g_log_dir}/backup-status.json for the WebUI and the
# backup healthcheck.

# Load gaboshlib (g_echo*, g_backup, g_lockfile, ...) and the SymbiOS libs.
# Passphrase subcommands print JSON on stdout: skip the gaboshlib stdout/stderr
# FIFO redirection (g_all-to-syslog) so the output stays machine-parseable.

function f_usage {
  echo "Usage: $(basename "$0") [command]"
  echo ""
  echo "SymbiOS main backup engine. Backs up the whole data root (/symbios -"
  echo "configuration, services, docker volumes and the pre-run database dumps"
  echo "from backup.d/) using restic over SFTP:"
  echo "  - Server configured            : restic snapshot over SFTP"
  echo "                                   (repository in PATH/$(hostname)/)"
  echo ""
  echo "Called by scripts/backup.sh (cron /etc/cron.d/backup_local, nightly 00:05)."
  echo "Status is written to <log>/backup-status.json for the WebUI."
  echo ""
  echo "Commands:"
  echo "  gen-passphrase    Ensure the backup encryption passphrase file exists"
  echo "                    and print it as JSON (never overwrites an existing)"
  echo "  get-passphrase    Print the current backup passphrase as JSON"
  echo "  gen-restic-passphrase Ensure the restic password file exists under /symbios"
  echo "                        and print its path as JSON"
  echo "  get-restic-passphrase  Print the restic password file path as JSON"
  echo "  help              Show this help"
  echo ""
  echo "Options:"
  echo "  -h, --help        Show this help and exit"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]
then
  f_usage
  exit 0
fi

[[ "${1:-}" == "gen-passphrase" || "${1:-}" == "get-passphrase" || "${1:-}" == "gen-restic-passphrase" || "${1:-}" == "get-restic-passphrase" ]] && g_alltosyslog=1
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

# Read all backup settings from inventory.yml.
f_bk_read_vars

# Make sure the passphrase file exists; generate one on first use so the
# nightly cron never fails just because nobody opened the WebUI page.
function f_ensure_passphrase {
  if [[ -s "$g_bk_pw_file" ]]
  then
    return 0
  fi
  local f_pw
  f_pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  umask 077
  echo "$f_pw" > "$g_bk_pw_file"
  umask 022
  chown root:root "$g_bk_pw_file"
  g_echo_warn "Generated a new backup passphrase (${g_bk_pw_file})."
  g_echo_warn "View/store it via WebUI -> Settings -> Backup ('Show passphrase')!"
}

function f_ensure_restic_passphrase {
  local f_pwfile="${g_bk_restic_pw_file:-${g_config_dir}/.backup_restic_password}"
  if [[ ! -d "$(dirname "$f_pwfile")" ]]; then
    mkdir -p "$(dirname "$f_pwfile")"
    chmod 750 "$(dirname "$f_pwfile")" 2>/dev/null
  fi
  if [[ -s "$f_pwfile" ]]; then
    return 0
  fi
  local f_pw
  f_pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
  umask 077
  printf '%s' "$f_pw" > "$f_pwfile"
  umask 022
  chown root:root "$f_pwfile" 2>/dev/null
  chmod 600 "$f_pwfile"
  g_echo_warn "Generated a new restic password (${f_pwfile})."
}

# Query subcommands used by the WebUI - no lock, never start a backup.
case "$1" in
  gen-passphrase)
    # Generate a passphrase only if none exists yet (never overwrite!)
    if [[ -s "$g_bk_pw_file" ]]
    then
      printf '{"ok":true,"generated":false,"passphrase":%s}\n' \
        "$(cat "$g_bk_pw_file" | f_json_escape)"
    else
      f_ensure_passphrase
      printf '{"ok":true,"generated":true,"passphrase":%s}\n' \
        "$(cat "$g_bk_pw_file" | f_json_escape)"
    fi
    exit 0 ;;
  get-passphrase)
    printf '{"ok":true,"passphrase":%s}\n' \
      "$(cat "$g_bk_pw_file" 2>/dev/null | f_json_escape)"
    exit 0 ;;
  gen-restic-passphrase)
    f_ensure_restic_passphrase
    printf '{"ok":true,"generated":true,"path":%s}\n' \
      "$(printf '%s' "${g_bk_restic_pw_file:-${g_config_dir}/.backup_restic_password}" | f_json_escape)"
    exit 0 ;;
  get-restic-passphrase)
    printf '{"ok":true,"path":%s}\n' \
      "$(printf '%s' "${g_bk_restic_pw_file:-${g_config_dir}/.backup_restic_password}" | f_json_escape)"
    exit 0 ;;
esac

g_lockfile
g_nice
g_all-to-syslog
set -o pipefail

# Write the run status for the WebUI/healthcheck.
# Usage: f_write_status <state> <target> <snapshot-date> <message> [extra-json]
function f_write_status {
  local f_state="$1" f_target="$2" f_snap="$3" f_msg="$4" f_extra="$5"
  local f_now
  f_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    printf '{"state":"%s","finished":"%s","target":"%s","snapshot":"%s","message":%s' \
      "$f_state" "$f_now" "$f_target" "$f_snap" "$(printf '%s' "$f_msg" | f_json_escape)"
    if [[ -n "$f_extra" ]]
    then
      printf ',%s' "$f_extra"
    fi
    printf '}'
  } > "${g_log_dir}/backup-status.json.tmp"
  mv "${g_log_dir}/backup-status.json.tmp" "${g_log_dir}/backup-status.json"
  # Success marker consumed by the healthcheck (epoch seconds).
  if [[ "$f_state" == "ok" ]]
  then
    date +%s > "${g_log_dir}/backup-last-success"
  fi
}

# Build restic exclude file from rsync-style excludes
function f_bk_build_restic_excludes {
  local f_rsync_excl="$1" f_restic_excl="$2"
  : > "$f_restic_excl"
  while IFS= read -r f_line; do
    [[ -z "$f_line" ]] && continue
    [[ "$f_line" =~ ^[[:space:]]*# ]] && continue
    # Convert common rsync patterns to restic
    local f_pat="$f_line"
    f_pat="${f_pat#/}"
    [[ -z "$f_pat" ]] && continue
    echo "**/$f_pat" >> "$f_restic_excl" 2>/dev/null || echo "$f_pat" >> "$f_restic_excl"
  done < "$f_rsync_excl"
  # Always exclude restic repo and backup dirs
  echo "**/backup" >> "$f_restic_excl"
  echo "**/.backup*" >> "$f_restic_excl"
}

# Run a restic backup to one target via gaboshlib's g_backup_restic.
# Usage: f_run_restic_backup <host> <port> <user> <path> \
#   <keep-daily> <keep-weekly> <keep-monthly> <rsync-excludes-file>
function f_run_restic_backup {
  local f_host="$1" f_port="$2" f_user="$3" f_path="$4"
  local f_keep_daily="$5" f_keep_weekly="$6" f_keep_monthly="$7" f_excl="$8"
  if [[ -z "$f_host" || -z "$f_path" || -z "$f_user" || -z "$f_port" ]]; then
    g_echo_error "Restic backup target incomplete (host/port/user/path)"
    return 1
  fi
  f_ensure_restic_passphrase
  local f_restic_excl="${g_tmp}/restic-excludes"
  f_bk_build_restic_excludes "$f_excl" "$f_restic_excl"
  local f_srcs="$g_data_root"
  [[ -d /root/.ssh ]] && f_srcs="$f_srcs:/root/.ssh"
  local f_key_opt=""
  if [[ -r "$g_bk_ssh_key" ]]; then
    f_key_opt="-k $g_bk_ssh_key"
  fi
  local f_excl_opt="default"
  if [[ -s "$f_restic_excl" ]]; then
    f_excl_opt="$f_restic_excl"
  fi
  RESTIC_KEEP_DAILY="$f_keep_daily" RESTIC_KEEP_WEEKLY="$f_keep_weekly" \
    RESTIC_KEEP_MONTHLY="$f_keep_monthly" \
    g_backup_restic -H "$f_host" -u "$f_user" -p "$f_port" -P "$f_path" \
      $f_key_opt "$f_srcs" "$f_excl_opt"
  return $?
}

# Local snapshot via gaboshlib's g_backup function (fallback mode when no
# restic target is configured). A temporary rsync shim drops gaboshlib's
# hardcoded --timeout=180: on slow local disks (Raspberry Pi + USB) even
# building the full file list can exceed 180s.
function f_run_g_backup {
  local f_dest="$1" f_excl="$2"
  local f_wrapper="${g_tmp}/rsync-wrapper"
  mkdir -p "$f_wrapper"
  {
    echo '#!/bin/bash'
    echo 'f_args=()'
    echo 'for f_a in "$@"'
    echo 'do'
    echo '  [[ "$f_a" == --timeout=* ]] || f_args+=("$f_a")'
    echo 'done'
    echo 'exec /usr/bin/rsync "${f_args[@]}"'
  } > "$f_wrapper/rsync"
  chmod 700 "$f_wrapper/rsync"

  local f_srcs="$g_data_root"
  [[ -d /root/.ssh ]] && f_srcs="$f_srcs:/root/.ssh"

  PATH="$f_wrapper:$PATH" g_backup "$f_srcs" "$f_dest" "$f_excl" \
    "" "" "" "" "" "--sparse"
}

# Encrypted archive push: tar the data root, encrypt with openssl and pipe
# the stream directly to the remote target (no local temp copy needed).
function f_run_encrypted_archive {
  local f_excl="$1"
  local f_date f_arch f_remote f_localhash f_remotehash
  f_date=$(date +%F)
  f_arch=$(f_bk_archive_name "$f_date")
  f_remote="${g_bk_path}/$(hostname)/${f_arch}"
  local f_tar_excl="${g_tmp}/excludes.tar"
  f_bk_excludes_for_tar "$f_excl" "$f_tar_excl"

  # Prepare the destination directory on the backup server
  f_bk_rsh "mkdir -p ${g_bk_path}/$(hostname)" || return 1

  # Stream: tar -> gzip -> encrypt -> ssh. sha256 of the ciphertext is
  # written to a temp file while streaming and verified against the remote.
  # Members mirror the snapshot sources (see f_run_g_backup): the data root
  # and the host's root SSH dir, which hold the key for the next push.
  local f_members="symbios"
  [[ -d /root/.ssh ]] && f_members="$f_members root/.ssh"
  : > "${g_tmp}/archive.sha"
  g_echo "Creating encrypted archive $f_arch (this can take a while)"
  # shellcheck disable=SC2086
  tar --numeric-owner --one-file-system \
    --exclude-from="$f_tar_excl" -C / -czf - $f_members 2>"${g_tmp}/tar.err" \
    | openssl enc "-$g_bk_cipher" -salt -pbkdf2 -iter "$g_bk_kdf_iter" \
        -pass file:"$g_bk_pw_file" \
    | tee >(sha256sum > "${g_tmp}/archive.sha") \
    | f_bk_rsh "cat > '${f_remote}.part'" || {
      g_echo_error "Archive transfer failed: $(tail -5 "${g_tmp}/tar.err" 2>/dev/null)"
      return 1
    }
  # The hash subshell runs asynchronously; give it a moment to flush.
  sleep 1
  f_localhash=$(awk '{print $1}' "${g_tmp}/archive.sha")

  # Verify integrity of the uploaded archive
  f_remotehash=$(f_bk_rsh "sha256sum '${f_remote}.part'" 2>/dev/null | awk '{print $1}')
  if [[ -z "$f_localhash" || "$f_localhash" != "$f_remotehash" ]]
  then
    g_echo_error "Checksum mismatch after upload (local=$f_localhash remote=$f_remotehash)"
    return 1
  fi

  # Atomically publish the finished archive and apply retention
  f_bk_rsh "mv '${f_remote}.part' '$f_remote'" || return 1
  g_echo_ok "Archive $f_arch uploaded and verified"
  f_bk_prune_archives
}

### Main ###

# Target label used by the interrupt handler below.
g_bk_cur_target="local"

# gaboshlib's g_echo_error_exit raises SIGHUP on fatal errors. The default
# SIGHUP action kills the script instantly - no EXIT trap, status JSON would
# stay "running" forever and locks/tmp dirs leak. Intercept it instead.
function f_bk_on_hup {
  f_write_status "error" "$g_bk_cur_target" "" "Backup was interrupted - see syslog."
  exit 1
}
trap f_bk_on_hup HUP

# Collect all configured restic targets (primary + additional servers).
g_bk_targets=()
while IFS=$'\t' read -r g_t_name g_t_host g_t_port g_t_user g_t_path g_t_kd g_t_kw g_t_km
do
  [[ -n "$g_t_host" ]] || continue
  g_bk_targets+=("$g_t_name|$g_t_host|$g_t_port|$g_t_user|$g_t_path|$g_t_kd|$g_t_kw|$g_t_km")
done < <(f_bk_targets_tsv)

g_echo_note "Starting $0 (host=$(hostname), targets=${#g_bk_targets[@]} restic target(s))"

# Excludes are shared between dump modules and the engines below.
mkdir -p "${g_data_root}/backup"
chmod 700 "${g_data_root}/backup"
chown root:root "${g_data_root}/backup" 2>/dev/null
f_bk_write_excludes "${g_tmp}/excludes.rsync"
g_snapshot_date=""

# Free-space guard: never let a run fill the disk (would break services).
# Prunes the oldest snapshots first, aborts with an error if that is not
# enough for the configured limits.
if ! f_bk_guard_free_space
then
  g_bk_cur_target="$(f_bk_is_remote && echo "remote" || echo "local")"
  f_write_status "error" "$g_bk_cur_target" "" "Disk below ${g_bk_min_free_gb}GB/${g_bk_min_free_percent}% free - aborting before the disk fills up."
  exit 1
fi

# Key pre-flight: an unusable backup key must abort loudly here, not surface
# as a "Permission denied" on the remote server an hour into the snapshot.
if ! f_bk_check_ssh_key
then
  g_bk_cur_target="$(f_bk_is_remote && echo "remote" || echo "local")"
  f_write_status "error" "$g_bk_cur_target" "" "Backup key ${g_bk_ssh_key} is missing or unusable - see syslog."
  exit 1
fi

if [[ ${#g_bk_targets[@]} -gt 0 ]]
then
  # One restic run per configured target; a failure on one server must not
  # stop the others (partial success is better than nothing).
  g_bk_cur_target="remote-restic"
  f_write_status "running" "remote-restic" "" ""
  g_ok_targets=""
  g_failed_targets=""
  for g_t in "${g_bk_targets[@]}"
  do
    IFS='|' read -r g_t_name g_t_host g_t_port g_t_user g_t_path g_t_kd g_t_kw g_t_km <<< "$g_t"
    g_echo_note "Backing up to ${g_t_name} (${g_t_host}:${g_t_port}${g_t_path})"
    if f_run_restic_backup "$g_t_host" "$g_t_port" "$g_t_user" "$g_t_path" \
      "$g_t_kd" "$g_t_kw" "$g_t_km" "${g_tmp}/excludes.rsync"
    then
      g_ok_targets="${g_ok_targets}${g_ok_targets:+, }${g_t_name}"
    else
      g_failed_targets="${g_failed_targets}${g_failed_targets:+, }${g_t_name}"
    fi
  done
  if [[ -z "$g_failed_targets" ]]
  then
    g_snapshot_date=$(date +%F)
    f_write_status "ok" "remote-restic" "$g_snapshot_date" "Restic snapshots created on: ${g_ok_targets}."
    g_echo_ok "Backup finished (restic, all targets)"
  else
    f_write_status "error" "remote-restic" "" "Restic snapshot failed on: ${g_failed_targets}. Succeeded on: ${g_ok_targets:-none}. See syslog."
    g_echo_error "Backup failed on: ${g_failed_targets}"
    exit 1
  fi
else
  g_bk_cur_target="local"
  f_write_status "running" "local" "" ""
  if f_run_g_backup "${g_data_root}/backup" "${g_tmp}/excludes.rsync"
  then
    g_snapshot_date=$(date +%F)
    f_bk_prune_local
    f_write_status "ok" "local" "$g_snapshot_date" "Local snapshot created in ${g_data_root}/backup." "$(f_bk_stats_json)"
    g_echo_ok "Backup finished (local snapshot)"
  else
    f_write_status "error" "local" "" "Local snapshot failed - see syslog."
    g_echo_error "Backup failed (local snapshot)"
    exit 1
  fi
fi

exit 0
