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
# symbios-backup-lib.sh - Shared helpers for the SymbiOS backup/restore
# scripts (symbios-backup.sh, symbios-backup-list.sh, symbios-restore.sh).
#
# Requires symbios-lib.sh to be sourced first (provides g_* layout globals).
#
# Configuration source: inventory.yml (all.vars)
#   backup_server_host / backup_server_port / backup_server_user /
#   backup_server_path   remote target (empty host = local backups only)
#   backup_encryption    true = encrypt remote archives (openssl aes-256-cbc)
#   backup_exclude       list of extra rsync exclude patterns
#
# Snapshot layouts produced/consumed:
#   rsync mode (g_backup):  <dest>/<hostname>/backup-YYYY-MM-DD/symbios/...
#   archive mode:           <dest>/<hostname>/symbios-YYYY-MM-DD.tar.gz.enc

# Retention policy for encrypted archives (grandfather-father-son).
g_bk_keep_daily=7
g_bk_keep_weekly=4
g_bk_keep_monthly=6

# Encryption parameters (openssl, no extra packages needed).
g_bk_cipher="aes-256-cbc"
g_bk_kdf_iter="200000"

# Read all backup-related settings from inventory.yml into g_bk_* globals.
function f_bk_read_vars {
  g_bk_host="$(f_symbios_var backup_server_host "")"
  g_bk_port="$(f_symbios_var backup_server_port "22")"
  g_bk_user="$(f_symbios_var backup_server_user "root")"
  g_bk_path="$(f_symbios_var backup_server_path "")"
  g_bk_encrypt="$(f_symbios_var backup_encryption "false")"
  [[ "$g_bk_encrypt" == "true" ]] || g_bk_encrypt=""
  # Local snapshot base: <data_root>/backup/<hostname>
  g_bk_snap_base="${g_data_root}/backup/$(hostname)"
  # Passphrase file for encrypted archives (0600, root only).
  g_bk_pw_file="${g_config_dir}/.backup_passphrase"
  # SSH client key: reuse the WebUI gateway identity so one key works for
  # everything (Test Connection in the WebUI uses the same key).
  g_bk_ssh_key="${g_config_dir}/.ssh/id_symbios"
}

# True if a remote backup server is configured.
function f_bk_is_remote {
  [[ -n "$g_bk_host" && -n "$g_bk_path" ]]
}

# Build the ssh option string used for every remote call.
function f_bk_ssh_opts {
  local f_opts="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
  [[ -r "$g_bk_ssh_key" ]] && f_opts="$f_opts -i $g_bk_ssh_key"
  f_opts="$f_opts -p ${g_bk_port:-22}"
  echo "$f_opts"
}

# Run a command on the remote backup server.
# Usage: f_bk_rsh <command> [args...]
function f_bk_rsh {
  ssh $(f_bk_ssh_opts) "${g_bk_user}@${g_bk_host}" "$@"
}

# Write the merged exclude file for rsync (patterns anchored at /symbios).
# Usage: f_bk_write_excludes <outfile>
function f_bk_write_excludes {
  local f_out="$1"
  {
    # Built-in defaults: never back up our own snapshots, skip docker/
    # containerd internals (images/layers are re-pullable), keep volumes
    # and all other data. Runtime noise that must not be copied:
    echo "/backup/"
    echo "/docker/overlay2/"
    echo "/docker/overlay/"
    echo "/docker/containers/"
    echo "/docker/image/"
    echo "/docker/buildkit/"
    echo "/docker/network/"
    echo "/docker/plugins/"
    echo "/docker/runtimes/"
    echo "/docker/swarm/"
    echo "/docker/containerd/"
    echo "/docker/rootfs/"
    echo "/docker/tmp/"
    echo "/containerd/"
    echo "**/__pycache__/"
    # User-defined excludes from inventory.yml (one rsync pattern per line)
    if [[ -r "${g_inventory}" ]]
    then
      python3 - "${g_inventory}" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)
for line in (cfg.get('all', {}).get('vars', {}).get('backup_exclude') or []):
    line = str(line).strip()
    if line and not line.startswith('#'):
        print(line)
PYEOF
    fi
  } > "$f_out"
}

# Convert an rsync-style exclude file (anchored at /symbios) into tar
# syntax (paths relative to /). Usage: f_bk_excludes_for_tar <rsyncfile> <tarfile>
function f_bk_excludes_for_tar {
  local f_in="$1" f_out="$2"
  > "$f_out"
  local f_line
  while IFS= read -r f_line
  do
    [[ -z "$f_line" ]] && continue
    case "$f_line" in
      /*) echo "${f_line#/}" ;;
      *)  echo "$f_line" ;;
    esac
  done < "$f_in" >> "$f_out"
}

# Name of the encrypted archive file for a given date.
function f_bk_archive_name {
  echo "symbios-${1}.tar.gz.enc"
}

# List local rsync snapshot dates (newest first). Monthly symlinks are
# resolved by name; incomplete/old/temp dirs are ignored.
function f_bk_list_local_dates {
  local f_d f_base="$g_bk_snap_base"
  [[ -d "$f_base" ]] || return 0
  for f_d in $(ls -1 "$f_base" 2>/dev/null | grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r)
  do
    echo "${f_d#backup-}"
  done
}

# List dates available on the remote rsync target (newest first).
function f_bk_list_remote_dates {
  f_bk_rsh "ls -1 ${g_bk_path}/$(hostname)/ 2>/dev/null" 2>/dev/null \
    | grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r | sed 's/^backup-//'
}

# List archive dates found below a base path (local dir or remote prefix
# command output is passed via stdin as plain filenames).
function f_bk_dates_from_archive_names {
  grep -E '^symbios-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz\.enc$' \
    | sed -E 's/^symbios-([0-9-]{10})\.tar\.gz\.enc$/\1/' | sort -ru
}

# Resolve how a given date can be restored. Sets g_bk_src_kind to
# "local-rsync", "remote-rsync", "local-archive", "remote-archive" or "".
function f_bk_resolve_source {
  local f_date="$1"
  g_bk_src_kind=""
  # 1. Local rsync snapshot directory (also matches monthly symlinks)
  if [[ -e "$g_bk_snap_base/backup-$f_date" ]]
  then
    g_bk_src_kind="local-rsync"
    return 0
  fi
  # 2. Local archive (unusual but possible)
  if [[ -f "$g_bk_snap_base/$(f_bk_archive_name "$f_date")" ]]
  then
    g_bk_src_kind="local-archive"
    return 0
  fi
  # 3./4. Remote variants (only if a server is configured)
  if f_bk_is_remote
  then
    if f_bk_rsh "test -e ${g_bk_path}/$(hostname)/backup-$f_date" >/dev/null 2>&1
    then
      g_bk_src_kind="remote-rsync"
      return 0
    fi
    if f_bk_rsh "test -e ${g_bk_path}/$(hostname)/$(f_bk_archive_name "$f_date")" >/dev/null 2>&1
    then
      g_bk_src_kind="remote-archive"
      return 0
    fi
  fi
  return 1
}

# Prune old encrypted archives on the remote target according to
# g_bk_keep_{daily,weekly,monthly} (grandfather-father-son).
function f_bk_prune_archives {
  local f_list f_name f_date f_dow f_week f_month
  local -A f_seen_week=() f_seen_month=()
  local f_days=0 f_weeks=0 f_months=0
  # Newest-first list of archive names on the remote host
  f_list=$(f_bk_rsh "ls -1 ${g_bk_path}/$(hostname)/ 2>/dev/null" 2>/dev/null \
    | f_bk_dates_from_archive_names) || return 0
  for f_name in $f_list
  do
    f_date="$f_name"
    f_dow=$(date -d "$f_date" +%u 2>/dev/null) || continue
    f_week=$(date -d "$f_date" +%G-W%V 2>/dev/null) || continue
    f_month="${f_date:0:7}"
    if [[ $f_days -lt $g_bk_keep_daily ]]
    then
      ((f_days++))
      continue
    fi
    if [[ $f_weeks -lt $g_bk_keep_weekly && "$f_dow" == "1" && -z "${f_seen_week[$f_week]:-}" ]]
    then
      f_seen_week[$f_week]=1
      ((f_weeks++))
      continue
    fi
    if [[ $f_months -lt $g_bk_keep_monthly && "${f_date:8:2}" == "01" && -z "${f_seen_month[$f_month]:-}" ]]
    then
      f_seen_month[$f_month]=1
      ((f_months++))
      continue
    fi
    g_echo_warn "Removing old backup archive $f_name (retention)"
    f_bk_rsh "rm -f ${g_bk_path}/$(hostname)/$(f_bk_archive_name "$f_date")" >/dev/null 2>&1
  done
}
