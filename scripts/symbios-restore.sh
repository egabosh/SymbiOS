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
# symbios-restore.sh - Restore snapshots created by symbios-backup.sh
# (restic repositories: local and/or remote SFTP targets).
#
# Usage:
#   symbios-restore.sh plan <YYYY-MM-DD> [<service>|--full|--file <path>]
#       Show (as JSON) what a restore would do - no changes are made.
#   symbios-restore.sh restore <YYYY-MM-DD> [<service>|--full|--file <path>] [--target <path>] [--to-original] [--yes]
#       Perform the restore. Without --yes nothing is executed (safety).
#   symbios-restore.sh find <YYYY-MM-DD> <pattern>
#       Search for files in a snapshot (JSON).
#   symbios-restore.sh ls <YYYY-MM-DD> [<path>]
#       List files in a snapshot directory (raw restic output).
#
# Service restore: stops the affected docker compose stack(s), restores
# their directories (services/<name> and/or base-services/<name>) from the
# restic snapshot, re-imports matching database dumps found in the snapshot
# and starts the stack(s) again.
#
# Full restore: stops Docker, restores the whole data root plus /root/.ssh
# from the snapshot, restarts Docker and reapplies all playbooks.
#
# restic restore semantics relied on here (verified with restic 0.18):
#   - The snapshot tree stores the ORIGINAL ABSOLUTE paths; restoring with
#     "--target /" writes every file back to its exact original location.
#   - "--delete" is only ever combined with "--include" patterns: in include
#     mode the delete walker removes exactly the entries below an include
#     pattern that are not part of the snapshot. Everything outside the
#     include patterns is never touched.
#   - NEVER combine "--delete" with exclude-only filtering: in exclude mode
#     the delete walker would remove EVERY entry of a visited target
#     directory that is not in the snapshot (up to and including the whole
#     filesystem root when restoring with "--target /").
#   - Negated include patterns ("!pattern") keep paths out of the restore
#     AND out of the delete walk (protection for the local backup
#     repository, docker internals and the repository password file).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <plan|restore> <YYYY-MM-DD> [<service>|--full|--file <path>] [--target <path>] [--to-original] [--yes]

Restore snapshots created by symbios-backup.sh (restic repositories).

  plan <YYYY-MM-DD> [<service>|--full|--file <path>]
      Show (as JSON) what a restore would do - no changes are made.
  restore <YYYY-MM-DD> [<service>|--full|--file <path>] [--target <path>] [--to-original] [--yes]
      Perform the restore. Without --yes nothing is executed (safety).
  find <YYYY-MM-DD> <pattern>
      Search for files in a snapshot (JSON).
  ls <YYYY-MM-DD> [<path>]
      List files in a snapshot directory (raw restic output).

Scopes:
  <service>     Stop the service's docker compose stack(s), restore its
                directories (services/<name> and/or base-services/<name>)
                from the snapshot, re-import its database dumps and start
                the stack(s) again.
  --full        Stop Docker, restore the whole data root plus /root/.ssh
                from the snapshot, restart Docker and reapply all
                playbooks.
  --file <path> Restore a single file (absolute snapshot path) into a
                staging directory (--target/--to-original optional).

Options:
  --target <path>     Restore --file into this directory instead of the
                     staging directory.
  --to-original       Restore --file back to its original location.
  --yes               Actually execute the restore.
  -h, --help          Show this help and exit

Exit codes: 0 = ok, 1 = error (JSON error message on stdout).
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Query actions (plan/find/ls) print JSON/raw output on stdout: skip the
# gaboshlib stdout/stderr FIFO redirection (g_all-to-syslog) so the output
# stays machine-parseable. The actual restore run keeps full logging (it
# streams into the WebUI job modal).
[[ "${1:-}" == "plan" || "${1:-}" == "find" || "${1:-}" == "ls" ]] && g_alltosyslog=1
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

# Share the backup lockfiles: never restore while a backup runs (or vice
# versa). Two locks cover both entry points (dispatcher and engine).
# g_lockfile is a function AND its own guard variable - clear only the
# variable (plain assignment) so the function stays callable for lock #2.
g_scriptname="backup"
g_lockfile
g_lockfile=""
g_scriptname="symbios-backup"
g_lockfile
g_nice
g_all-to-syslog
set -o pipefail

# Read backup settings (targets, repository password, ssh key).
f_bk_read_vars

# Print {"ok":false,...} and exit - used for every validation error.
function f_die_json {
  printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$1" | f_json_escape)"
  exit 1
}

### Argument handling ###

g_action="$1"; shift || true
g_date="$1"; shift || true
g_scope="--full"
g_yes=""
g_file=""
g_target=""
g_to_original=""
while [[ $# -gt 0 ]]
do
  case "$1" in
    --yes) g_yes="1" ;;
    --to-original) g_to_original="1" ;;
    --file) shift; g_file="${1:-}"; g_scope="--file" ;;
    --target) shift; g_target="${1:-}" ;;
    # The whole-system scope is an explicit option too (the WebUI always
    # sends it), so it must be matched before the catch-all below.
    --full) g_scope="--full" ;;
    --*) f_die_json "Unknown option '$1'." ;;
    *) [[ "$g_scope" == "--full" ]] && g_scope="$1" ;;
  esac
  shift
done

[[ "$g_action" == "plan" || "$g_action" == "restore" || "$g_action" == "find" || "$g_action" == "ls" ]] \
  || f_die_json "Usage: symbios-restore.sh {plan|restore|find|ls} <YYYY-MM-DD> [<service>|--full|--file <path>] [--target <path>] [--yes]"

if [[ "$g_action" == "find" ]]
then
  g_pattern="$g_scope"
  [[ "$g_pattern" != "--full" && -n "$g_pattern" ]] || f_die_json "Missing search pattern"
elif [[ "$g_action" == "ls" ]]
then
  g_lspath="$g_scope"
  [[ "$g_lspath" == "--full" || -z "$g_lspath" ]] && g_lspath="/"
else
  [[ "$g_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || f_die_json "Invalid date '$g_date' - expected YYYY-MM-DD."
  [[ "$g_scope" == "--full" || "$g_scope" == "--file" || "$g_scope" =~ ^[A-Za-z0-9._-]+$ ]] \
    || f_die_json "Invalid service name '$g_scope'."
  [[ "$g_scope" != "--file" || -n "$g_file" ]] || f_die_json "Missing file path for --file."
fi

### Source resolution ###

# Resolve which repository holds the requested date: the local repository
# first (cheapest), then every configured remote target in order. Sets
# g_bk_src_kind, g_restic_target (TSV line or "local") and g_restic_sid.
if ! f_bk_resolve_source "$g_date"
then
  f_die_json "No snapshot found for $g_date."
fi

# Repository and ssh context of the resolved target - all restic calls
# below use these.
g_repo="$(f_bk_repo_url "$g_restic_target")"
g_sshargs=""
if [[ "$g_restic_target" != "local" ]]
then
  g_sshargs="$(f_bk_sshargs)"
fi
export RESTIC_REPOSITORY="$g_repo"

# Human-readable source description for the plan output.
case "$g_bk_src_kind" in
  local-restic)  g_src_desc="local restic repository (${g_bk_local_repo})" ;;
  remote-restic)
    f_tname=""
    IFS='|' read -r f_tname _ <<< "$g_restic_target"
    g_src_desc="restic snapshot on ${f_tname}"
    ;;
esac

# Run restic against the resolved repository with LIVE progress output
# (restic's progress goes to stderr, which the WebUI job modal streams).
# Used for the restore/find/ls actions; parsing helpers below use the
# quiet f_bk_restic runner from symbios-backup-lib.sh instead.
function f_r_restic {
  if [[ -n "$g_sshargs" ]]
  then
    restic "$@" -o "sftp.args=$g_sshargs"
  else
    restic "$@"
  fi
}

### Snapshot index ###

# Index of all paths in the resolved snapshot (one absolute path per line,
# from a single "restic ls --json" call - cheaper than probing per path).
function f_snap_index {
  f_bk_restic "$g_repo" "$g_sshargs" ls "$g_restic_sid" --json | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get('message_type') == 'node' or d.get('struct_type') == 'node':
        p = d.get('path')
        if p:
            print(p)
" > "${g_tmp}/snap-paths"
}

# True if the given absolute directory exists in the snapshot.
function f_snap_has_dir {
  [[ -s "${g_tmp}/snap-paths" ]] || f_snap_index
  grep -qxF "$1" "${g_tmp}/snap-paths"
}

# List the *.sql.gz dump basenames available in the snapshot's backups dir.
function f_list_snap_dumps {
  [[ -s "${g_tmp}/snap-paths" ]] || f_snap_index
  grep "^${g_data_root}/backups/[^/]*\.sql\.gz$" "${g_tmp}/snap-paths" | sed 's#.*/##'
}

# Stream one dump (by basename) from the snapshot, already decompressed,
# so it can be piped into a database container.
function f_cat_dump {
  f_r_restic dump "$g_restic_sid" "${g_data_root}/backups/$1" | zcat
}

### find / ls actions (read-only, no scope resolution needed) ###

if [[ "$g_action" == "find" ]]
then
  f_r_restic find "$g_pattern" "$g_restic_sid" --json 2>/dev/null | python3 -c "
import sys, json
res = []
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for snap in data:
    for m in snap.get('matches') or []:
        p = m.get('path')
        if p:
            res.append(p)
print(json.dumps({'ok': True, 'matches': res}))
"
  exit 0
fi

if [[ "$g_action" == "ls" ]]
then
  f_r_restic ls "$g_restic_sid" "$g_lspath" 2>/dev/null | head -200
  exit 0
fi

### Scope resolution ###

# Directory pairs to restore for a single service (relative below /symbios).
g_rel_dirs=()

function f_collect_scope_dirs {
  local f_cand
  # --file restores a single path, not service directories: no scope dirs.
  if [[ "$g_scope" == "--full" || "$g_scope" == "--file" ]]
  then
    return 0
  fi
  for f_cand in "services/$g_scope" "base-services/$g_scope"
  do
    # Include a directory if it exists in the snapshot OR on this system
    if f_snap_has_dir "${g_data_root}/${f_cand}" || [[ -e "${g_data_root}/${f_cand}" ]]
    then
      g_rel_dirs+=("$f_cand")
    fi
  done
  if [[ ${#g_rel_dirs[@]} -eq 0 ]]
  then
    f_die_json "Nothing known about service '$g_scope' (not in snapshot $g_date and not installed here)."
  fi
}

f_collect_scope_dirs

### Plan building ###

g_steps_file="${g_tmp}/steps"
g_warns_file="${g_tmp}/warns"
g_dumps_file="${g_tmp}/dumps"
: > "$g_steps_file"; : > "$g_warns_file"; : > "$g_dumps_file"

# Describe what will happen and collect the database dump candidates.
function f_build_plan {
  local f_dir f_tok f_dump f_found=0
  if [[ "$g_scope" == "--full" ]]
  then
    echo "Stop Docker (all services go offline)" >> "$g_steps_file"
    echo "Restore ALL data below ${g_data_root} from $g_date (${g_src_desc})" >> "$g_steps_file"
    echo "Start Docker again" >> "$g_steps_file"
    echo "Reapply all SymbiOS configuration (playbooks)" >> "$g_steps_file"
    echo "Everything that changed AFTER $g_date will be lost (services created later are removed)." >> "$g_warns_file"
    echo "The server will be unreachable for several minutes." >> "$g_warns_file"
    return 0
  fi

  for f_dir in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    if ! f_snap_has_dir "${g_data_root}/${f_dir}"
    then
      echo "Directory ${g_data_root}/${f_dir} does not exist in snapshot $g_date." >> "$g_warns_file"
    fi
    echo "Stop containers of ${g_data_root}/${f_dir}" >> "$g_steps_file"
    echo "Restore ${g_data_root}/${f_dir} from $g_date (${g_src_desc})" >> "$g_steps_file"
    echo "Start containers of ${g_data_root}/${f_dir} again" >> "$g_steps_file"
  done

  # Database dumps belonging to this service (newest per container token)
  # Tokens: the service name plus every container/service key found in the
  # stack's compose files.
  {
    echo "$g_scope"
    echo "symbios-$g_scope"
    for f_dir in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
    do
      for f_comp in "${g_data_root}/${f_dir}/docker-compose.yml" \
                    "${g_data_root}/${f_dir}/docker-compose.override.yml"
      do
        [[ -r "$f_comp" ]] || continue
        grep -E '^[A-Za-z0-9_.-]+:[[:space:]]*$' "$f_comp" | tr -d ': '
        sed -n 's/^[[:space:]]*container_name:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"'[:space:]]*\).*/\1/p' "$f_comp"
      done
    done
  } | sort -u > "${g_tmp}/tokens"

  # Match dumps whose filename starts with "<token>-"
  while IFS= read -r f_tok
  do
    while IFS= read -r f_dump
    do
      case "$f_dump" in
        "${f_tok}"-*)
          echo "$f_dump" >> "$g_dumps_file"
          f_found=1 ;;
      esac
    done < <(f_list_snap_dumps)
  done < "${g_tmp}/tokens"

  if [[ $f_found -eq 1 ]]
  then
    sort -u "$g_dumps_file" -o "$g_dumps_file"
    while IFS= read -r f_dump
    do
      echo "Re-import database dump $f_dump (newest of this container)" >> "$g_steps_file"
    done < "$g_dumps_file"
  else
    echo "No database dumps found for this service in the snapshot." >> "$g_warns_file"
  fi
}

f_build_plan

# Emit a JSON string array from newline-separated values on stdin.
function f_json_array_stdin {
  local f_first=1 f_item f_out="["
  while IFS= read -r f_item
  do
    [[ -z "$f_item" ]] && continue
    [[ $f_first -eq 1 ]] && f_first=0 || f_out="$f_out,"
    f_out="$f_out$(printf '%s' "$f_item" | f_json_escape)"
  done
  echo "$f_out]"
}

### Output plan (also for restore without --yes) ###
# --file is handled by its own branch below (it has a dedicated plan output).

if { [[ "$g_action" == "plan" ]] || [[ -z "$g_yes" ]]; } && [[ "$g_scope" != "--file" ]]
then
  cat <<EOF
{"ok":true,"action":"plan","date":"$g_date","scope":"$g_scope",
 "source":$(printf '%s' "$g_src_desc" | f_json_escape),
 "steps":$(f_json_array_stdin < "$g_steps_file"),
 "warnings":$(f_json_array_stdin < "$g_warns_file"),
 "dumps":$(f_json_array_stdin < "$g_dumps_file")}
EOF
  exit 0
fi

### Restore execution ###

# Stop the docker compose stack(s) of the given absolute directories plus
# any running containers obviously belonging to the selected service.
function f_stop_stacks {
  local f_dir f_c
  for f_dir in "$@"
  do
    [[ -d "$f_dir" ]] || continue
    if ls "$f_dir"/docker-compose*.yml >/dev/null 2>&1
    then
      g_echo "Stopping stack in $f_dir"
      (cd "$f_dir" && timeout 600 docker compose down --remove-orphans) >/dev/null 2>&1 || true
    fi
  done
  if [[ "$g_scope" != "--full" ]]
  then
    for f_c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i -- "$g_scope")
    do
      g_echo "Stopping container $f_c"
      timeout 120 docker stop "$f_c" >/dev/null 2>&1 || true
    done
  fi
}

# Start the docker compose stack(s) again after the file restore.
function f_start_stacks {
  local f_dir
  for f_dir in "$@"
  do
    [[ -d "$f_dir" ]] || continue
    if ls "$f_dir"/docker-compose*.yml >/dev/null 2>&1
    then
      g_echo "Starting stack in $f_dir"
      (cd "$f_dir" && timeout 900 docker compose up -d) || g_echo_error "Could not start stack in $f_dir"
    fi
  done
}

# Restore the scope directories from the snapshot back onto the live system.
# The --include patterns (original absolute snapshot paths) restrict BOTH
# the restore and the --delete walk to the service directories: files that
# appeared there after the snapshot are removed, everything else on the
# system is never touched.
function f_restore_scope_dirs {
  local f_args=()
  local f_dir
  for f_dir in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    f_snap_has_dir "${g_data_root}/${f_dir}" || continue
    g_echo "Restoring ${g_data_root}/${f_dir}"
    f_args+=(--include "${g_data_root}/${f_dir}")
  done
  [[ ${#f_args[@]} -gt 0 ]] || return 0
  if ! f_r_restic restore "$g_restic_sid" --target / --delete "${f_args[@]}"
  then
    g_echo_error "Restic restore failed for $g_scope - see the output above."
    return 1
  fi
  return 0
}

# Import database dumps of the restored service into their containers.
# Dump naming: <container-token>-<dbname>-<timestamp>.sql.gz
function f_import_db_dumps {
  local f_tok f_container f_newest
  [[ -s "$g_dumps_file" ]] || return 0
  while IFS= read -r f_tok
  do
    # Newest dump for this container token
    f_newest=$(sort -u "$g_dumps_file" | while IFS= read -r f_dump
    do
      case "$f_dump" in
        "${f_tok}"-*) echo "$f_dump" ;;
      esac
    done | sort | tail -1)
    [[ -n "$f_newest" ]] || continue
    # Find the matching running container (exact, prefixed, suffix match)
    f_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x -- "$f_tok" || true)
    [[ -z "$f_container" ]] && f_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x -- "symbios-${f_tok}" || true)
    [[ -z "$f_container" ]] && f_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x -- ".*-${f_tok}" || true)
    if [[ -z "$f_container" ]]
    then
      g_echo_warn "No running container found for dump $f_newest - skipped"
      continue
    fi
    # PostgreSQL: recreate the database and pipe the dump in
    if docker exec "$f_container" env 2>/dev/null | grep -q '^POSTGRES_PASSWORD='
    then
      g_echo "Importing PostgreSQL dump $f_newest into $f_container"
      docker exec "$f_container" sh -c \
        'psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\";" -c "CREATE DATABASE \"$POSTGRES_DB\";"' \
        || { g_echo_error "Recreating database failed ($f_container)"; continue; }
      f_cat_dump "$f_newest" | docker exec -i "$f_container" sh -c \
        'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
        && g_echo_ok "Database import finished ($f_container)" \
        || g_echo_error "Database import had errors ($f_container)"
    # MySQL/MariaDB: pipe the dump into the existing database
    elif docker exec "$f_container" env 2>/dev/null | grep -qE '^(MARIADB|MYSQL)_(PASSWORD|ROOT_PASSWORD)='
    then
      g_echo "Importing MySQL/MariaDB dump $f_newest into $f_container"
      f_cat_dump "$f_newest" | docker exec -i "$f_container" sh -c \
        'if [ -n "$MARIADB_DATABASE" ]; then C=mariadb; U=$MARIADB_USER; P=$MARIADB_PASSWORD; D=$MARIADB_DATABASE; else C=mysql; U=$MYSQL_USER; P=$MYSQL_PASSWORD; D=$MYSQL_DATABASE; fi; exec "$C" -u "$U" -p"$P" "$D"' \
        && g_echo_ok "Database import finished ($f_container)" \
        || g_echo_error "Database import had errors ($f_container)"
    else
      g_echo_warn "Unknown database type in $f_container - dump $f_newest NOT imported"
    fi
  done < "${g_tmp}/tokens"
}

# Write the include patterns for the full restore: the restore scopes as
# plain includes, the backup excludes as NEGATED includes. A negated
# pattern keeps a path out of the restore AND out of the --delete walk
# (local backup repository, docker internals, repository password file).
function f_write_restore_includes {
  f_bk_write_excludes "${g_tmp}/backup-excludes"
  {
    # Restore scopes: the whole data root plus the host's root SSH dir
    # (both are the backup sources).
    echo "$g_data_root"
    echo "${g_data_root}/**"
    if grep -qx "/root/.ssh" "${g_tmp}/snap-paths" 2>/dev/null
    then
      echo "/root/.ssh"
      echo "/root/.ssh/**"
    fi
    # Protected paths derived from the backup exclude list: "**/x" (a
    # directory anywhere in the tree) becomes "!**/x/**", a pattern that
    # already ends in a glob is negated as-is.
    local f_line
    while IFS= read -r f_line
    do
      [[ -n "$f_line" ]] || continue
      f_line="${f_line%/}"
      [[ -z "$f_line" ]] && continue
      case "$f_line" in
        *\*) echo "!$f_line" ;;
        *)   echo "!${f_line}/**" ;;
      esac
    done < "${g_tmp}/backup-excludes"
  } > "${g_tmp}/restore-includes"
  # Note: include patterns that end without a glob get "/**" appended so
  # the whole subtree is protected, matching the rsync-era semantics.
}

# Build the --include argument array from the include pattern file.
# Usage: f_include_args <file> (appends to the g_inc_args array).
function f_include_args {
  local f_line
  while IFS= read -r f_line
  do
    [[ -n "$f_line" ]] && g_inc_args+=(--include "$f_line")
  done < "$1"
}

### Single file restore ###

if [[ "$g_scope" == "--file" ]]
then
  # Destination: explicit --target, original location (--to-original)
  # or a staging directory below the data root.
  g_dest="$g_target"
  if [[ -z "$g_dest" ]]
  then
    if [[ -n "$g_to_original" ]]
    then
      g_dest="/"
    else
      g_dest="${g_data_root}/restored-files/$(date +%Y%m%d-%H%M%S)"
    fi
  fi
  g_steps="restic restore $g_restic_sid --include $g_file --target $g_dest"
  if [[ "$g_action" == "plan" || -z "$g_yes" ]]
  then
    printf '{"ok":true,"action":"plan","date":"%s","scope":"--file","file":%s,"source":%s,"steps":[%s]}\n' \
      "$g_date" "$(printf '%s' "$g_file" | f_json_escape)" \
      "$(printf '%s' "$g_src_desc" | f_json_escape)" \
      "$(printf '%s' "$g_steps" | f_json_escape)"
    exit 0
  fi
  # The include pattern is the original absolute snapshot path; with
  # --target / the file returns to its exact original location, with a
  # staging target it lands below <target>/<original path>.
  if ! f_snap_index 2>/dev/null || ! grep -qx "$g_file" "${g_tmp}/snap-paths"
  then
    g_echo_warn "$g_file is not part of snapshot $g_date - restic will fail if it does not exist"
  fi
  mkdir -p "$g_dest"
  g_echo "Restoring file(s) $g_file from snapshot $g_restic_sid to $g_dest"
  if f_r_restic restore "$g_restic_sid" --include "$g_file" --target "$g_dest"
  then
    g_echo_ok "File restore completed to $g_dest"
  else
    g_echo_error "File restore failed - see the output above."
    exit 1
  fi
  exit 0
fi

### Service / full restore ###

if [[ "$g_scope" != "--full" ]]
then
  # --- Single service restore ---
  g_abs_dirs=()
  for g_d in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    g_abs_dirs+=("${g_data_root}/${g_d}")
  done
  f_stop_stacks "${g_abs_dirs[@]}"
  if ! f_restore_scope_dirs
  then
    f_start_stacks "${g_abs_dirs[@]}"
    exit 1
  fi
  f_start_stacks "${g_abs_dirs[@]}"
  sleep 5
  f_import_db_dumps
else
  # --- Full system restore ---
  f_snap_index
  f_write_restore_includes
  g_echo_warn "FULL SYSTEM RESTORE from $g_date starting in 10 seconds"
  sleep 10
  g_echo "Stopping Docker"
  systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
  sleep 3
  g_echo "Restoring ${g_data_root} from $g_date (${g_src_desc})"
  # --delete only in include mode (see header): removes files that
  # appeared below the data root after the snapshot; the negated includes
  # protect the local backup repository, docker internals and the
  # repository password file.
  g_inc_args=()
  f_include_args "${g_tmp}/restore-includes"
  if ! f_r_restic restore "$g_restic_sid" --target / --delete "${g_inc_args[@]}"
  then
    g_echo_error "Restic restore failed - the system may be in an inconsistent state!"
    g_echo "Starting Docker anyway"
  fi
  g_echo "Starting Docker"
  systemctl start containerd.service docker.socket docker.service 2>/dev/null || true
  # Wait until the docker daemon answers again
  for g_i in $(seq 1 60)
  do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  g_echo "Reapplying all SymbiOS playbooks (this can take a while)"
  "${g_git_root}/scripts/symbios-reapply.sh" || g_echo_error "Reapply had errors - check the logs"
fi

g_echo_ok "Restore from $g_date finished"
exit 0
