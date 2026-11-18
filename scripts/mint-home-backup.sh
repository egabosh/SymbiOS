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
# mint-home-backup.sh - manual home backup for Linux Mint systems.
#
# WHY a client-side script: the Mint machine owns its user homes, so it reads
# them itself and streams the archive to the SymbiOS host. No credentials for
# the Mint machine are stored on the server, and no service needs to wake or
# schedule the client - the user runs it when the machine is on.
#
# All messages go to stderr: stdout carries the tar stream in transfer mode.
# The archives land below ${SYMBIOS_DIR} (default
# /symbios/backups/mint/<id>/) and are picked up by the next restic snapshot.

set -o pipefail

# Log helpers write to stderr on purpose (stdout is the archive stream).
function f_log {
  printf '%s\n' "$*" >&2
}

function f_ok {
  printf 'OK: %s\n' "$*" >&2
}

function f_error {
  printf 'ERROR: %s\n' "$*" >&2
}

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--dry-run] [--output <file>] [--config <file>]
       $(basename "$0") --help

Back up the interactive users' homes of this Linux Mint system. By default a
gzip tar archive is streamed over SSH into the backup directory configured in
${g_config}.

Interactive users are accounts with UID 1000..65533, a home below /home and a
bash, zsh or fish login shell. Service accounts (e.g. docker or llama) are not
included. INCLUDE_USERS in the config overrides the automatic selection.
Caches, browser profiles' cache trees, Trash and node_modules are excluded.

Options:
  --dry-run           Show the selected users, their sizes and the target path;
                      read no home data and transfer nothing.
  --output <file>     Write the archive to a local file instead of streaming
                      it to SymbiOS (useful for a migration on a USB disk).
  --config <file>     Use another config file (default: ${g_config}).
  -h, --help          Show this help and exit.

Config keys (shell KEY="value" syntax, root-owned):
  SYMBIOS_HOST        Required: host name or IP of the SymbiOS host.
  SYMBIOS_PORT        SSH port (default 33).
  SYMBIOS_USER        SSH user (default root).
  SYMBIOS_DIR         Required: target directory below the SymbiOS data root.
  BACKUP_ID           Required: id used for the archive name.
  SSH_KEY             Private key for the SSH transfer.
  RETENTION           Number of archives kept on the target (default 7).
  INCLUDE_USERS       Optional space-separated list of users to back up.
  EXTRA_EXCLUDES      Optional space-separated additional tar patterns.

Examples:
  $(basename "$0") --dry-run
  $(basename "$0")
  $(basename "$0") --output /media/usb/compute-home.tar.gz

While the archive is created a timestamped /tmp/no-suspend is set so an idle
suspend watchdog cannot suspend this machine mid-transfer. A pre-existing
non-empty flag is left untouched.

Exit codes: 0 = ok, 1 = runtime error, 2 = usage or configuration error.
EOF
}

# --- defaults and arguments --------------------------------------------------
g_config="/etc/symbios/home-backup.conf"
g_output="-"
g_dry_run=0

case "${1:-}" in
  -h|--help)
    f_usage
    exit 0
    ;;
esac

while [[ $# -gt 0 ]]
do
  case "$1" in
    --dry-run)
      g_dry_run=1
      ;;
    --output|--config)
      if [[ $# -lt 2 ]]
      then
        f_error "$1 needs a value"
        f_usage >&2
        exit 2
      fi
      if [[ "$1" == "--output" ]]
      then
        g_output="$2"
      else
        g_config="$2"
      fi
      shift
      ;;
    *)
      f_error "Unknown option: $1"
      f_usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]
then
  f_error "This script must run as root to read all home directories."
  exit 1
fi

# --- configuration -----------------------------------------------------------
SYMBIOS_HOST=""
SYMBIOS_PORT="33"
SYMBIOS_USER="root"
SYMBIOS_DIR=""
BACKUP_ID=""
SSH_KEY="/etc/symbios/home-backup/id_ed25519"
INCLUDE_USERS=""
EXTRA_EXCLUDES=""
RETENTION="7"

if [[ ! -r "$g_config" ]]
then
  f_error "Config file not readable: $g_config"
  exit 2
fi
# The file is root-owned and deployed by SymbiOS; sourcing keeps the format
# identical to the other SymbiOS KEY="value" configs.
# shellcheck disable=SC1090
. "$g_config"

function f_bad_config {
  f_error "Invalid configuration ($g_config): $1 = $2"
  exit 2
}

[[ "$BACKUP_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
  || f_bad_config BACKUP_ID "$BACKUP_ID"
[[ "$RETENTION" =~ ^[0-9]+$ && "$RETENTION" -gt 0 ]] \
  || f_bad_config RETENTION "$RETENTION"

if [[ "$g_output" == "-" ]]
then
  [[ "$SYMBIOS_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
    || f_bad_config SYMBIOS_HOST "$SYMBIOS_HOST"
  [[ "$SYMBIOS_PORT" =~ ^[0-9]+$ && "$SYMBIOS_PORT" -ge 1 && "$SYMBIOS_PORT" -le 65535 ]] \
    || f_bad_config SYMBIOS_PORT "$SYMBIOS_PORT"
  [[ "$SYMBIOS_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] \
    || f_bad_config SYMBIOS_USER "$SYMBIOS_USER"
  # No spaces or shell metacharacters: the path is embedded in a remote shell.
  [[ "$SYMBIOS_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || f_bad_config SYMBIOS_DIR "$SYMBIOS_DIR"
  [[ "$SSH_KEY" == /* && ! "$SSH_KEY" == *" "* ]] \
    || f_bad_config SSH_KEY "$SSH_KEY"
  [[ -r "$SSH_KEY" ]] || { f_error "SSH key not readable: $SSH_KEY"; exit 1; }
fi

# --- user selection ----------------------------------------------------------
declare -a g_users=()

function f_add_user {
  local f_user="$1"
  local f_line f_home

  [[ "$f_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] \
    || { f_error "Invalid user name in INCLUDE_USERS: $f_user"; return 1; }
  f_line=$(getent passwd "$f_user") || return 1
  # passwd fields: name:passwd:uid:gid:gecos:home:shell
  f_home="${f_line#*:*:*:*:*:}"
  f_home="${f_home%%:*}"
  [[ "$f_home" == /home/* && -d "$f_home" ]] || return 1
  g_users+=("$f_user")
}

function f_select_users {
  local f_name f_uid f_home f_shell

  if [[ -n "$INCLUDE_USERS" ]]
  then
    for f_name in $INCLUDE_USERS
    do
      f_add_user "$f_name" || return 1
    done
    return 0
  fi

  while IFS=: read -r f_name _ f_uid _ _ f_home f_shell
  do
    [[ "$f_uid" =~ ^[0-9]+$ ]] || continue
    (( f_uid >= 1000 && f_uid < 65534 )) || continue
    [[ "$f_home" == /home/* ]] || continue
    case "$f_shell" in
      */bash|*/zsh|*/fish) ;;
      *) continue ;;
    esac
    [[ -d "$f_home" ]] || continue
    g_users+=("$f_name")
  done < <(getent passwd)
}

if ! f_select_users || [[ ${#g_users[@]} -eq 0 ]]
then
  f_error "No interactive users found - check INCLUDE_USERS in $g_config"
  exit 1
fi

g_stamp=$(date +%Y%m%d%H%M)
g_archive="${BACKUP_ID}-${g_stamp}.tar.gz"
g_created=$(date -Iseconds)
g_host=$(hostname -f 2>/dev/null || hostname)

declare -a g_excludes=(
  --exclude='*/.cache'
  --exclude='*/.local/share/Trash'
  --exclude='*/node_modules'
  --exclude='*/.npm/_cacache'
  --exclude='*/.cargo/registry'
  --exclude='*/.steam/steamapps'
  --exclude='*/.xsession-errors'
  --exclude='*/.xsession-errors.old'
)
for f_pattern in $EXTRA_EXCLUDES
do
  g_excludes+=(--exclude="$f_pattern")
done

if (( g_dry_run ))
then
  f_log "Backup ID:   $BACKUP_ID"
  f_log "Users:       ${g_users[*]}"
  for f_user in "${g_users[@]}"
  do
    f_log "  $(du -sh -- "/home/$f_user" 2>/dev/null | cut -f1)  /home/$f_user"
  done
  if [[ "$g_output" == "-" ]]
  then
    f_log "Target:      $SYMBIOS_USER@$SYMBIOS_HOST:$SYMBIOS_PORT$SYMBIOS_DIR/$g_archive"
  else
    f_log "Target:      $g_output"
  fi
  f_log "Dry run: nothing was read or transferred."
  exit 0
fi

# --- idle suspend guard ------------------------------------------------------
# The WoL idle watchdog treats a NON-EMPTY /tmp/no-suspend as "busy". Only
# remove the flag if we created it, so another job's flag survives.
g_guard_created=0
if [[ ! -s /tmp/no-suspend ]]
then
  printf '%s mint-home-backup %s\n' "$g_created" "$BACKUP_ID" >> /tmp/no-suspend
  g_guard_created=1
fi

function f_cleanup {
  if (( g_guard_created ))
  then
    rm -f /tmp/no-suspend
  fi
}
trap f_cleanup EXIT

# --- archive creation --------------------------------------------------------
# Usage: f_create_archive <output|->
function f_create_archive {
  local f_output="$1"
  # Store paths as home/<user>/... so the archive can be extracted at /
  # during a migration, instead of only below /home.
  tar --create --gzip --file "$f_output" "${g_excludes[@]}" \
    -C / "${g_users[@]/#/home/}"
}

if [[ "$g_output" != "-" ]]
then
  if ! f_create_archive "$g_output"
  then
    f_error "Could not write archive to $g_output"
    exit 1
  fi
  f_ok "Archive written to $g_output ($(stat -c %s "$g_output") bytes)"
  f_log "sha256: $(sha256sum "$g_output" | cut -d' ' -f1)"
  exit 0
fi

# --- transfer over SSH -------------------------------------------------------
declare -a g_ssh=(
  ssh
  -i "$SSH_KEY"
  -p "$SYMBIOS_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  "$SYMBIOS_USER@$SYMBIOS_HOST"
)

# Usage: f_stream_archive  (reads the tar stream from stdin)
function f_stream_archive {
  "${g_ssh[@]}" "mkdir -p -- '$SYMBIOS_DIR' && cat > '$SYMBIOS_DIR/$g_archive.part'"
}

f_log "Streaming ${g_users[*]} to $SYMBIOS_USER@$SYMBIOS_HOST:$SYMBIOS_DIR/$g_archive"
if ! f_create_archive - | f_stream_archive
then
  "${g_ssh[@]}" "rm -f -- '$SYMBIOS_DIR/$g_archive.part'" > /dev/null 2>&1 || true
  f_error "Transfer failed - the partial archive was removed on the target"
  exit 1
fi

# Finalize remotely: validate, publish the .part file, write the metadata and
# apply retention. Kept as a heredoc so no receiver script is needed on the
# SymbiOS host (this client is the only thing the playbook installs).
if ! "${g_ssh[@]}" bash -s -- \
    "$SYMBIOS_DIR" "$g_archive" "$BACKUP_ID" "$g_host" "${g_users[*]}" \
    "$RETENTION" "$g_created" << 'REMOTE'
set -e
r_dir="$1"
r_archive="$2"
r_id="$3"
r_host="$4"
r_users="$5"
r_keep="$6"
r_created="$7"
r_part="$r_dir/$r_archive.part"

if [[ ! -s "$r_part" ]]
then
  printf 'empty partial archive on target\n' >&2
  exit 1
fi
r_count=$(tar -tzf "$r_part" | wc -l)
if [[ "$r_count" -eq 0 ]]
then
  printf 'archive contains no files\n' >&2
  exit 1
fi

mv -- "$r_part" "$r_dir/$r_archive"
r_size=$(stat -c %s "$r_dir/$r_archive")
r_sha=$(sha256sum "$r_dir/$r_archive" | cut -d' ' -f1)
r_meta="$r_dir/${r_archive%.tar.gz}.json"
{
  printf '{\n'
  printf '  "id": "%s",\n' "$r_id"
  printf '  "host": "%s",\n' "$r_host"
  printf '  "archive": "%s",\n' "$r_archive"
  printf '  "created": "%s",\n' "$r_created"
  printf '  "size_bytes": %s,\n' "$r_size"
  printf '  "sha256": "%s",\n' "$r_sha"
  printf '  "files": %s,\n' "$r_count"
  printf '  "users": "%s"\n' "$r_users"
  printf '}\n'
} > "$r_meta.part"
mv -- "$r_meta.part" "$r_meta"

r_old=$(ls -1t "$r_dir/$r_id"-*.tar.gz 2> /dev/null | tail -n +$(( r_keep + 1 )) || true)
while IFS= read -r r_file
do
  [[ -n "$r_file" ]] || continue
  rm -f -- "$r_file" "${r_file%.tar.gz}.json"
done <<< "$r_old"

printf '%s %s %s %s\n' "$r_archive" "$r_count" "$r_size" "$r_sha"
REMOTE
then
  f_error "Remote finalization failed - check $SYMBIOS_DIR/$g_archive.part"
  exit 1
fi

f_ok "Backup complete: $SYMBIOS_USER@$SYMBIOS_HOST:$SYMBIOS_DIR/$g_archive"
exit 0
