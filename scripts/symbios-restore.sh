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
# symbios-restore.sh - Restore snapshots created by symbios-backup.sh.
#
# Usage:
#   symbios-restore.sh plan <YYYY-MM-DD> [<service>|--full]
#       Show (as JSON) what a restore would do - no changes are made.
#   symbios-restore.sh restore <YYYY-MM-DD> [<service>|--full] [--yes]
#       Perform the restore. Without --yes nothing is executed (safety).
#
# Service restore: stops the affected docker compose stack(s), restores
# their directories (services/<name> and/or base-services/<name>) from the
# snapshot, re-imports matching database dumps found in the snapshot and
# starts the stack(s) again.
#
# Full restore: stops Docker, restores the whole /symbios data root from
# the snapshot (protected excludes keep docker internals and the local
# backup store intact), restarts Docker and reapplies all playbooks.

# Load gaboshlib and the SymbIOS libs.
# The plan action prints JSON on stdout: skip the gaboshlib stdout/stderr FIFO
# redirection (g_all-to-syslog) so the output stays machine-parseable. The
# actual restore run keeps full logging (it streams into the WebUI job modal).
[[ "${1:-}" == "plan" ]] && g_alltosyslog=1
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

# Share the backup lockfile: never restore while a backup runs (or vice
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

# Read backup settings (remote target, encryption, snapshot paths).
f_bk_read_vars

# Print {"ok":false,...} and exit - used for every validation error.
function f_die_json {
  printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$1" | f_json_escape)"
  exit 1
}

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

### Argument handling ###

g_action="$1"; shift || true
g_date="$1"; shift || true
g_scope="--full"
g_yes=""
for g_arg in "$@"
do
  case "$g_arg" in
    --yes) g_yes="1" ;;
    *) g_scope="$g_arg" ;;
  esac
done

[[ "$g_action" == "plan" || "$g_action" == "restore" ]] \
  || f_die_json "Usage: symbios-restore.sh {plan|restore} <YYYY-MM-DD> [<service>|--full] [--yes]"
[[ "$g_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || f_die_json "Invalid date '$g_date' - expected YYYY-MM-DD."
[[ "$g_scope" == "--full" || "$g_scope" =~ ^[A-Za-z0-9._-]+$ ]] \
  || f_die_json "Invalid service name '$g_scope'."

# Resolve which physical source the snapshot comes from (local disk,
# remote rsync target or encrypted archive).
if ! f_bk_resolve_source "$g_date"
then
  f_die_json "No snapshot found for $g_date."
fi

# Human-readable source description for the plan output.
case "$g_bk_src_kind" in
  local-rsync)    g_src_desc="local snapshot (${g_data_root}/backup)" ;;
  remote-rsync)   g_src_desc="snapshot on ${g_bk_host}" ;;
  local-archive)  g_src_desc="local encrypted archive" ;;
  remote-archive) g_src_desc="encrypted archive on ${g_bk_host}" ;;
esac

### Source access helpers ###

# Print the path/URL under which <relpath> (below the snapshot's symbios/)
# can be read.
function f_snap_path {
  local f_rel="$1"
  case "$g_bk_src_kind" in
    local-rsync)  echo "${g_bk_snap_base}/backup-${g_date}/symbios/${f_rel}" ;;
    remote-rsync) echo "${g_bk_user}@${g_bk_host}:${g_bk_path}/$(hostname)/backup-${g_date}/symbios/${f_rel}" ;;
    *)            echo "${g_tmp}/archive-root/symbios/${f_rel}" ;;
  esac
}

# Print the remote shell path of a relative snapshot path (for ssh cmds).
function f_snap_remote_path {
  echo "${g_bk_path}/$(hostname)/backup-${g_date}/symbios/$1"
}

# True if the given relative directory exists in the snapshot source.
function f_snap_has_dir {
  local f_rel="$1"
  case "$g_bk_src_kind" in
    local-rsync|*-archive)
      [[ -d "$(f_snap_path "$f_rel")" ]] && return 0 ;;
    remote-rsync)
      f_bk_rsh "test -d '$(f_snap_remote_path "$f_rel")'" >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

# List the *.sql.gz dump basenames available in the snapshot's backups dir.
function f_list_snap_dumps {
  case "$g_bk_src_kind" in
    local-rsync|*-archive)
      ls -1 "$(f_snap_path "backups")"/*.sql.gz 2>/dev/null | xargs -n1 basename 2>/dev/null ;;
    remote-rsync)
      f_bk_rsh "ls -1 '$(f_snap_remote_path "backups")'/*.sql.gz 2>/dev/null" 2>/dev/null \
        | sed 's#.*/##' ;;
  esac
}

# Stream one dump (by basename) from the snapshot, already decompressed,
# so it can be piped into a database container.
function f_cat_dump {
  local f_name="$1"
  local f_full="$(f_snap_path "backups")/${f_name}"
  case "$g_bk_src_kind" in
    local-rsync|*-archive)
      zcat "$f_full" ;;
    remote-rsync)
      f_bk_rsh "cat '$(f_snap_remote_path "backups")/${f_name}'" 2>/dev/null | zcat ;;
  esac
}

# For archive sources: extract the needed members once into a staging dir.
function f_extract_archive_members {
  local f_members=()
  [[ "$g_bk_src_kind" == *-archive && "$g_scope" != "--full" ]] || return 0
  mkdir -p "${g_tmp}/archive-root"
  local f_d
  for f_d in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    f_members+=("symbios/${f_d}")
  done
  f_members+=("symbios/backups")
  g_echo "Reading encrypted archive (${g_src_desc}) ..."
  case "$g_bk_src_kind" in
    local-archive)
      openssl enc -d "-$g_bk_cipher" -pbkdf2 -iter "$g_bk_kdf_iter" \
          -pass file:"$g_bk_pw_file" \
        -in "${g_bk_snap_base}/$(f_bk_archive_name "$g_date")" \
        | tar -xzf - -C "${g_tmp}/archive-root" --wildcards "${f_members[@]}" ;;
    remote-archive)
      f_bk_rsh "cat '${g_bk_path}/$(hostname)/$(f_bk_archive_name "$g_date")'" \
        | openssl enc -d "-$g_bk_cipher" -pbkdf2 -iter "$g_bk_kdf_iter" \
            -pass file:"$g_bk_pw_file" \
        | tar -xzf - -C "${g_tmp}/archive-root" --wildcards "${f_members[@]}" ;;
  esac
}

### Scope resolution ###

# Directory pairs to restore for a single service (relative below /symbios).
g_rel_dirs=()

function f_collect_scope_dirs {
  local f_cand
  if [[ "$g_scope" == "--full" ]]
  then
    return 0
  fi
  for f_cand in "services/$g_scope" "base-services/$g_scope"
  do
    # Include a directory if it exists in the snapshot OR on this system
    if f_snap_has_dir "$f_cand" || [[ -e "${g_data_root}/${f_cand}" ]]
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
    [[ "$g_bk_src_kind" == *-archive ]] && \
      echo "Archive restore cannot delete files created after $g_date; newer files stay in place." >> "$g_warns_file"
    return 0
  fi

  for f_dir in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    if ! f_snap_has_dir "$f_dir"
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

### Output plan (also for restore without --yes) ###

if [[ "$g_action" == "plan" || -z "$g_yes" ]]
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

# Copy one directory tree from the snapshot back onto the live system.
function f_restore_dir {
  local f_rel="$1"
  local f_src f_dst="${g_data_root}/${f_rel}"
  mkdir -p "$f_dst"
  case "$g_bk_src_kind" in
    local-rsync)
      rsync -aXAH --delete --exclude-from="${g_tmp}/restore-excludes" \
        "$(f_snap_path "$f_rel")/" "$f_dst/" ;;
    remote-rsync)
      rsync -aXAH --delete --exclude-from="${g_tmp}/restore-excludes" \
        -e "ssh $(f_bk_ssh_opts)" "$(f_snap_path "$f_rel")/" "$f_dst/" ;;
    local-archive|remote-archive)
      rsync -aXAH "$(f_snap_path "$f_rel")/" "$f_dst/" ;;
  esac
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

# Write the rsync exclude file used by f_restore_dir. Full restores reuse the
# backup exclude list (keeps docker internals and the snapshot store intact);
# service restores start with an empty list (the service dir is restored as-is).
function f_write_restore_excludes {
  if [[ "$g_scope" == "--full" ]]
  then
    f_bk_write_excludes > "${g_tmp}/restore-excludes"
  else
    : > "${g_tmp}/restore-excludes"
  fi
}

if [[ "$g_scope" != "--full" ]]
then
  # --- Single service restore ---
  g_abs_dirs=()
  for g_d in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    g_abs_dirs+=("${g_data_root}/${g_d}")
  done
  # Archives need their contents staged before anything is touched
  f_extract_archive_members
  f_write_restore_excludes
  f_stop_stacks "${g_abs_dirs[@]}"
  for g_d in ${g_rel_dirs[@]+"${g_rel_dirs[@]}"}
  do
    if f_snap_has_dir "$g_d"
    then
      g_echo "Restoring ${g_data_root}/${g_d}"
      f_restore_dir "$g_d" || g_echo_error "Restore of ${g_d} failed"
    fi
  done
  f_start_stacks "${g_abs_dirs[@]}"
  sleep 5
  f_import_db_dumps
  rm -rf "${g_tmp}/archive-root"
else
  # --- Full system restore ---
  f_write_restore_excludes
  g_echo_warn "FULL SYSTEM RESTORE from $g_date starting in 10 seconds"
  sleep 10
  g_echo "Stopping Docker"
  systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
  sleep 3
  if [[ "$g_bk_src_kind" == *-archive ]]
  then
    # Archives are extracted directly onto the live filesystem
    g_echo "Extracting full snapshot archive (${g_src_desc})"
    case "$g_bk_src_kind" in
      local-archive)
        openssl enc -d "-$g_bk_cipher" -pbkdf2 -iter "$g_bk_kdf_iter" \
            -pass file:"$g_bk_pw_file" \
          -in "${g_bk_snap_base}/$(f_bk_archive_name "$g_date")" \
          | tar -xzf - -C "/" ;;
      remote-archive)
        f_bk_rsh "cat '${g_bk_path}/$(hostname)/$(f_bk_archive_name "$g_date")'" \
          | openssl enc -d "-$g_bk_cipher" -pbkdf2 -iter "$g_bk_kdf_iter" \
              -pass file:"$g_bk_pw_file" \
          | tar -xzf - -C "/" ;;
    esac
  else
    g_echo "Restoring ${g_data_root} from snapshot"
    f_restore_dir ""
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
