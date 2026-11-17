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

# A restic run to a remote target can be aborted from the outside (a network
# hiccup, a container recreate on the target host). The data is still fine
# and restic skips what it already uploaded, so the run is retried instead of
# losing the whole night.
g_bk_retry_attempts=3
g_bk_retry_wait=120

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
  # Normalize the configured servers (defaults, leading slash, numeric guards)
  # and prepend the legacy primary target when the array does not cover it yet.
  jq -r \
    --arg host "$g_bk_host" --arg path "$g_bk_path" --arg name "$f_name" \
    --arg user "$g_bk_user" --arg port "$g_bk_port" \
    --arg kd "$g_bk_rkeep_daily" --arg kw "$g_bk_rkeep_weekly" \
    --arg km "$g_bk_rkeep_monthly" --arg node "$(uname -n)" '
    # int-or-default with the range guard the numeric keys had before
    def num(v; d):
      if v == null or v == "" then d
      else (try (v | if type == "number" then . else (tostring | tonumber) end) catch d) as $n
        | if ($n | type) == "number" and ($n | floor) == $n and $n >= 0 and $n <= 99999
          then $n else d end
      end;
    def clean(v): (v // "") | tostring | gsub("^\\s+|\\s+$"; "");
    def orz(v; d): clean(v) as $c | if $c == "" then d else $c end;
    def slash(p): if (p | startswith("/")) then p else "/" + p end;
    [ .[]? | select(type == "object")
      | clean(.host) as $h | clean(.path) as $p
      | select($h != "" and $p != "")
      | [ orz(.name; $h), $h, num(.port; 22), orz(.user; "root"), slash($p),
          num(.keep_daily; 7), num(.keep_weekly; 4), num(.keep_monthly; 9999) ] ] as $rows
    | (if ($host != "" and $path != "")
         and ([ $rows[] | select(.[1] == $host and .[4] == slash($path)) ] | length == 0)
       then [ [ (if $name == "" then $node else $name end), $host, num($port; 22),
                (if $user == "" then "root" else $user end), slash($path),
                num($kd; 7), num($kw; 4), num($km; 9999) ] ] + $rows
       else $rows end)
    | .[] | @tsv
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

# Run a restic command and retry it when it fails. A killed or interrupted
# run leaves its lock behind, so every attempt is preceded by a stale-lock
# cleanup: "unlock" without arguments never touches a lock of a live process,
# it only removes the leftovers of a dead one. A retried backup resumes
# where the previous attempt stopped - restic skips data it already stored.
# Usage: f_bk_restic_retry <repo> <sshargs|''> <restic-args...>
function f_bk_restic_retry {
  local f_repo="$1" f_ssh="$2"
  shift 2
  local f_attempt=1 f_rc=0
  while true
  do
    f_bk_restic "$f_repo" "$f_ssh" unlock
    f_bk_restic "$f_repo" "$f_ssh" "$@"
    f_rc=$?
    if [[ $f_rc -eq 0 ]]
    then
      return 0
    fi
    if [[ $f_attempt -ge $g_bk_retry_attempts ]]
    then
      g_echo_error "restic failed after $g_bk_retry_attempts attempts (last rc $f_rc)"
      return $f_rc
    fi
    g_echo_warn "restic failed (attempt $f_attempt/$g_bk_retry_attempts, rc $f_rc) - retrying in ${g_bk_retry_wait}s"
    sleep "$g_bk_retry_wait"
    f_attempt=$((f_attempt + 1))
  done
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
  # A lock file that the repository user cannot read (e.g. created by a
  # "restic mount" running as root on the backup server) makes every restic
  # call fail with a bare "permission denied" - name the real cause.
  if f_bk_err_tail | grep -qi "locks/" && f_bk_err_tail | grep -qi "permission denied"
  then
    g_echo_error "Repository $f_repo is locked by a process running as another user (e.g. 'restic mount' on the backup server) - stop it and retry."
    return 1
  fi
  g_echo_error "Repository $f_repo is not usable: $(f_bk_err_tail | tail -n 1)"
  return 1
}

# Write the restic exclude file for the backup and the full restore.
# restic matches a pattern against the complete path of an entry, so the
# built-in directory patterns are anchored to the data root: an unanchored
# "**/docker" would also drop every equally named directory anywhere below
# the sources - a user folder "backup" inside the Nextcloud data would
# silently disappear from the backup. Only the generic noise patterns stay
# unanchored on purpose.
# Usage: f_bk_write_excludes <outfile>
function f_bk_write_excludes {
  local f_out="$1"
  local f_root="${g_data_root%/}"
  {
    # Built-in defaults. Never back up the local repository itself - its
    # parent ${data_root}/backup holds regular data (service config copies)
    # and stays in the snapshot:
    echo "$f_root/backup/restic"
    # Skip the whole docker/containerd state (images and layers are
    # re-pullable, named volumes live below services/), keep all other data:
    echo "$f_root/docker"
    echo "$f_root/containerd"
    # Nextcloud file previews are regenerated on demand - skip them:
    echo "$f_root/services/nextcloud/nextcloud-data/data/appdata_*/preview/"
    # Runtime noise that must not be copied, wherever it appears:
    echo "**/__pycache__/"
    # Never back up the backup credentials themselves (.backup_restic_password
    # in the config dir): a repository password inside its own encrypted
    # repository is useless (chicken and egg) - it lives in the WebUI /
    # off-site instead.
    echo "**/.backup*"
    # User-defined excludes from inventory.yml (one path per line, relative
    # to the data root; # comments are skipped). Read through the inventory
    # CLI - the file itself is never parsed here.
    if [[ -r "${g_inventory}" ]]
    then
      "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
        get --json backup_exclude 2>/dev/null \
        | jq -r --arg root "$f_root" '
            .[]? | tostring | gsub("^\\s+|\\s+$"; "")
            | select(length > 0 and (startswith("#") | not))
            | $root + "/" + sub("^/+"; "")
          '
    fi
  } > "$f_out"
}

# Print the short id of the newest snapshot of <date> in <repo> (empty
# when the repository holds none). Usage: f_bk_restic_find_sid <repo> <sshargs|''> <YYYY-MM-DD>
function f_bk_restic_find_sid {
  local f_repo="$1" f_ssh="$2" f_date="$3"
  f_bk_restic "$f_repo" "$f_ssh" snapshots --json 2>/dev/null \
    | jq -r --arg d "$f_date" \
        '.[]? | select((.time // "")[0:10] == $d) | (.short_id // .id) // empty' \
    | head -n1
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
  # Unique dates, newest first (jq emits nothing on unparsable input).
  jq -r '[.[]? | (.time // "")[0:10] | select(length == 10)] | unique | reverse | .[]' \
    <<< "$f_json" 2>/dev/null
  return 0
}

# Resolve how a given date can be restored. Sets g_bk_src_kind to
# "local-restic" or "remote-restic", g_restic_target to the target line in
# the "|"-joined form f_bk_repo_url expects (or "local") and g_restic_sid to
# the short snapshot id. Returns 1 when no repository holds that date.
# Usage: f_bk_resolve_source <YYYY-MM-DD>
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
  # Remote targets in configured order (primary first). f_bk_targets_tsv
  # prints tab separated lines, f_bk_repo_url and the restore script's source
  # description read them "|"-joined - convert once here.
  local f_line f_pipe
  while IFS= read -r f_line
  do
    [[ -n "$f_line" ]] || continue
    f_pipe="${f_line//$'\t'/|}"
    g_restic_sid="$(f_bk_restic_find_sid "$(f_bk_repo_url "$f_pipe")" "$(f_bk_sshargs)" "$f_date")"
    if [[ -n "$g_restic_sid" ]]
    then
      g_bk_src_kind="remote-restic"
      g_restic_target="$f_pipe"
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
    # Number of snapshots in the local repository (jq prints nothing when
    # restic output is not parsable - the guard below turns that into 0).
    f_count=$(f_bk_restic "$g_bk_local_repo" "" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null)
    [[ "$f_count" =~ ^[0-9]+$ ]] || f_count=0
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
