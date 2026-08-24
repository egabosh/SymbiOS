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
# volumes and the pre-run database dumps from backup.d/) as a daily,
# hardlink-based snapshot:
#
#   - No backup server configured : local snapshot below ${data_root}/backup
#   - Server configured           : rsync snapshot over SSH/SFTP (g_backup)
#   - Server + encryption         : openssl-encrypted daily archive pushed
#                                   over SSH (at-rest encrypted on target)
#
# Called by scripts/backup.sh (cron /etc/cron.d/backup_local, nightly 00:05).
# Status is written to ${g_log_dir}/backup-status.json for the WebUI and the
# backup healthcheck.

# Load gaboshlib (g_echo*, g_backup, g_lockfile, ...) and the SymbiOS libs.
# Passphrase subcommands print JSON on stdout: skip the gaboshlib stdout/stderr
# FIFO redirection (g_all-to-syslog) so the output stays machine-parseable.
[[ "${1:-}" == "gen-passphrase" || "${1:-}" == "get-passphrase" ]] && g_alltosyslog=1
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
esac

g_lockfile
g_nice
g_all-to-syslog
set -o pipefail

# Write the run status for the WebUI/healthcheck.
# Usage: f_write_status <state> <target> <snapshot-date> <message>
function f_write_status {
  local f_state="$1" f_target="$2" f_snap="$3" f_msg="$4"
  local f_now
  f_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    printf '{"state":"%s","finished":"%s","target":"%s","snapshot":"%s","message":%s}' \
      "$f_state" "$f_now" "$f_target" "$f_snap" "$(printf '%s' "$f_msg" | f_json_escape)"
  } > "${g_log_dir}/backup-status.json.tmp"
  mv "${g_log_dir}/backup-status.json.tmp" "${g_log_dir}/backup-status.json"
  # Success marker consumed by the healthcheck (epoch seconds).
  if [[ "$f_state" == "ok" ]]
  then
    date +%s > "${g_log_dir}/backup-last-success"
  fi
}

# Local or remote-unencrypted snapshot via gaboshlib's g_backup function.
# A temporary ssh wrapper injects our identity key into every ssh/rsync
# call made by g_backup (it does not support -i itself).
function f_run_g_backup {
  local f_dest="$1" f_excl="$2" f_srv="$3" f_port="$4" f_user="$5"
  local f_wrapper="${g_tmp}/ssh-wrapper"
  mkdir -p "$f_wrapper"
  {
    echo '#!/bin/bash'
    echo 'exec /usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \'
    if [[ -r "$g_bk_ssh_key" ]]
    then
      echo "  -i '$g_bk_ssh_key' \"\$@\""
    else
      echo '  "$@"'
    fi
  } > "$f_wrapper/ssh"
  chmod 700 "$f_wrapper/ssh"

  # shellcheck disable=SC2086
  PATH="$f_wrapper:$PATH" g_backup "$g_data_root" "$f_dest" "$f_excl" \
    "$f_srv" "$f_port" "$f_user"
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
  : > "${g_tmp}/archive.sha"
  g_echo "Creating encrypted archive $f_arch (this can take a while)"
  tar --numeric-owner --one-file-system \
    --exclude-from="$f_tar_excl" -C / -czf - symbios 2>"${g_tmp}/tar.err" \
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

g_echo_note "Starting $0 (host=$(hostname), target=$(f_bk_is_remote && echo "remote:${g_bk_host}" || echo local))"

# Excludes are shared between dump modules and the engines below.
mkdir -p "${g_data_root}/backup"
chmod 700 "${g_data_root}/backup"
chown root:root "${g_data_root}/backup" 2>/dev/null
f_bk_write_excludes "${g_tmp}/excludes.rsync"
g_snapshot_date=""

if f_bk_is_remote
then
  if [[ "$g_bk_encrypt" == "true" ]]
  then
    # Remote + at-rest encryption -> daily encrypted archives
    f_write_status "running" "remote-encrypted" "" ""
    f_ensure_passphrase
    if f_run_encrypted_archive "${g_tmp}/excludes.rsync"
    then
      g_snapshot_date=$(date +%F)
      f_write_status "ok" "remote-encrypted" "$g_snapshot_date" "Encrypted archive uploaded to ${g_bk_host}."
      g_echo_ok "Backup finished (encrypted remote archive)"
    else
      f_write_status "error" "remote-encrypted" "" "Encrypted archive upload failed - see syslog."
      g_echo_error "Backup failed (encrypted remote archive)"
      exit 1
    fi
  else
    # Remote without encryption -> hardlink snapshots via rsync/SSH
    f_write_status "running" "remote" "" ""
    if f_run_g_backup "$g_bk_path" "${g_tmp}/excludes.rsync" "$g_bk_host" "$g_bk_port" "$g_bk_user"
    then
      g_snapshot_date=$(date +%F)
      f_write_status "ok" "remote" "$g_snapshot_date" "Snapshot synced to ${g_bk_host}:${g_bk_path}."
      g_echo_ok "Backup finished (remote snapshot)"
    else
      f_write_status "error" "remote" "" "Remote snapshot failed - see syslog."
      g_echo_error "Backup failed (remote snapshot)"
      exit 1
    fi
  fi
else
  # No server configured -> local snapshot below ${data_root}/backup
  f_write_status "running" "local" "" ""
  if f_run_g_backup "${g_data_root}/backup" "${g_tmp}/excludes.rsync" "" "" ""
  then
    g_snapshot_date=$(date +%F)
    f_write_status "ok" "local" "$g_snapshot_date" "Local snapshot created in ${g_data_root}/backup."
    g_echo_ok "Backup finished (local snapshot)"
  else
    f_write_status "error" "local" "" "Local snapshot failed - see syslog."
    g_echo_error "Backup failed (local snapshot)"
    exit 1
  fi
fi

exit 0
