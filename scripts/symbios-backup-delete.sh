#!/bin/bash
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# Free Software Foundation, either version 3 of the License, or
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
# symbios-backup-delete.sh - Delete restic snapshots from every repository.
#
# The WebUI lists one row per date, so a date delete removes all snapshots of
# that day in the local repository and in every configured remote repository.
# "all" removes every snapshot in every repository. Without --yes the command
# only prints the plan as JSON and changes nothing.
#
# Deletion is irreversible: restic forget --prune removes the snapshots and
# reclaims the space they held. The nightly retention policy never brings them
# back, only a new backup creates a new restore point.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <delete <YYYY-MM-DD>|all> [--yes]

Delete restic snapshots from the local repository and all configured remote
repositories. A date deletes every snapshot of that day in every repository;
"all" deletes every snapshot. Without --yes only a JSON plan is printed.

Commands:
  delete <YYYY-MM-DD>   Select all snapshots of one day (all repositories)
  all                   Select every snapshot (all repositories)

Options:
  --yes                 Execute the deletion (required; without it: dry run)
  -h, --help            Show this help and exit

Output:
  Dry run: {"ok":true,"mode":"date|all","dry_run":true,"total":N,
            "targets":[{"target":"<name>","count":N,"snapshots":["<id>",...]},
                       {"target":"<name>","error":"..."}]}
  Execute: human-readable progress in the WebUI job log.

Exit codes: 0 = ok (or nothing to delete), 1 = error (a target failed),
2 = unknown command or usage error.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]
then
  f_usage
  exit 0
fi

# Validate the whole command line before sourcing the libraries: a typo must
# never fall through into a destructive default action.
g_cmd="${1:-}"
case "$g_cmd" in
  delete|all) ;;
  *)
    echo "Unknown command: ${g_cmd:-<none>}" >&2
    f_usage >&2
    exit 2 ;;
esac
shift

g_date=""
g_yes=""
while [[ $# -gt 0 ]]
do
  case "$1" in
    --yes) g_yes="1" ;;
    --*) echo "Unknown option: $1" >&2; f_usage >&2; exit 2 ;;
    *)
      if [[ "$g_cmd" == "delete" && -z "$g_date" ]]
      then
        g_date="$1"
      else
        echo "Unexpected argument: $1" >&2
        f_usage >&2
        exit 2
      fi ;;
  esac
  shift
done
if [[ "$g_cmd" == "delete" ]]
then
  if [[ ! "$g_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  then
    echo "Invalid date: ${g_date:-<none>} (expected YYYY-MM-DD)" >&2
    exit 2
  fi
fi

# Query output must stay machine-parseable in dry-run mode (the same pattern
# the listing and restore scripts use for their JSON answers).
[[ -z "$g_yes" ]] && g_alltosyslog=1
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

# Real deletions must not race the shared maintenance window (backup + updates).
# fd 7 is used because gaboshlib keeps original stderr on 9 and its redirect
# pipe on 8. Dry runs are read-only and do not need this lock.
if [[ -n "$g_yes" ]]
then
  exec 7>/run/symbios-maintenance.lock
  if ! flock -x -n 7
  then
    g_echo_error "A SymbiOS maintenance run is active - exiting."
    exit 1
  fi
fi

# Share both backup locks with the engine and the restore script: never forget
# snapshots while a backup or restore is running.
g_scriptname="backup"
g_lockfile
g_lockfile=""
g_scriptname="symbios-backup"
g_lockfile
g_nice
[[ -z "$g_yes" ]] || g_all-to-syslog
set -o pipefail

f_bk_read_vars

# Collect every repository that can hold snapshots: the local one first, then
# all configured remote targets. Entries are "label|repo|sshargs".
function f_collect_targets {
  g_delete_targets=()
  if ! command -v restic >/dev/null 2>&1 || [[ ! -s "$g_bk_restic_pw_file" ]]
  then
    return 0
  fi
  [[ ! -d "$g_bk_local_repo" ]] || g_delete_targets+=("local|$g_bk_local_repo|")
  local f_name f_host f_port f_user f_path f_kd f_kw f_km f_line
  while IFS=$'\t' read -r f_name f_host f_port f_user f_path f_kd f_kw f_km
  do
    [[ -n "$f_host" ]] || continue
    f_line="${f_name}|${f_host}|${f_port}|${f_user}|${f_path}|${f_kd}|${f_kw}|${f_km}"
    g_delete_targets+=("${f_name}|$(f_bk_repo_url "$f_line")|$(f_bk_sshargs)")
  done < <(f_bk_targets_tsv)
}

# Print all matching snapshot ids of one repository, one per line. An empty
# date selects every snapshot. Unparsable restic output is treated as empty.
# Usage: f_snapshot_ids <repo> <sshargs|''> [<YYYY-MM-DD>]
function f_snapshot_ids {
  local f_repo="$1" f_ssh="$2" f_date="${3:-}" f_json
  f_json="$(f_bk_restic "$f_repo" "$f_ssh" snapshots --json 2>/dev/null)" || return 1
  printf '%s\n' "$f_json" | jq -r --arg d "$f_date" '
    .[]? | select($d == "" or (.time // "")[0:10] == $d)
    | (.short_id // .id) // empty
  ' 2>/dev/null | grep -E '^[a-fA-F0-9]{8,64}$' || true
}

# Print the JSON dry-run plan. Every target reports either its snapshot ids or
# an error, so an unreachable repository cannot look like "nothing selected".
function f_print_plan {
  local f_entry f_label f_repo f_ssh f_ids f_sids_json f_first=1 f_count
  local f_plan=""
  g_total=0
  for f_entry in ${g_delete_targets[@]+"${g_delete_targets[@]}"}
  do
    IFS='|' read -r f_label f_repo f_ssh <<< "$f_entry"
    [[ $f_first -eq 1 ]] && f_first=0 || f_plan="$f_plan,"
    if f_ids="$(f_snapshot_ids "$f_repo" "$f_ssh" "$g_date")"
    then
      local f_arr=()
      while IFS= read -r f_id
      do
        [[ -n "$f_id" ]] && f_arr+=("$f_id")
      done <<< "$f_ids"
      f_count=${#f_arr[@]}
      g_total=$(( g_total + f_count ))
      f_sids_json="$(f_bk_lines_json ${f_arr[@]+"${f_arr[@]}"})"
      f_plan="$f_plan{\"target\":$(printf '%s' "$f_label" | f_json_escape),\"count\":$f_count,\"snapshots\":$f_sids_json}"
    else
      f_plan="$f_plan{\"target\":$(printf '%s' "$f_label" | f_json_escape),\"error\":$(printf '%s' "$(f_bk_err_tail | tail -n 1)" | f_json_escape)}"
    fi
  done
  printf '{"ok":true,"mode":"%s","dry_run":true,"total":%s,"targets":[%s]}\n' \
    "$([[ "$g_cmd" == "all" ]] && echo all || echo date)" "$g_total" "$f_plan"
}

# Delete the selected snapshots on each target. A failed repository must not
# stop the others, but the exit code reports the partial failure.
function f_delete_snapshots {
  local f_entry f_label f_repo f_ssh f_ids f_id f_arr=() f_failed=""
  for f_entry in ${g_delete_targets[@]+"${g_delete_targets[@]}"}
  do
    IFS='|' read -r f_label f_repo f_ssh <<< "$f_entry"
    : > "$g_bk_err_file"
    if ! f_ids="$(f_snapshot_ids "$f_repo" "$f_ssh" "$g_date")"
    then
      g_echo_error "Cannot list snapshots on $f_label - $(f_bk_err_tail | tail -n 1)"
      f_failed="${f_failed}${f_failed:+, }$f_label"
      continue
    fi
    f_arr=()
    while IFS= read -r f_id
    do
      [[ -n "$f_id" ]] && f_arr+=("$f_id")
    done <<< "$f_ids"
    if [[ ${#f_arr[@]} -eq 0 ]]
    then
      g_echo_note "No snapshots to delete on $f_label"
      continue
    fi
    g_echo "Deleting ${#f_arr[@]} snapshot(s) on $f_label: ${f_arr[*]}"
    if f_bk_restic_retry "$f_repo" "$f_ssh" forget --prune "${f_arr[@]}"
    then
      g_echo_ok "Deleted ${#f_arr[@]} snapshot(s) on $f_label"
    else
      g_echo_error "Snapshots on $f_label could not be deleted"
      f_failed="${f_failed}${f_failed:+, }$f_label"
    fi
  done
  if [[ -n "$f_failed" ]]
  then
    g_echo_error "Deletion failed on: $f_failed"
    return 1
  fi
  g_echo_ok "Snapshot deletion finished on all targets"
  return 0
}

### Main ###

f_collect_targets

# Dry-run only: f_print_plan counts the selected snapshots while building the
# plan, so no repository is queried twice.
if [[ -z "$g_yes" ]]
then
  f_print_plan
  exit 0
fi

f_delete_snapshots
exit $?
