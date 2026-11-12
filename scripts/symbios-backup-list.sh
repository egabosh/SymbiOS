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
# symbios-backup-list.sh - List available backup snapshots as JSON for the
# WebUI (Settings -> Backup). Queries the local restic repository and, for
# every configured backup server, its remote restic repository.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

List available backup snapshots as JSON for the WebUI (Settings -> Backup).
Queries the local restic repository and, for every configured backup server,
its remote restic repository. No arguments.

Output JSON: {"ok":true,"mode":"local|remote-restic","targets":[...],
"snapshots":[...],"services":[...],"warning":...,"pubkey":...}
Every snapshot entry: {"date":"YYYY-MM-DD","local":0|1,
"servers":["<target name>", ...]} - restic repositories are always
encrypted, so there is no separate encrypted flag.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Pure query script printing JSON: skip the gaboshlib stdout/stderr FIFO
# redirection (g_all-to-syslog) so the output stays machine-parseable.
g_alltosyslog=1
source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

f_bk_read_vars

# Collect restorable service scopes: subdirectories of the services root
# and the base-services root (runtime/config dirs filtered out).
function f_list_services {
  local f_root
  for f_root in "$g_services_root" "$g_base_services_root"
  do
    [[ -d "$f_root" ]] || continue
    ls -1 "$f_root" 2>/dev/null | while read -r f_name
    do
      case "$f_name" in
        .*|_*|config|log|webui|tasks) continue ;;
      esac
      [[ -d "$f_root/$f_name" ]] && echo "$f_name"
    done
  done | sort -u
}

# JSON array from a newline list (input values must be [A-Za-z0-9_.-]).
function f_json_array {
  local f_first=1 f_item f_out="[" f_tmp
  f_tmp=$(mktemp)
  cat > "$f_tmp"
  while IFS= read -r f_item
  do
    [[ -z "$f_item" ]] && continue
    # Basic safety: strip anything unexpected before embedding into JSON
    f_item=$(echo "$f_item" | tr -cd 'A-Za-z0-9_.-')
    [[ -z "$f_item" ]] && continue
    [[ $f_first -eq 1 ]] && f_first=0 || f_out="$f_out,"
    f_out="$f_out\"$f_item\""
  done < "$f_tmp"
  rm -f "$f_tmp"
  echo "$f_out]"
}

### Main ###

g_all_dates="$(mktemp)"
g_warning=""
# One date file per restic target so the UI can show WHICH server holds a
# snapshot (parallel arrays, index-aligned).
g_target_files=()
g_target_names=()

# The local repository first (cheapest, no network round trip).
g_local_hint=""
if command -v restic >/dev/null 2>&1 && [[ -s "${g_bk_restic_pw_file:-}" ]] \
  && [[ -d "$g_bk_local_repo" ]]
then
  g_target_files+=("${g_tmp}/bk-local.dates")
  g_target_names+=("local")
  f_bk_restic_dates "$g_bk_local_repo" "" > "${g_target_files[0]}" || : > "${g_target_files[0]}"
  cat "${g_target_files[0]}" >> "$g_all_dates"
else
  # Remember why the local repository is not usable: in a local-only setup
  # an empty list would otherwise look like a lost backup.
  if ! command -v restic >/dev/null 2>&1
  then
    g_local_hint="restic is not installed"
  elif [[ ! -s "${g_bk_restic_pw_file:-}" ]]
  then
    g_local_hint="the restic repository password file is missing"
  else
    g_local_hint="no local restic repository exists yet at ${g_bk_local_repo}"
  fi
fi

# Remote targets: query every configured repository.
if f_bk_has_targets
then
  if command -v restic >/dev/null 2>&1 && [[ -s "${g_bk_restic_pw_file:-}" ]]
  then
    g_idx=${#g_target_files[@]}
    g_failed=""
    while IFS=$'\t' read -r f_t_name f_t_host f_t_port f_t_user f_t_path f_t_kd f_t_kw f_t_km
    do
      [[ -n "$f_t_host" ]] || continue
      g_target_files+=("${g_tmp}/bk-target-${g_idx}.dates")
      g_target_names+=("$f_t_name")
      # A restic query can fail (server down, key revoked) - the listing
      # stays useful with the remaining targets and names the broken one.
      if f_bk_restic_dates "$(f_bk_repo_url "$f_t_name|$f_t_host|$f_t_port|$f_t_user|$f_t_path|$f_t_kd|$f_t_kw|$f_t_km")" "$(f_bk_sshargs)" > "${g_target_files[$g_idx]}"
      then
        cat "${g_target_files[$g_idx]}" >> "$g_all_dates"
      else
        : > "${g_target_files[$g_idx]}"
        g_failed="${g_failed}${g_failed:+, }${f_t_name}"
      fi
      g_idx=$(( g_idx + 1 ))
    done < <(f_bk_targets_tsv)
    [[ -n "$g_failed" ]] && g_warning="Could not read the restic repository on: ${g_failed}."
  else
    g_warning="restic is not installed or the repository password is missing - cannot list remote snapshots."
  fi
fi

# Merge all dates (unique, newest first)
sort -u "$g_all_dates" | sort -ru > "${g_tmp}/all-dates"

# Local-only setups: explain an empty list instead of showing nothing.
if [[ -z "$g_warning" ]] && ! f_bk_has_targets && [[ -n "$g_local_hint" ]]
then
  g_warning="No snapshots to list: ${g_local_hint}."
fi

# Build the JSON snapshots array: per date which locations hold it.
# "servers" lists the names of the targets that have this snapshot, so with
# multiple backup servers the Location column stays unambiguous.
g_snap_json="["
g_first=1
while IFS= read -r g_date
do
  [[ "$g_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ $g_first -eq 1 ]] && g_first=0 || g_snap_json="$g_snap_json,"
  g_has_local=0
  g_srv_json=""
  for i in "${!g_target_names[@]}"
  do
    if [[ -s "${g_target_files[$i]}" ]] && grep -qx "$g_date" "${g_target_files[$i]}"
    then
      if [[ "${g_target_names[$i]}" == "local" ]]
      then
        g_has_local=1
      else
        g_srv_json="${g_srv_json:+, }$(printf '%s' "${g_target_names[$i]}" | f_json_escape)"
      fi
    fi
  done
  g_snap_json="$g_snap_json{\"date\":\"$g_date\",\"local\":$g_has_local,\"servers\":[$g_srv_json]}"
done < "${g_tmp}/all-dates"
g_snap_json="$g_snap_json]"

# Target mode description for the UI
if ! f_bk_has_targets
then
  g_mode="local"
else
  g_mode="remote-restic"
fi

# Public key the user needs to authorize on the backup server
g_pubkey=""
[[ -r "${g_bk_ssh_pubkey}" ]] && g_pubkey="$(cat "${g_bk_ssh_pubkey}")"

# Names of all configured restic targets (for the UI)
g_targets_json="["
g_first=1
while IFS=$'\t' read -r g_t_name _g_rest
do
  [[ -n "$g_t_name" ]] || continue
  [[ $g_first -eq 1 ]] && g_first=0 || g_targets_json="$g_targets_json,"
  # f_json_escape prints the value already quoted for JSON
  g_targets_json="$g_targets_json$(printf '%s' "$g_t_name" | f_json_escape)"
done < <(f_bk_targets_tsv)
g_targets_json="$g_targets_json]"

cat <<EOF
{"ok":true,"mode":"$g_mode","host":"$g_bk_host","path":"$g_bk_path",
"targets":$g_targets_json,
"snapshots":$g_snap_json,
"services":$(f_list_services | f_json_array),
"warning":$(printf '%s' "$g_warning" | f_json_escape),
"pubkey":$(printf '%s' "$g_pubkey" | f_json_escape)}
EOF
rm -f "$g_all_dates" ${g_target_files[@]+"${g_target_files[@]}"}
