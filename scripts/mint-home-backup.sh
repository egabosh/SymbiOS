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
# mint-home-backup.sh - manual restic home backup for Linux Mint systems.
#
# The Mint machine reads its own user homes and writes an encrypted restic
# repository over SFTP (port 28) into the private directory of its dedicated
# LDAP backup user on the SymbiOS host. No root SSH access is needed, and the
# next central restic snapshot picks the repository up with /symbios.
#
# There is deliberately no cron job: the user runs this script when the
# machine is on. All messages go to stderr.

set -o pipefail

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
Usage: $(basename "$0") [--dry-run] [--config <file>]
       $(basename "$0") --help

Back up the interactive users' homes of this Linux Mint system into the
restic repository configured in ${g_config} (default:
/etc/symbios/home-backup.conf). The repository is reached over SFTP with the
system's own LDAP backup user, so only this system can read or delete it.

Interactive users are accounts with UID 1000..65533, a home below /home and a
bash, zsh or fish login shell. Service accounts (e.g. docker or llama) are not
included. INCLUDE_USERS in the config overrides the automatic selection.
Caches, browser cache trees, Trash and node_modules are excluded.

Options:
  --dry-run           Show the selected users, their sizes and the repository;
                      read no home data and contact no server.
  --config <file>     Use another config file (default: ${g_config}).
  -h, --help          Show this help and exit.

Config keys (shell KEY="value" syntax, root-owned):
  BACKUP_ID             Required: id used as a restic tag.
  BACKUP_USER           Required: LDAP user on the SymbiOS host (informational).
  RESTIC_REPO           Required: sftp URL of the private repository.
  RESTIC_PASSWORD_FILE  Required: root-readable file with the repo password.
  RETENTION             Number of daily snapshots kept (default 7).
  INCLUDE_USERS         Optional space-separated list of users to back up.
  EXTRA_EXCLUDES        Optional space-separated extra restic exclude patterns.

While the backup runs a timestamped /tmp/no-suspend is set so an idle suspend
watchdog cannot suspend this machine mid-transfer. A pre-existing non-empty
flag is left untouched.

Exit codes: 0 = ok, 1 = runtime error, 2 = usage or configuration error.
EOF
}

# --- defaults and arguments --------------------------------------------------
g_config="/etc/symbios/home-backup.conf"
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
    --config)
      if [[ $# -lt 2 ]]
      then
        f_error "--config needs a value"
        f_usage >&2
        exit 2
      fi
      g_config="$2"
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
BACKUP_ID=""
BACKUP_USER=""
RESTIC_REPO=""
RESTIC_PASSWORD_FILE=""
RETENTION="7"
INCLUDE_USERS=""
EXTRA_EXCLUDES=""

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
[[ "$BACKUP_USER" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || f_bad_config BACKUP_USER "$BACKUP_USER"
[[ "$RESTIC_REPO" =~ ^sftp:[A-Za-z0-9][A-Za-z0-9._-]*:/home/[A-Za-z0-9][A-Za-z0-9_-]*/restic$ ]] \
  || f_bad_config RESTIC_REPO "$RESTIC_REPO"
[[ "$RESTIC_PASSWORD_FILE" == /* && ! "$RESTIC_PASSWORD_FILE" == *" "* ]] \
  || f_bad_config RESTIC_PASSWORD_FILE "$RESTIC_PASSWORD_FILE"
[[ "$RETENTION" =~ ^[0-9]+$ && "$RETENTION" -gt 0 ]] \
  || f_bad_config RETENTION "$RETENTION"

if (( ! g_dry_run ))
then
  command -v restic > /dev/null || { f_error "restic is not installed"; exit 1; }
  [[ -r "$RESTIC_PASSWORD_FILE" && -s "$RESTIC_PASSWORD_FILE" ]] \
    || { f_error "Repository password file not readable: $RESTIC_PASSWORD_FILE"; exit 1; }
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

declare -a g_excludes=(
  --exclude-caches
  --exclude='**/.cache'
  --exclude='**/.local/share/Trash'
  --exclude='**/node_modules'
  --exclude='**/.npm/_cacache'
  --exclude='**/.cargo/registry'
  --exclude='**/.steam/steamapps'
  --exclude='**/.xsession-errors'
  --exclude='**/.xsession-errors.old'
)
for f_pattern in $EXTRA_EXCLUDES
do
  g_excludes+=(--exclude="$f_pattern")
done

declare -a g_paths=()
for f_user in "${g_users[@]}"
do
  g_paths+=("/home/${f_user}")
done

if (( g_dry_run ))
then
  f_log "Backup ID:   $BACKUP_ID"
  f_log "Repository:  $RESTIC_REPO"
  f_log "SFTP user:   $BACKUP_USER"
  f_log "Users:       ${g_users[*]}"
  for f_user in "${g_users[@]}"
  do
    f_log "  $(du -sh -- "/home/$f_user" 2>/dev/null | cut -f1)  /home/$f_user"
  done
  f_log "Retention:   keep $RETENTION daily snapshots"
  f_log "Dry run: nothing was read or transferred."
  exit 0
fi

# --- idle suspend guard ------------------------------------------------------
# The WoL idle watchdog treats a NON-EMPTY /tmp/no-suspend as "busy". Only
# remove the flag if we created it, so another job's flag survives.
g_guard_created=0
g_created=$(date -Iseconds)
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

# --- restic repository -------------------------------------------------------
export RESTIC_REPOSITORY="$RESTIC_REPO"
export RESTIC_PASSWORD_FILE

if ! restic snapshots > /dev/null 2>&1
then
  f_log "Initializing restic repository $RESTIC_REPO"
  if ! restic init
  then
    f_error "Could not initialize the restic repository - check the SFTP user, key and server path"
    exit 1
  fi
fi

if ! restic backup --tag mint-home-backup --tag "$BACKUP_ID" \
    "${g_excludes[@]}" "${g_paths[@]}"
then
  f_error "restic backup failed"
  exit 1
fi

if ! restic forget --prune --group-by host --keep-daily "$RETENTION"
then
  f_error "restic retention failed (the snapshot itself was stored)"
  exit 1
fi

f_ok "Backup complete: $RESTIC_REPO (users: ${g_users[*]})"
exit 0
