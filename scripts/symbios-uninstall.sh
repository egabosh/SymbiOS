#!/bin/bash

# SymbiOS - Debian-based server management platform
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

# symbios-uninstall.sh - Uninstall a SymbiOS service.
#
# Reads the # docs: block from the playbook via yq, stops services,
# deletes paths according to the mode, restarts if configured,
# and removes the state file entry.
#
# Usage:
#   symbios-uninstall.sh <playbook-path> <mode>
#
# Modes:
#   full    - Delete program_paths + userdata_paths
#   program - Delete only program_paths (keep userdata)
#   reset   - Delete only userdata_paths (keep program)
#
# The playbook-path is relative to the git root, e.g. "services/jellyfin.yml".

source /etc/bash/gaboshlib.include 2>/dev/null || true
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_script_dir/symbios-lib.sh"

# Check required tools
if ! command -v yq &>/dev/null
then
  g_echo_error "yq is not installed. Cannot parse playbook metadata."
  exit 1
fi

# Validate arguments
if [[ $# -lt 2 ]]
then
  g_echo_error "Usage: symbios-uninstall.sh <playbook-path> <mode>"
  g_echo_error "Modes: full, program, reset"
  exit 1
fi

f_playbook="$1"
f_mode="$2"

# Validate mode
if [[ "$f_mode" != "full" && "$f_mode" != "program" && "$f_mode" != "reset" ]]
then
  g_echo_error "Invalid mode: $f_mode (must be full, program, or reset)"
  exit 1
fi

# Resolve the playbook file path
f_playbook_file="${g_git_root}/${f_playbook}"
if [[ ! -f "$f_playbook_file" ]]
then
  g_echo_error "Playbook not found: $f_playbook_file"
  exit 1
fi

# Extract the # docs: block from the playbook comment header.
# The docs block starts at "# docs:" and continues until a non-comment
# line is encountered. We strip the leading "# " prefix for yq.
f_tmp=$(mktemp)
f_in_docs=0
while IFS= read -r f_line
do
  f_stripped="${f_line#"${f_line%%[![:space:]]*}"}"
  if [[ "$f_in_docs" -eq 1 ]]
  then
    if [[ "$f_stripped" == \#* ]]
    then
      # Strip "# " or "#" prefix
      echo "${f_stripped}" | sed 's/^#[ ]\?//' >> "$f_tmp"
    else
      break
    fi
  elif [[ "$f_stripped" == "# docs:"* ]]
  then
    f_in_docs=1
    echo "${f_stripped}" | sed 's/^#[ ]\?//' >> "$f_tmp"
  fi
done < "$f_playbook_file"

if [[ ! -s "$f_tmp" ]]
then
  g_echo_error "No # docs: block found in $f_playbook"
  rm -f "$f_tmp"
  exit 1
fi

g_echo_note "Parsed docs block from $f_playbook"

# --- Step 1: Stop services ---
f_stop_cmd=$(yq eval '.docs.uninstall.stop // ""' "$f_tmp" 2>/dev/null)
if [[ -n "$f_stop_cmd" && "$f_stop_cmd" != "" ]]
then
  g_echo_note "Stopping services: $f_stop_cmd"
  eval "$f_stop_cmd"
else
  g_echo_note "No stop command defined, skipping service stop"
fi

# --- Step 2: Delete paths ---
f_deleted_any=0

# Helper function: delete a list of paths from the docs block.
# When f_recursive=1, directories are removed completely (rm -rf).
# When f_recursive=0 (default), only files directly inside a directory
# are removed; subdirectories are preserved so that userdata dirs
# (e.g. nextcloud-data/) nested under a program dir (e.g.
# /symbios/services/nextcloud/) survive the "program" uninstall mode.
function f_delete_paths {
  local f_key="$1"
  local f_label="$2"
  local f_recursive="${3:-0}"
  local f_paths
  f_paths=$(yq eval ".docs.uninstall.${f_key}[]" "$f_tmp" 2>/dev/null)
  if [[ -z "$f_paths" ]]
  then
    g_echo_note "No ${f_label} paths defined, skipping"
    return
  fi
  while IFS= read -r f_path
  do
    if [[ -z "$f_path" ]]
    then
      continue
    fi
    if [[ -e "$f_path" ]]
    then
      g_echo_note "Deleting ${f_label}: $f_path"
      if [[ "$f_recursive" -eq 1 ]]
      then
        rm -rf "$f_path"
      elif [[ -d "$f_path" ]]
      then
        # Remove files and symlinks inside the directory, keep subdirectories
        find "$f_path" -maxdepth 1 -mindepth 1 ! -type d -delete
      else
        rm -f "$f_path"
      fi
      f_deleted_any=1
    else
      g_echo_note "Path not found (skipping): $f_path"
    fi
  done <<< "$f_paths"
}

case "$f_mode" in
  full)
    g_echo_note "Mode: full - deleting program + userdata paths"
    f_delete_paths "program_paths" "program"
    f_delete_paths "userdata_paths" "userdata" 1
    ;;
  program)
    g_echo_note "Mode: program - deleting program paths only"
    f_delete_paths "program_paths" "program"
    ;;
  reset)
    g_echo_note "Mode: reset - deleting userdata paths only"
    f_delete_paths "userdata_paths" "userdata" 1
    ;;
esac

if [[ "$f_deleted_any" -eq 0 ]]
then
  g_echo_warn "No paths were deleted (none found on disk)"
fi

# --- Step 3: Restart services ---
# Only restart if the docker-compose file still exists (skipped after full uninstall)
f_restart_cmd=$(yq eval '.docs.uninstall.restart // ""' "$f_tmp" 2>/dev/null)
if [[ -n "$f_restart_cmd" && "$f_restart_cmd" != "" ]]
then
  f_compose_file=$(echo "$f_restart_cmd" | grep -oP '(?<=-f )\S+' || true)
  if [[ -n "$f_compose_file" && -f "$f_compose_file" ]]
  then
    g_echo_note "Restarting services: $f_restart_cmd"
    eval "$f_restart_cmd"
  elif [[ -n "$f_compose_file" ]]
  then
    g_echo_note "Compose file $f_compose_file not found - skipping restart"
  else
    g_echo_note "Restarting services: $f_restart_cmd"
    eval "$f_restart_cmd"
  fi
else
  g_echo_note "No restart command defined, skipping service restart"
fi

# --- Step 4: Remove from state file ---
g_echo_note "Removing $f_playbook from installed-playbooks state"
"$g_script_dir/symbios-state.sh" unset "$f_playbook"

# Cleanup
rm -f "$f_tmp"

g_echo_note "Uninstall of $f_playbook completed (mode: $f_mode)"
