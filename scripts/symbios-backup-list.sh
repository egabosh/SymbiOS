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
# symbios-backup-list.sh - List available backup snapshots as JSON for the
# WebUI (Settings -> Backup). Merges local snapshot dates and - if a backup
# server is configured - restic snapshots.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

List available backup snapshots as JSON for the WebUI (Settings -> Backup).
Merges local snapshot dates and, if a backup server is configured, remote
dates / encrypted archive dates. No arguments.

Output JSON: {"ok":true,"mode":"local|remote|remote-encrypted","host":...,
"path":...,"snapshots":[...],"services":[...],"warning":...,"pubkey":...}

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

g_local_dates="$(mktemp)"
g_remote_dates="$(mktemp)"
g_arch_dates="$(mktemp)"
g_warning=""

# Local snapshots (rsync mode)
f_bk_list_local_dates > "$g_local_dates"

# Remote snapshots - restic first (query every configured target),
# fallback to the legacy rsync directory listing.
if f_bk_has_targets
then
  if command -v restic >/dev/null 2>&1 && [[ -n "${g_bk_restic_pw_file:-}" ]] && [[ -s "${g_bk_restic_pw_file}" ]]; then
    export RESTIC_PASSWORD_FILE="${g_bk_restic_pw_file}"
    while IFS=$'\t' read -r f_t_name f_t_host f_t_port f_t_user f_t_path f_t_kd f_t_kw f_t_km
    do
      [[ -n "$f_t_host" ]] || continue
      RESTIC_REPOSITORY="sftp://${f_t_user}@${f_t_host}:${f_t_port}//${f_t_path#/}/$(hostname)"
      f_sshargs="-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
      [[ -r "$g_bk_ssh_key" ]] && f_sshargs="-i $g_bk_ssh_key $f_sshargs"
      restic snapshots --json -o "sftp.args=${f_sshargs}" 2>/dev/null | python3 -c "
import sys,json
try:
  data=json.load(sys.stdin)
  for s in data:
    t=s.get('time','')
    if len(t)>=10:
      print(t[:10])
except Exception:
  pass
" >> "$g_remote_dates" || true
    done < <(f_bk_targets_tsv)
    sort -ru -o "$g_remote_dates" "$g_remote_dates"
  fi
  if [[ ! -s "$g_remote_dates" ]]; then
    if ! f_bk_rsh "ls -1 '${g_bk_path}/$(hostname)/' 2>/dev/null" > "${g_tmp}/remote-ls" 2>/dev/null
    then
      g_warning="Could not reach backup server ${g_bk_host} - showing local backups only."
      : > "${g_tmp}/remote-ls"
    fi
    grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}$' "${g_tmp}/remote-ls" \
      | sed 's/^backup-//' | sort -ru > "$g_remote_dates" || true
    f_bk_dates_from_archive_names < "${g_tmp}/remote-ls" > "$g_arch_dates" || true
  fi
fi

# Merge all dates (unique, newest first)
sort -u "$g_local_dates" "$g_remote_dates" "$g_arch_dates" | sort -ru > "${g_tmp}/all-dates"

# Build the JSON snapshots array
g_snap_json="["
g_first=1
while IFS= read -r g_date
do
  [[ "$g_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ $g_first -eq 1 ]] && g_first=0 || g_snap_json="$g_snap_json,"
  g_has_local=0
  g_has_remote=0
  g_encrypted=0
  grep -qx "$g_date" "$g_local_dates" && g_has_local=1
  grep -qx "$g_date" "$g_remote_dates" && g_has_remote=1
  if grep -qx "$g_date" "$g_arch_dates"
  then
    g_has_remote=1
    g_encrypted=1
  fi
  g_snap_json="$g_snap_json{\"date\":\"$g_date\",\"local\":$g_has_local,\"remote\":$g_has_remote,\"encrypted\":$g_encrypted}"
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
rm -f "$g_local_dates" "$g_remote_dates" "$g_arch_dates"
