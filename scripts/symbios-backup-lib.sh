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
#   backup_keep_daily / backup_keep_weekly / backup_keep_monthly
#                        local snapshot retention (grandfather-father-son)
#   backup_min_free_gb / backup_min_free_percent
#                        disk guard: abort before the disk fills up
#
# Snapshot layouts produced/consumed:
#   rsync mode (g_backup):  <dest>/<hostname>/backup-YYYY-MM-DD/symbios/...
#   archive mode:           <dest>/<hostname>/symbios-YYYY-MM-DD.tar.gz.enc

# ---------------------------------------------------------------------------
# Direct invocation (not sourced): this is a library, so running it directly
# only makes sense to read its documentation. The guard (BASH_SOURCE == $0)
# prevents the usage block from triggering when a caller script is itself
# invoked with --help.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
  then
    cat << EOF
$(basename "$0") - Shared helpers for the SymbiOS backup/restore scripts.

This is a library and must be sourced after symbios-lib.sh:
  source symbios-lib.sh
  source symbios-backup-lib.sh

Used by symbios-backup.sh, symbios-backup-list.sh and symbios-restore.sh.
Reads all backup settings from inventory.yml into g_bk_* globals and
provides the helper functions f_bk_read_vars, f_bk_is_remote,
f_bk_ssh_opts, f_bk_rsh, f_bk_write_excludes, f_bk_excludes_for_tar,
f_bk_list_local_dates, f_bk_dates_from_archive_names, f_bk_resolve_source,
f_bk_remove_local_entry and f_bk_is_monthly_alias (among others).

Configuration (inventory.yml, all.vars):
  backup_server_host / backup_server_port / backup_server_user /
  backup_server_path   remote target (empty host = local backups only)
  backup_encryption    true = encrypt remote archives (openssl aes-256-cbc)
  backup_exclude       list of extra rsync exclude patterns
  backup_keep_daily / backup_keep_weekly / backup_keep_monthly
                       local snapshot retention (grandfather-father-son)
  backup_min_free_gb / backup_min_free_percent
                       disk guard: abort before the disk fills up

Options:
  -h, --help  Show this help and exit
EOF
    exit 0
  fi
  echo "$(basename "$0") is a library and cannot be run directly - source it instead." >&2
  exit 1
fi

# Retention policy for remote encrypted archives AND local snapshots
# (grandfather-father-son): keep the last N dailies, N Monday-weeklies and
# N month-starts, prune everything older.
g_bk_keep_daily=7
g_bk_keep_weekly=4
g_bk_keep_monthly=6

# Local disk guard: the nightly backup aborts (or prunes old snapshots)
# when free space on the data root drops below these limits. Reaching them
# would otherwise break the running services while rsync fills the disk.
g_bk_min_free_gb=3
g_bk_min_free_percent=15

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
  # Optional overrides from inventory.yml (retention + disk guard).
  g_bk_keep_daily="$(f_symbios_var backup_keep_daily "$g_bk_keep_daily")"
  g_bk_keep_weekly="$(f_symbios_var backup_keep_weekly "$g_bk_keep_weekly")"
  g_bk_keep_monthly="$(f_symbios_var backup_keep_monthly "$g_bk_keep_monthly")"
  g_bk_min_free_gb="$(f_symbios_var backup_min_free_gb "$g_bk_min_free_gb")"
  g_bk_min_free_percent="$(f_symbios_var backup_min_free_percent "$g_bk_min_free_percent")"
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

# List local monthly snapshot dirs (newest first). g_backup anchors the first
# daily of every month into backup-YYYY-MM-monthly and replaces the daily with
# a symlink, so monthlies must be handled separately from plain dailies.
function f_bk_list_local_monthly {
  local f_base="$g_bk_snap_base"
  [[ -d "$f_base" ]] || return 0
  ls -d1 "$f_base"/backup-[0-9][0-9][0-9][0-9]-[0-9][0-9]-monthly 2>/dev/null \
    | sed 's#^.*/backup-##; s/-monthly$//' | sort -r
}

# Snapshot stats as a JSON fragment for the backup status extra-arg:
# "snapshot_count":N,"snapshot_size_mb":M (no leading comma; f_write_status
# prepends one). Empty when no snapshot tree exists.
function f_bk_stats_json {
  local f_base="$g_bk_snap_base"
  local f_count=0 f_size_mb=0
  if [[ -d "$f_base" ]]
  then
    f_count=$(f_bk_list_local_dates | wc -l)
    f_count=$(( f_count + $(f_bk_list_local_monthly | wc -l) ))
    # du -sx counts hardlinked files once (-x: stay on the snapshot fs).
    f_size_mb=$(du -sx -B1M "$f_base" 2>/dev/null | awk '{print $1}')
    [[ "$f_size_mb" =~ ^[0-9]+$ ]] || f_size_mb=0
  fi
  printf '"snapshot_count":%s,"snapshot_size_mb":%s' "$f_count" "$f_size_mb"
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

# Force-delete a local snapshot dir by name (handles the -monthly symlink
# aliases: removing the monthly dir after the daily symlink is gone).
# Usage: f_bk_remove_local_entry <basename-e.g.-backup-YYYY-MM-DD>
function f_bk_remove_local_entry {
  local f_base="$g_bk_snap_base"
  local f_entry="$1"
  [[ -e "$f_base/$f_entry" || -L "$f_base/$f_entry" ]] || return 0
  if [[ -L "$f_base/$f_entry" ]]
  then
    # g_backup symlinks a month's first daily into backup-YYYY-MM-monthly.
    # Resolve the (relative or absolute) target and remove the monthly dir
    # too, otherwise the alias dead-ends and the space stays occupied.
    local f_target
    f_target=$(readlink "$f_base/$f_entry")
    case "$f_target" in
      /*) f_target="$f_target" ;;
      *)  f_target="$f_base/$(dirname "$f_entry")/$f_target" ;;
    esac
    local f_real
    f_real=$(cd "$(dirname "$f_target")" 2>/dev/null && pwd)/$(basename "$f_target")
    if [[ -d "$f_real" && "$(basename "$f_real")" == *-monthly ]]
    then
      g_echo_warn "Removing monthly snapshot $f_real (retention)"
      chmod -R +w "$f_real" 2>/dev/null
      rm -rf "$f_real"
    fi
    rm -f "$f_base/$f_entry"
  else
    g_echo_warn "Removing old local snapshot $f_entry (retention)"
    chmod -R +w "$f_base/$f_entry" 2>/dev/null
    rm -rf "$f_base/$f_entry"
  fi
}

# True if local snapshot <date> is a monthly alias (its symbios/ entry is a
# symlink into backup-YYYY-MM-monthly, created by g_backup's monthly anchor).
# Usage: f_bk_is_monthly_alias <date>
function f_bk_is_monthly_alias {
  local f_date="$1" f_base="$g_bk_snap_base"
  if [[ -L "$f_base/backup-$f_date/symbios" ]]
  then
    case "$(readlink "$f_base/backup-$f_date/symbios")" in
      *"backup-${f_date:0:7}-monthly"*) return 0 ;;
    esac
  fi
  return 1
}

# Prune local hardlink snapshots according to g_bk_keep_{daily,weekly,monthly}
# (grandfather-father-son). The monthly dirs back the month-long retention;
# dailies keep the newest N plus N Monday dailies. Monthly-alias dailies are
# kept only for months whose monthly dir is still retained (they are the
# restore entry point for those blocks). Runs after every snapshot so the
# disk can never grow unbounded.
function f_bk_prune_local {
  local f_base="$g_bk_snap_base"
  [[ -d "$f_base" ]] || return 0
  local f_date f_dow f_week f_month f_ym
  local -A f_seen_week=()
  local f_days=0 f_weeks=0 f_keep_monthly="" f_m f_list
  # Newest-first list of daily dates
  f_list=$(f_bk_list_local_dates)
  # Keep the newest g_bk_keep_monthly monthly dirs (by YYYY-MM)
  f_keep_monthly=$(f_bk_list_local_monthly | head -n "$g_bk_keep_monthly")
  # Pass 1: decide which dailies stay
  for f_date in $f_list
  do
    f_month="${f_date:0:7}"
    f_dow=$(date -d "$f_date" +%u 2>/dev/null) || continue
    f_week=$(date -d "$f_date" +%G-W%V 2>/dev/null) || continue
    if f_bk_is_monthly_alias "$f_date"
    then
      # Alias of a STILL-KEPT month: preserve as restore entry point.
      # Alias of a dropped month: remove it (its monthly dir falls in pass 2).
      if echo "$f_keep_monthly" | grep -q "^${f_month}$"
      then
        continue
      fi
      f_bk_remove_local_entry "backup-$f_date"
      continue
    fi
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
    # Daily is neither new enough for daily/weekly nor an alias of a kept
    # monthly -> remove it
    f_bk_remove_local_entry "backup-$f_date"
  done
  # Pass 2: drop monthly dirs beyond the retention window
  for f_m in $(f_bk_list_local_monthly | tail -n +$(( $g_bk_keep_monthly + 1 )))
  do
    f_bk_remove_local_entry "backup-$f_m-monthly"
  done
}

# Free space on the data root in MB (df on the mount that holds g_data_root).
function f_bk_free_mb {
  df -P -B1M "$g_data_root" 2>/dev/null | awk 'NR==2{print $4}'
}

# Free space on the data root in percent (100 - used).
function f_bk_free_percent {
  local f_free f_total
  f_free=$(f_bk_free_mb)
  f_total=$(df -P -B1M "$g_data_root" 2>/dev/null | awk 'NR==2{print $2}')
  [[ "$f_free" =~ ^[0-9]+$ && "$f_total" =~ ^[0-9]+$ && "$f_total" -gt 0 ]] \
    && echo $(( f_free * 100 / f_total )) || echo 0
}

# True if the data root is below the free-space guard limits.
function f_bk_disk_low {
  local f_free f_pct
  f_free=$(f_bk_free_mb)
  f_pct=$(f_bk_free_percent)
  [[ "$f_free" =~ ^[0-9]+$ && "$f_free" -lt "$g_bk_min_free_gb" ]] && return 0
  [[ "$f_pct" =~ ^[0-9]+$ && "$f_pct" -lt "$g_bk_min_free_percent" ]] && return 0
  return 1
}

# Free-space guard: if the disk is low, prune the OLDEST local snapshots
# (dailies first, then monthlies) until the guard is satisfied. Returns 1
# when nothing more can be pruned and the backup must NOT run (disk full).
function f_bk_guard_free_space {
  f_bk_disk_low || return 0
  g_echo_warn "Data root below free-space guard (min ${g_bk_min_free_gb}GB/${g_bk_min_free_percent}%) - pruning oldest snapshots first"
  while f_bk_disk_low
  do
    local f_oldest f_oldest_monthly
    f_oldest=$(f_bk_list_local_dates | tail -n 1)
    if [[ -n "$f_oldest" ]]
    then
      # Prune the oldest daily first
      f_bk_remove_local_entry "backup-$f_oldest"
      continue
    fi
    # All dailies gone - fall back to the oldest monthly dirs
    f_oldest_monthly=$(f_bk_list_local_monthly | tail -n 1)
    if [[ -n "$f_oldest_monthly" ]]
    then
      f_bk_remove_local_entry "backup-$f_oldest_monthly-monthly"
      continue
    fi
    break
  done
  if f_bk_disk_low
  then
    g_echo_error "Disk still below ${g_bk_min_free_gb}GB/${g_bk_min_free_percent}% even after pruning all snapshots - aborting backup"
    return 1
  fi
  g_echo_ok "Free space guard satisfied after pruning snapshots"
  return 0
}
