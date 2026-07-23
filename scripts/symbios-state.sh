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

# symbios-state.sh — Manage the installed-playbooks state file.
#
# Each playbook registers itself via this script so the reapply script
# knows which playbooks to re-run. The state file is a simple YAML-ish
# text file: one "<playbook-path>: <ISO-timestamp>" per line.
#
# Usage:
#   symbios-state.sh set   <playbook-path>   # register as installed
#   symbios-state.sh unset <playbook-path>   # remove from installed list
#   symbios-state.sh list                     # print installed playbooks
#   symbios-state.sh is-installed <path>      # exit 0 if installed, 1 if not

source /etc/bash/gaboshlib.include 2>/dev/null || true

g_state_file="/home/docker/symbios-ui/config/installed-playbooks.yml"

# Ensure state file exists
if [[ ! -f "$g_state_file" ]]
then
  mkdir -p "$(dirname "$g_state_file")"
  printf '%s\n' "# Auto-maintained by playbooks via symbios-state.sh" > "$g_state_file"
  chmod 644 "$g_state_file"
fi

function f_usage {
  cat << EOF
Usage: symbios-state.sh <command> [argument]

Commands:
  set <playbook>       Register playbook as installed
  unset <playbook>     Remove playbook from installed list
  list                 Print installed playbooks (one per line, just paths)
  is-installed <path>  Check if playbook is installed (exit 0/1)
EOF
}

function f_set {
  local f_playbook="$1"
  if [[ -z "$f_playbook" ]]
  then
    g_echo_error "No playbook path given"
    exit 1
  fi
  local f_timestamp
  f_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Remove old entry if present, then append updated one
  f_unset_quiet "$f_playbook"
  printf '%s: "%s"\n' "$f_playbook" "$f_timestamp" >> "$g_state_file"
}

function f_unset {
  local f_playbook="$1"
  if [[ -z "$f_playbook" ]]
  then
    g_echo_error "No playbook path given"
    exit 1
  fi
  f_unset_quiet "$f_playbook"
}

function f_unset_quiet {
  local f_playbook="$1"
  local f_tmp
  f_tmp=$(mktemp)
  # Remove lines matching this playbook (prefix or full match)
  grep -v "^${f_playbook}:" "$g_state_file" > "$f_tmp" 2>/dev/null || true
  mv "$f_tmp" "$g_state_file"
  chmod 644 "$g_state_file"
}

function f_list {
  # Output only playbook paths, one per line
  grep -v '^#' "$g_state_file" 2>/dev/null | sed 's/:.*//' | sort
}

function f_is_installed {
  local f_playbook="$1"
  grep -q "^${f_playbook}:" "$g_state_file" 2>/dev/null
}

# Dispatch
case "${1:-}" in
  set)
    f_set "$2"
    ;;
  unset)
    f_unset "$2"
    ;;
  list)
    f_list
    ;;
  is-installed)
    f_is_installed "$2"
    ;;
  *)
    f_usage
    exit 1
    ;;
esac
