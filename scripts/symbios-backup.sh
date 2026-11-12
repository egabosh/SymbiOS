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
# symbios-backup.sh - SymbiOS main backup engine (restic only).
#
# Backs up the whole data root (/symbios - configuration, services, docker
# volumes and the pre-run database dumps from backup.d/) plus /root/.ssh:
#
#   - Restic target(s) configured : restic snapshot over SFTP to every
#                                   configured server (repository below
#                                   PATH/$(hostname)/), each with its own
#                                   retention policy
#   - No target configured        : restic snapshot into the local
#                                   repository ${data_root}/backup/restic
#
# Every repository is encrypted with the restic password file - there is no
# unencrypted mode. Called by scripts/backup.sh (cron
# /etc/cron.d/backup_local, nightly 00:05). The run status (including the
# captured restic errors) is written to ${g_log_dir}/backup-status.json for
# the WebUI and the backup healthcheck.

function f_usage {
  echo "Usage: $(basename "$0") [command]"
  echo ""
  echo "SymbiOS main backup engine (restic only). Backs up the whole data"
  echo "root (/symbios - configuration, services, docker volumes and the"
  echo "pre-run database dumps from backup.d/) plus /root/.ssh:"
  echo "  - Restic target(s) configured : restic snapshot over SFTP"
  echo "                                   (repository in PATH/$(hostname)/)"
  echo "  - No target configured        : local restic repository in"
  echo "                                   ${g_data_root:-<data_root>}/backup/restic"
  echo ""
  echo "Every repository is encrypted with the restic password file - there"
  echo "is no unencrypted mode."
  echo ""
  echo "Called by scripts/backup.sh (cron /etc/cron.d/backup_local, nightly"
  echo "00:05). The run status including the captured restic errors is"
  echo "written to <log>/backup-status.json for the WebUI."
  echo ""
  echo "Commands:"
  echo "  get-restic-password  Print the restic repository password as JSON"
  echo "  gen-restic-password   Ensure the restic password file exists under"
  echo "                        /symbios (never overwrites an existing one)"
  echo "                        and print it as JSON"
  echo "  help                  Show this help"
  echo ""
  echo "Options:"
  echo "  -h, --help            Show this help and exit"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]
then
  f_usage
  exit 0
fi

# Query subcommands print JSON on stdout: skip the gaboshlib stdout/stderr
# FIFO redirection (g_all-to-syslog) so the output stays machine-parseable.
[[ "${1:-}" == "get-restic-password" || "${1:-}" == "gen-restic-password" ]] && g_alltosyslog=1
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-backup-lib.sh"

# Read all backup settings from inventory.yml.
f_bk_read_vars

# Make sure the restic password file exists; generate one on first use so the
# nightly cron never fails just because nobody opened the WebUI page.
# (backup.yml creates it too - this covers manual first runs on hosts where
# the playbook has not run yet.)
function f_ensure_restic_password {
  local f_pwfile="${g_bk_restic_pw_file:-${g_config_dir}/.backup_restic_password}"
  if [[ ! -d "$(dirname "$f_pwfile")" ]]
  then
    mkdir -p "$(dirname "$f_pwfile")"
    chmod 750 "$(dirname "$f_pwfile")" 2>/dev/null
  fi
  if [[ -s "$f_pwfile" ]]
  then
    return 0
  fi
  local f_pw
  f_pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
  umask 077
  printf '%s' "$f_pw" > "$f_pwfile"
  umask 022
  chown root:root "$f_pwfile" 2>/dev/null
  chmod 600 "$f_pwfile"
  g_echo_warn "Generated a new restic repository password (${f_pwfile})."
  g_echo_warn "View/store it via WebUI -> Settings -> Backup ('Show password')!"
}

# Query subcommands used by the WebUI - no lock, never start a backup.
# The password itself is only printed as JSON on stdout (it never appears
# in argv; the file stays root-only on the host).
case "$1" in
  get-restic-password)
    f_ensure_restic_password
    printf '{"ok":true,"generated":false,"password":%s}\n' \
      "$(cat "$g_bk_restic_pw_file" 2>/dev/null | f_json_escape)"
    exit 0 ;;
  gen-restic-password)
    if [[ -s "$g_bk_restic_pw_file" ]]
    then
      f_generated=false
    else
      f_ensure_restic_password
      f_generated=true
    fi
    printf '{"ok":true,"generated":%s,"password":%s}\n' \
      "$f_generated" "$(cat "$g_bk_restic_pw_file" 2>/dev/null | f_json_escape)"
    exit 0 ;;
esac

g_lockfile
g_nice
g_all-to-syslog
set -o pipefail

# Write the run status for the WebUI/healthcheck.
# Usage: f_write_status <state> <target> <snapshot-date> <message> [extra-json]
# "errors" in <extra-json> carries the captured restic error lines (one per
# target) so the WebUI can show the specific failure instead of "See syslog".
function f_write_status {
  local f_state="$1" f_target="$2" f_snap="$3" f_msg="$4" f_extra="$5"
  local f_now
  f_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    printf '{"state":"%s","finished":"%s","target":"%s","snapshot":"%s","message":%s' \
      "$f_state" "$f_now" "$f_target" "$f_snap" "$(printf '%s' "$f_msg" | f_json_escape)"
    if [[ -n "$f_extra" ]]
    then
      printf ',%s' "$f_extra"
    fi
    printf '}'
  } > "${g_log_dir}/backup-status.json.tmp"
  mv "${g_log_dir}/backup-status.json.tmp" "${g_log_dir}/backup-status.json"
  # Success marker consumed by the healthcheck (epoch seconds).
  if [[ "$f_state" == "ok" ]]
  then
    date +%s > "${g_log_dir}/backup-last-success"
  fi
}

# Append the currently captured restic errors of one target to the run-wide
# error list (TSV file: target name \t error line). Reset by the caller
# before each target run.
# Usage: f_collect_errors <target-name>
function f_collect_errors {
  local f_target="$1" f_line
  while IFS= read -r f_line
  do
    printf '%s\t%s\n' "$f_target" "$f_line" >> "${g_tmp}/run-errors"
  done < <(f_bk_err_tail)
}

# The run-wide error list as an object member for the status extra:
# "errors":["target: error line", ...]
# The key is part of the fragment (like f_bk_stats_json) - f_write_status
# joins extras with a comma, a bare array would produce invalid JSON and the
# WebUI would fall back to "No backup has yet run".
function f_errors_json {
  local f_target f_line
  local f_arr=()
  if [[ ! -r "${g_tmp}/run-errors" ]]
  then
    printf '"errors":[]'
    return 0
  fi
  while IFS=$'\t' read -r f_target f_line
  do
    f_arr+=("${f_target}: ${f_line}")
  done < "${g_tmp}/run-errors"
  printf '"errors":%s' "$(f_bk_lines_json ${f_arr[@]+"${f_arr[@]}"})"
}

# Snapshot one restic target (remote TSV line or "local" for the local
# repository) and apply its retention policy. Sources are the data root and
# /root/.ssh (which holds the key for the next push).
# Usage: f_run_restic_backup <tsv-line|local>
function f_run_restic_backup {
  local f_tsv="$1"
  local f_repo f_ssh f_name f_kd f_kw f_km
  if [[ "$f_tsv" == "local" ]]
  then
    f_repo="$g_bk_local_repo"
    f_ssh=""
    f_name="local"
    f_kd="$g_bk_rkeep_daily"
    f_kw="$g_bk_rkeep_weekly"
    f_km="$g_bk_rkeep_monthly"
    # The retention globals may hold anything from the inventory - the
    # forget call below needs plain non-negative integers.
    [[ "$f_kd" =~ ^[0-9]+$ ]] || f_kd=7
    [[ "$f_kw" =~ ^[0-9]+$ ]] || f_kw=4
    [[ "$f_km" =~ ^[0-9]+$ ]] || f_km=9999
    mkdir -p "$(dirname "$f_repo")"
  else
    local f_host f_port f_user f_path
    IFS='|' read -r f_name f_host f_port f_user f_path f_kd f_kw f_km <<< "$f_tsv"
    f_repo="$(f_bk_repo_url "$f_tsv")"
    f_ssh="$(f_bk_sshargs)"
  fi

  # Repository must exist and open with the configured password.
  if ! f_bk_restic_ensure_repo "$f_repo" "$f_ssh"
  then
    f_collect_errors "$f_name"
    return 1
  fi

  # Snapshot: data root plus the host's root SSH dir (which holds the key
  # for the next push). --one-file-system keeps a stray mount below /symbios
  # out of the snapshot.
  local f_srcs=("$g_data_root")
  [[ -d /root/.ssh ]] && f_srcs+=(/root/.ssh)
  f_bk_write_excludes "${g_tmp}/restic-excludes"
  g_echo "Creating restic snapshot in $f_repo"
  if ! f_bk_restic "$f_repo" "$f_ssh" backup \
      "${f_srcs[@]}" --one-file-system --exclude-file "${g_tmp}/restic-excludes"
  then
    g_echo_error "Restic snapshot on $f_name failed"
    f_collect_errors "$f_name"
    return 1
  fi

  # Retention: forget + prune bound the repository size on every run.
  local f_forget=()
  [[ "$f_kd" -gt 0 ]] && f_forget+=(--keep-daily "$f_kd")
  [[ "$f_kw" -gt 0 ]] && f_forget+=(--keep-weekly "$f_kw")
  [[ "$f_km" -gt 0 ]] && f_forget+=(--keep-monthly "$f_km")
  g_echo "Applying retention on $f_name (keep-daily $f_kd, keep-weekly $f_kw, keep-monthly $f_km)"
  if ! f_bk_restic "$f_repo" "$f_ssh" forget --prune "${f_forget[@]}"
  then
    g_echo_error "Restic retention (forget --prune) on $f_name failed"
    f_collect_errors "$f_name"
    return 1
  fi
  return 0
}

### Main ###

# Target label used by the interrupt handler below.
g_bk_cur_target="local"

# gaboshlib's g_echo_error_exit raises SIGHUP on fatal errors. The default
# SIGHUP action kills the script instantly - no EXIT trap, status JSON would
# stay "running" forever and locks/tmp dirs leak. Intercept it instead.
function f_bk_on_hup {
  f_write_status "error" "$g_bk_cur_target" "" "Backup was interrupted - see syslog." \
    "$(f_errors_json)"
  exit 1
}
trap f_bk_on_hup HUP

# Collect all configured restic targets (TSV lines name|host|port|user|path|kd|kw|km).
g_bk_targets=()
while IFS=$'\t' read -r g_t_name g_t_host g_t_port g_t_user g_t_path g_t_kd g_t_kw g_t_km
do
  [[ -n "$g_t_host" ]] || continue
  g_bk_targets+=("$g_t_name|$g_t_host|$g_t_port|$g_t_user|$g_t_path|$g_t_kd|$g_t_kw|$g_t_km")
done < <(f_bk_targets_tsv)

g_echo_note "Starting $0 (host=$(hostname), targets=${#g_bk_targets[@]} restic target(s))"
: > "${g_tmp}/run-errors"
g_snapshot_date=""

# Free-space guard: never let a run fill the disk (would break services).
# Retention bounds the repository size on every run - reaching the limits
# anyway means something is wrong, so abort before the disk fills up.
if ! f_bk_guard_free_space
then
  g_bk_cur_target="$(f_bk_has_targets && echo "remote-restic" || echo "local")"
  f_write_status "error" "$g_bk_cur_target" "" "Disk below ${g_bk_min_free_gb}GB/${g_bk_min_free_percent}% free - aborting before the disk fills up."
  exit 1
fi

# Key pre-flight: an unusable backup key must abort loudly here, not surface
# as a "Permission denied" on the remote server an hour into the snapshot.
if ! f_bk_check_ssh_key
then
  g_bk_cur_target="$(f_bk_has_targets && echo "remote-restic" || echo "local")"
  f_write_status "error" "$g_bk_cur_target" "" "Backup key ${g_bk_ssh_key} is missing or unusable - see syslog." \
    "$(f_errors_json)"
  exit 1
fi

# The restic password must exist before the first repository is touched.
f_ensure_restic_password

if [[ ${#g_bk_targets[@]} -gt 0 ]]
then
  # One restic run per configured target; a failure on one server must not
  # stop the others (partial success is better than nothing).
  g_bk_cur_target="remote-restic"
  f_write_status "running" "remote-restic" "" ""
  g_ok_targets=""
  g_failed_targets=""
  for g_t in "${g_bk_targets[@]}"
  do
    IFS='|' read -r g_t_name _ <<< "$g_t"
    g_echo_note "Backing up to ${g_t_name}"
    if f_run_restic_backup "$g_t"
    then
      g_ok_targets="${g_ok_targets}${g_ok_targets:+, }${g_t_name}"
    else
      g_failed_targets="${g_failed_targets}${g_failed_targets:+, }${g_t_name}"
    fi
  done
  if [[ -z "$g_failed_targets" ]]
  then
    g_snapshot_date=$(date +%F)
    f_write_status "ok" "remote-restic" "$g_snapshot_date" "Restic snapshots created on: ${g_ok_targets}."
    g_echo_ok "Backup finished (restic, all targets)"
  else
    f_write_status "error" "remote-restic" "" "Restic snapshot failed on: ${g_failed_targets}. Succeeded on: ${g_ok_targets:-none}." \
      "$(f_errors_json)"
    g_echo_error "Backup failed on: ${g_failed_targets}"
    exit 1
  fi
else
  # No remote target: snapshot into the local repository.
  g_bk_cur_target="local"
  f_write_status "running" "local" "" ""
  if f_run_restic_backup "local"
  then
    g_snapshot_date=$(date +%F)
    f_write_status "ok" "local" "$g_snapshot_date" "Local restic snapshot created in ${g_bk_local_repo}." \
      "$(f_bk_stats_json),$(f_errors_json)"
    g_echo_ok "Backup finished (local restic repository)"
  else
    f_write_status "error" "local" "" "Local restic snapshot failed." \
      "$(f_errors_json)"
    g_echo_error "Backup failed (local restic repository)"
    exit 1
  fi
fi

exit 0
