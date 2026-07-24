#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

# symbios-reapply.sh — Re-run installed playbooks.
#
# Reads the state file managed by symbios-state.sh and re-executes every
# registered playbook. Designed to run in the background (nohup) so the
# WebUI doesn't block.
#
# Usage:
#   symbios-reapply.sh                         # full reapply
#   symbios-reapply.sh --only <pb1> <pb2> ...  # re-run only specific playbooks (must be installed)

source /etc/bash/gaboshlib.include

g_state_file="/home/docker/symbios-ui/config/installed-playbooks.yml"
g_inventory="/home/docker/symbios-ui/config/inventory.yml"
g_repo="/home/SymbiOS"
g_log_dir="/home/docker/symbios-ui/log"
g_log_file="${g_log_dir}/reapply.log"
g_status_file="/tmp/symbios-reapply.status"
g_pid_file="/tmp/symbios-reapply.pid"
g_only_playbooks=""

# Parse arguments
if [[ "${1:-}" == "--only" ]]
then
  shift
  g_only_playbooks="$*"
fi

function f_cleanup {
  rm -f "$g_pid_file"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") REAPPLY DONE (exit code: ${g_exit_code:-1})" >> "$g_log_file"
  echo "done:${g_exit_code:-1}" > "$g_status_file"
}

function f_log {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >> "$g_log_file"
}

# Prevent concurrent runs
if [[ -f "$g_pid_file" ]]
then
  g_old_pid=$(cat "$g_pid_file")
  if kill -0 "$g_old_pid" 2>/dev/null
  then
    g_echo_warn "REAPPLY already running (PID $g_old_pid). Exiting."
    exit 0
  fi
  # Stale PID file
  rm -f "$g_pid_file"
fi

echo $$ > "$g_pid_file"
trap f_cleanup EXIT

# Ensure directories exist
mkdir -p "$g_log_dir"
mkdir -p "$(dirname "$g_state_file")"

# Initialise state file if missing
if [[ ! -f "$g_state_file" ]]
then
  printf '%s\n' "# Auto-maintained by playbooks via symbios-state.sh" > "$g_state_file"
fi

# Initialise log
g_exit_code=0
echo "" >> "$g_log_file"
f_log "=== REAPPLY START (only=${g_only_playbooks:-all}) ==="
echo "running" > "$g_status_file"

# Build list of playbooks to re-run
g_playbooks=""

if [[ -n "$g_only_playbooks" ]]
then
  # Only specific playbooks — check each is installed via symbios-state.sh
  for g_pb in $g_only_playbooks
  do
    if symbios-state.sh is-installed "$g_pb" 2>/dev/null
    then
      g_playbooks=$(printf '%s\n' "$g_playbooks" "$g_pb")
    else
      f_log "SKIP [$g_pb] — not installed"
      g_echo_note "SKIP: $g_pb — not installed"
    fi
  done
else
  # All playbooks registered in state file
  if [[ -s "$g_state_file" ]]
  then
    g_playbooks=$(grep -v '^#' "$g_state_file" 2>/dev/null | sed 's/:.*//' | sort)
  fi
fi

# Also include any user-playbooks (always re-run all)
g_user_dir="/home/docker/symbios-ui/config/user-playbooks"
if [[ -d "$g_user_dir" ]]
then
  for g_user_file in "$g_user_dir"/*.yml
  do
    [[ -f "$g_user_file" ]] || continue
    g_playbooks=$(printf '%s\n' "$g_playbooks" "user-playbooks/$(basename "$g_user_file")")
  done
fi

if [[ -z "$g_playbooks" ]]
then
  f_log "No playbooks to re-run"
  g_echo_note "Nothing to re-run."
  exit 0
fi

# Execute each playbook
g_count=0
g_total=$(echo "$g_playbooks" | grep -c '[^ ]' || echo 0)
f_log "Will re-run $g_total playbooks"
g_echo_note "Re-running $g_total playbook(s)..."

for g_playbook in $g_playbooks
do
  g_count=$((g_count + 1))

  # Resolve full path
  g_path=""
  if [[ -f "$g_repo/$g_playbook" ]]
  then
    g_path="$g_repo/$g_playbook"
  elif [[ -f "/home/docker/symbios-ui/config/user-playbooks/$(basename "$g_playbook")" ]]
  then
    g_path="/home/docker/symbios-ui/config/user-playbooks/$(basename "$g_playbook")"
  fi

  if [[ -z "$g_path" ]]
  then
    f_log "WARN [$g_count/$g_total] Playbook not found: $g_playbook (skipping)"
    continue
  fi

  f_log "RUN [$g_count/$g_total] $g_playbook"
  echo "running:${g_count}/${g_total} ${g_playbook}" > "$g_status_file"

  if ansible-playbook --connection=local \
    --inventory "$g_inventory" \
    --limit localhost \
    -e "ansible_python_interpreter=/usr/bin/python3" \
    "$g_path" >> "$g_log_file" 2>&1
  then
    f_log "OK  [$g_count/$g_total] $g_playbook"
    g_echo_note "OK  [$g_count/$g_total] $g_playbook"
  else
    f_log "ERR [$g_count/$g_total] $g_playbook (exit code: $?)"
    g_echo_error "ERR [$g_count/$g_total] $g_playbook (exit code: $?)"
    g_exit_code=1
  fi
done

f_log "=== REAPPLY COMPLETE ==="
g_echo_note "Reapply complete."
