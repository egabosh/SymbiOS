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
# Requires symbios-lib.sh to be sourced first (provides g_* layout globals,
# f_json_escape and g_tmp).
#
# The backup model is restic only. Every repository (remote or local) is
# created on first use and encrypted with the repository password file:
#
#   - Remote targets: the backup_servers list (plus a legacy primary that
#     still lives in the backup_server_* keys). Each target gets its own
#     repository below PATH/$(hostname)/ over SFTP with its own retention.
#   - Local repository: <data_root>/backup/restic (used when no remote
#     target is configured).
#
# Configuration source: inventory.yml (all.vars)
#   backup_servers       list of restic targets, each a dict {name,host,
#                        port,user,path,keep_daily,keep_weekly,keep_monthly}
#   backup_exclude       list of extra exclude patterns (paths below the
#                        data root, converted to restic patterns)
#   backup_keep_daily / backup_keep_weekly / backup_keep_monthly
#                        restic retention for the primary target and the
#                        local repository
#   backup_min_free_gb / backup_min_free_percent
#                        disk guard: abort before the disk fills up

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
provides the restic plumbing shared by the engine, the listing and the
restore (repository URLs, the restic runner with error capture, exclude
building, snapshot lookup, free-space guard).

Configuration (inventory.yml, all.vars):
  backup_servers       list of restic targets ({name,host,port,user,path,
                       keep_daily,keep_weekly,keep_monthly})
  backup_exclude       list of extra exclude patterns
  backup_keep_daily / backup_keep_weekly / backup_keep_monthly
                       restic retention (primary target + local repository)
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

# Restic retention defaults (primary target + local repository):
# 7 dailies, 4 weeklies, all monthlies. 0 disables a level.
g_bk_keep_daily=7
g_bk_keep_weekly=4
g_bk_keep_monthly=9999

# Local disk guard: the nightly backup aborts when free space on the data
# root drops below these limits. Filling the disk would break the running
# services; restic retention bounds the repository size on every run.
g_bk_min_free_gb=3
g_bk_min_free_percent=15

# Read all backup-related settings from inventory.yml into g_bk_* globals.
function f_bk_read_vars {
  g_bk_host="$(f_symbios_var backup_server_host "")"
  g_bk_port="$(f_symbios_var backup_server_port "22")"
  g_bk_user="$(f_symbios_var backup_server_user "root")"
  g_bk_path="$(f_symbios_var backup_server_path "")"
  # Local restic repository (fallback target when no server is configured).
  g_bk_local_repo="${g_data_root}/backup/restic"
  # Restic repository password file - MUST be stored under /symbios only.
  g_bk_restic_pw_file="${g_config_dir}/.backup_restic_password"
  if [[ ! -s "$g_bk_restic_pw_file" ]]; then
    g_bk_restic_pw_file="${g_data_root}/.backup_restic_password"
  fi
  export RESTIC_PASSWORD_FILE="$g_bk_restic_pw_file"
  # SSH client key: the host's own root key.
  g_bk_ssh_key="$(f_symbios_var backup_ssh_key "/root/.ssh/id_ed25519")"
  g_bk_ssh_pubkey="${g_bk_ssh_key}.pub"
  # Captured restic stderr (error details for the status JSON / WebUI).
  g_bk_err_file="${g_tmp}/restic.err"
  touch "$g_bk_err_file" 2>/dev/null || true
  # Retention and disk guard overrides from inventory.yml.
  g_bk_rkeep_daily="$(f_symbios_var backup_keep_daily "$g_bk_keep_daily")"
  g_bk_rkeep_weekly="$(f_symbios_var backup_keep_weekly "$g_bk_keep_weekly")"
  g_bk_rkeep_monthly="$(f_symbios_var backup_keep_monthly "$g_bk_keep_monthly")"
  g_bk_min_free_gb="$(f_symbios_var backup_min_free_gb "$g_bk_min_free_gb")"
  g_bk_min_free_percent="$(f_symbios_var backup_min_free_percent "$g_bk_min_free_percent")"
}

# List all configured restic targets as TSV lines (tab separated):
#   name  host  port  user  path  keep_daily  keep_weekly  keep_monthly
# All targets are stored in the unified backup_servers array. For backward
# compatibility, a primary target that still lives only in the legacy
# backup_server_* keys (pre-unification inventories) is synthesized as the
# first row unless the array already contains the same host+path.
function f_bk_targets_tsv {
  local f_json f_name
  f_name="$(f_symbios_var backup_server_name "")"
  f_json="$("$g_symbios_dir/symbios-inventory.py" \
    --inventory "${g_inventory}" get --json backup_servers 2>/dev/null)" || f_json="[]"
  BK_HOST="$g_bk_host" BK_PATH="$g_bk_path" BK_USER="$g_bk_user" BK_PORT="$g_bk_port" \
  BK_NAME="$f_name" BK_KEEP_DAILY="$g_bk_rkeep_daily" BK_KEEP_WEEKLY="$g_bk_rkeep_weekly" \
  BK_KEEP_MONTHLY="$g_bk_rkeep_monthly" \
  python3 -c '
import json, sys, os

def num(value, default):
    if value in (None, ""):
        return str(default)
    try:
        v = int(value)
    except (TypeError, ValueError):
        return str(default)
    return str(v if 0 <= v <= 99999 else default)

try:
    data = json.load(sys.stdin) or []
except Exception:
    data = []

rows = []
for srv in data:
    if not isinstance(srv, dict):
        continue
    host = str(srv.get("host") or "").strip()
    path = str(srv.get("path") or "").strip()
    user = str(srv.get("user") or "").strip() or "root"
    name = str(srv.get("name") or "").strip() or host
    if not host or not path:
        continue
    if not path.startswith("/"):
        path = "/" + path
    rows.append((name, host, num(srv.get("port"), 22), user, path,
                 num(srv.get("keep_daily"), 7),
                 num(srv.get("keep_weekly"), 4),
                 num(srv.get("keep_monthly"), 9999)))

# Backward compatibility: legacy primary keys not covered by the array yet
host = os.environ.get("BK_HOST", "").strip()
path = os.environ.get("BK_PATH", "").strip()
if host and path:
    if not path.startswith("/"):
        path = "/" + path
    if not any(r[1] == host and r[4] == path for r in rows):
        name = os.environ.get("BK_NAME", "").strip() or os.uname().nodename
        user = os.environ.get("BK_USER", "").strip() or "root"
        port = os.environ.get("BK_PORT", "").strip() or "22"
        kd = os.environ.get("BK_KEEP_DAILY", "").strip() or "7"
        kw = os.environ.get("BK_KEEP_WEEKLY", "").strip() or "4"
        km = os.environ.get("BK_KEEP_MONTHLY", "").strip() or "9999"
        rows.insert(0, (name, host, num(port, 22), user, path,
                        num(kd, 7), num(kw, 4), num(km, 9999)))

for row in rows:
    print("\t".join(row))
' <<< "$f_json"
}

# True if at least one remote restic target is configured.
function f_bk_has_targets {
  [[ -n "$(f_bk_targets_tsv)" ]]
}

# Pre-flight for the SSH key. Without this the only symptom of a missing or
# passphrase-protected key is a generic "Permission denied" on the remote, and
# a key rotation on the host silently stops every backup.
function f_bk_check_ssh_key {
  f_bk_has_targets || return 0

  local f_why=""
  f_why="$(f_symbios_ssh_key_usable "$g_bk_ssh_key")" || {
    g_echo_error "Backup key ${g_bk_ssh_key} ${f_why} - no backup possible."
    g_echo_error "Fix the key, or point backup_ssh_key in inventory.yml at another one."
    return 1
  }

  return 0
}

# Repository URL of a TSV target line ("local" -> the local repository path).
# The double slash in the sftp URL is restic's syntax for an absolute path;
# every client gets its own repository below PATH/$(hostname).
function f_bk_repo_url {
  if [[ "${1:-}" == "local" ]]
  then
    echo "$g_bk_local_repo"
    return 0
  fi
  local f_name f_host f_port f_user f_path
  IFS='|' read -r f_name f_host f_port f_user f_path _ <<< "$1"
  echo "sftp://${f_user}@${f_host}:${f_port}//${f_path#/}/$(hostname)"
}

# ssh options for restic's sftp backend. ServerAlive* keeps the connection
# alive while restic processes a lot of unchanged data; the key is passed
# explicitly because the target may limit the authentication tries.
function f_bk_sshargs {
  local f_args="-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
  [[ -r "$g_bk_ssh_key" ]] && f_args="-i $g_bk_ssh_key $f_args"
  echo "$f_args"
}

# Run one restic command. All stderr is captured in g_bk_err_file (error
# details for syslog summaries and the status JSON / WebUI); callers log
# a summary via the g_echo family after the run.
# Usage: f_bk_restic <repo> <sshargs|''> <restic-args...>
function f_bk_restic {
  local f_repo="$1" f_ssh="$2"
  shift 2
  local f_rc=0
  if [[ -n "$f_ssh" ]]
  then
    RESTIC_REPOSITORY="$f_repo" restic "$@" -o "sftp.args=$f_ssh" 2>>"$g_bk_err_file" || f_rc=$?
  else
    RESTIC_REPOSITORY="$f_repo" restic "$@" 2>>"$g_bk_err_file" || f_rc=$?
  fi
  return $f_rc
}

# Meaningful tail of the captured restic stderr: carriage returns from
# progress output are split, empty lines dropped. Usage: f_bk_err_tail [file]
function f_bk_err_tail {
  local f_file="${1:-$g_bk_err_file}"
  [[ -r "$f_file" ]] || return 0
  tr '\r' '\n' < "$f_file" | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -n 25
}

# A newline list as a JSON array fragment (["...", ...]).
# Usage: f_bk_lines_json <line> [line ...]
function f_bk_lines_json {
  local f_first=1 f_line f_out="["
  local f_arr=("$@")
  for f_line in ${f_arr[@]+"${f_arr[@]}"}
  do
    [[ $f_first -eq 1 ]] && f_first=0 || f_out="$f_out,"
    f_out="$f_out$(printf '%s' "$f_line" | f_json_escape)"
  done
  echo "${f_out}]"
}

# The captured error tail as a JSON array fragment (for the status JSON).
function f_bk_err_tail_json {
  local f_line
  local f_arr=()
  while IFS= read -r f_line
  do
    f_arr+=("$f_line")
  done < <(f_bk_err_tail)
  f_bk_lines_json ${f_arr[@]+"${f_arr[@]}"}
}

# Make sure the repository exists and opens with the configured password. A
# missing repository is initialized on first use; every other error (wrong
# password, no permission, host down) fails the target.
# Usage: f_bk_restic_ensure_repo <repo> <sshargs|''>
function f_bk_restic_ensure_repo {
  local f_repo="$1" f_ssh="$2"
  : > "$g_bk_err_file"
  if f_bk_restic "$f_repo" "$f_ssh" snapshots >/dev/null
  then
    return 0
  fi
  if f_bk_err_tail | grep -qiE "no such file or directory|does not exist|unable to open config file"
  then
    g_echo_note "Creating restic repository $f_repo"
    : > "$g_bk_err_file"
    if f_bk_restic "$f_repo" "$f_ssh" init
    then
      return 0
    fi
    g_echo_error "Repository $f_repo could not be created - check the write permission of the backup target."
    return 1
  fi
  g_echo_error "Repository $f_repo is not usable: $(f_bk_err_tail | tail -n 1)"
  return 1
}

# Write the restic exclude file for the backup and the full restore.
# Patterns are unanchored ("**/" prefix) so they match below every backup
# source root (/symbios and /root/.ssh); this mirrors the rsync-era
# semantics of the inventory patterns (paths relative to the data root).
# Usage: f_bk_write_excludes <outfile>
function f_bk_write_excludes {
  local f_out="$1"
  local f_dir
  {
    # Built-in defaults: never back up the local repository itself, skip
    # docker/containerd internals (images/layers are re-pullable), keep
    # volumes and all other data. Runtime noise that must not be copied:
    for f_dir in backup docker/overlay2 docker/overlay docker/containers \
                docker/image docker/buildkit docker/network docker/plugins \
                docker/runtimes docker/swarm docker/containerd docker/rootfs \
                docker/tmp containerd
    do
      echo "**/$f_dir"
    done
    echo "**/__pycache__/"
    # Never back up the backup credentials themselves (.backup_restic_password
    # in the config dir): a repository password inside its own encrypted
    # repository is useless (chicken and egg) - it lives in the WebUI /
    # off-site instead.
    echo "**/.backup*"
    # User-defined excludes from inventory.yml (one path per line, relative
    # to the data root; # comments are skipped)
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
    line = str(line).strip().lstrip('/')
    if line and not line.startswith('#'):
        print('**/' + line)
PYEOF
    fi
  } > "$f_out"
}

# Print the short id of the newest snapshot of <date> in <repo> (empty
# when the repository holds none). Usage: f_bk_restic_find_sid <repo> <sshargs|''> <YYYY-MM-DD>
function f_bk_restic_find_sid {
  local f_repo="$1" f_ssh="$2" f_date="$3"
  f_bk_restic "$f_repo" "$f_ssh" snapshots --json | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in data:
    t = s.get('time', '')
    if t[:10] == '$f_date':
        print(s.get('short_id') or s.get('id'))
        break
"
  return 0
}

# Print the snapshot dates of a repository (YYYY-MM-DD, unique, newest
# first). Returns the restic exit code so callers can warn about an
# unreachable repository. Usage: f_bk_restic_dates <repo> <sshargs|''>
function f_bk_restic_dates {
  local f_repo="$1" f_ssh="$2"
  local f_json f_rc=0
  f_json="$(f_bk_restic "$f_repo" "$f_ssh" snapshots --json)" || f_rc=$?
  if [[ $f_rc -ne 0 ]]
  then
    return $f_rc
  fi
  printf '%s' "$f_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
dates = set()
for s in data:
    t = s.get('time', '')
    if len(t) >= 10:
        dates.add(t[:10])
for d in sorted(dates, reverse=True):
    print(d)
"
  return 0
}

# Resolve how a given date can be restored. Sets g_bk_src_kind to
# "local-restic" or "remote-restic", g_restic_target to the TSV line (or
# "local") and g_restic_sid to the short snapshot id. Returns 1 when no
# repository holds that date. Usage: f_bk_resolve_source <YYYY-MM-DD>
function f_bk_resolve_source {
  local f_date="$1"
  g_bk_src_kind=""
  g_restic_target=""
  g_restic_sid=""
  command -v restic >/dev/null 2>&1 || return 1
  [[ -s "${g_bk_restic_pw_file:-}" ]] || return 1
  export RESTIC_PASSWORD_FILE="$g_bk_restic_pw_file"
  # Local repository first (cheapest, no network round trip).
  if [[ -d "$g_bk_local_repo" ]]
  then
    g_restic_sid="$(f_bk_restic_find_sid "$g_bk_local_repo" "" "$f_date")"
    if [[ -n "$g_restic_sid" ]]
    then
      g_bk_src_kind="local-restic"
      g_restic_target="local"
      return 0
    fi
  fi
  # Remote targets in configured order (primary first).
  local f_line
  while IFS= read -r f_line
  do
    [[ -n "$f_line" ]] || continue
    g_restic_sid="$(f_bk_restic_find_sid "$(f_bk_repo_url "$f_line")" "$(f_bk_sshargs)" "$f_date")"
    if [[ -n "$g_restic_sid" ]]
    then
      g_bk_src_kind="remote-restic"
      g_restic_target="$f_line"
      return 0
    fi
  done < <(f_bk_targets_tsv)
  return 1
}

# Local repository stats as a JSON fragment for the backup status extra:
# "snapshot_count":N,"snapshot_size_mb":M (no leading comma; f_write_status
# prepends one). Empty values when no local repository exists.
function f_bk_stats_json {
  local f_count=0 f_size_mb=0
  if [[ -d "$g_bk_local_repo" ]]
  then
    f_count=$(f_bk_restic "$g_bk_local_repo" "" snapshots --json | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)
")
    # du -sx counts hardlinked files once (-x: stay on the repository fs).
    f_size_mb=$(du -sx -B1M "$g_bk_local_repo" 2>/dev/null | awk '{print $1}')
    [[ "$f_size_mb" =~ ^[0-9]+$ ]] || f_size_mb=0
  fi
  printf '"snapshot_count":%s,"snapshot_size_mb":%s' "$f_count" "$f_size_mb"
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

# Free-space guard: abort the run when the data root is below the limits.
# restic retention (forget --prune) already bounds the repository size on
# every run - filling the disk anyway would break the running services.
function f_bk_guard_free_space {
  if f_bk_disk_low
  then
    g_echo_error "Data root below free-space guard (min ${g_bk_min_free_gb}GB/${g_bk_min_free_percent}% free) - aborting before the disk fills up."
    return 1
  fi
  return 0
}
