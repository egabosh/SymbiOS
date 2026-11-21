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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# symbios-update.sh - Pull changes from Git repo and run changed playbooks
#
# 1. Clones/updates the SymbiOS repo from GitHub
# 2. Uses git diff to detect which installed playbooks changed
# 3. Runs changed playbooks via ansible

# Source gaboshlib if available
source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile

# Also log standalone runs to the shared update log for the WebUI log
# viewer. When called from autoupdate.sh the variable is already exported
# and the output is logged there - skip to avoid double entries.
if [[ -z "${SYMBIOS_UPDATE_LOG:-}" ]] && [[ -n "${g_log_dir}" ]]
then
  export SYMBIOS_UPDATE_LOG="${g_log_dir}/autoupdate.log"
  if mkdir -p "${g_log_dir}" 2>/dev/null || [[ -d "${g_log_dir}" ]]
  then
    exec > >(tee -a "${SYMBIOS_UPDATE_LOG}") 2>&1
  fi
fi

g_symbios_dir="${SYMBIOS_DIR:-${g_git_root}}"
g_repo_url="https://github.com/egabosh/SymbiOS.git"
g_failed=""
g_dry_run=false

function f_usage {
  cat << EOF
Usage: symbios-update.sh [OPTIONS]

Options:
  -h, --help          Show this help message
  -d, --dry-run       Check for changes but do not apply them

Pull latest changes from GitHub and run any updated playbooks. Playbooks
newly listed in install.sh are installed once as well, so existing hosts
receive new base services without a manual step.
EOF
}

# Platform gate from the playbook docs header, mirroring the rule in
# symbios-playbooks-for-vars.sh (that script parses arguments on source, so
# it cannot be sourced here). Read the header from the target revision:
# --dry-run never checks out the new tree. Unknown values never skip.
function f_applies_here {
  local f_pb="${1}" f_rev="${2}" f_when

  f_when="$(git show "${f_rev}:${f_pb}" 2>/dev/null | awk '
    /^# *applies_when: */ {
      line = $0
      sub(/^# *applies_when: */, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      gsub(/^["\x27]|["\x27]$/, "", line)
      print line
      exit
    }
  ')"

  case "${f_when}" in
    raspberry_pi)
      [[ -f /proc/device-tree/model ]] && grep -qi "raspberry" /proc/device-tree/model
      ;;
    *)
      true
      ;;
  esac
}

# Parse arguments
while [ $# -gt 0 ]
do
  case "${1}" in
    -d|--dry-run)
      g_dry_run=true
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: ${1}"
      f_usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${g_dry_run}" == true ]]
then
  g_echo_note "Dry run mode - checking changes only"
fi

g_echo_note "Starting SymbiOS update at $(date)"

# Clone or update SymbiOS from GitHub
if [[ ! -d "${g_symbios_dir}/.git" ]]
then
  mkdir -p "$(dirname "${g_symbios_dir}")"
  git clone "${g_repo_url}" "${g_symbios_dir}"
fi
cd "${g_symbios_dir}"
git remote set-url origin "${g_repo_url}"

# Save pre-pull HEAD for diff
g_head_before=$(git rev-parse HEAD 2>/dev/null)

# Fetch the latest changes from GitHub
git fetch origin

if [[ "${g_dry_run}" == true ]]
then
  # Dry run: never touch the working tree - compare HEAD against the
  # freshly fetched origin/main (read-only check).
  g_head_after=$(git rev-parse origin/main 2>/dev/null)
  g_changed_files=$(git diff --name-only "${g_head_before}" "${g_head_after}" 2>/dev/null)
else
  # Discard any local changes and sync to GitHub
  git reset --hard origin/main
  git clean -fd

  g_head_after=$(git rev-parse HEAD 2>/dev/null)
fi

# Nothing changed
if [[ "${g_head_before}" == "${g_head_after}" ]]
then
  g_echo_note "Repository already up-to-date"
  g_echo_note "Update completed at $(date)"
  exit 0
fi

# Change to SymbiOS directory
cd "${g_symbios_dir}" || {
  g_echo_error "Could not change to SymbiOS directory"
  exit 1
}

# Check if ansible is available
if ! which ansible >/dev/null 2>&1
then
  g_echo_error "Ansible is not installed. Please install ansible first."
  exit 1
fi

# Check if we have an inventory file
if [[ ! -s "${g_inventory}" ]]
then
  g_echo_error "Inventory file not found: ${g_inventory}"
  exit 1
fi

# Get changed files between old and new HEAD (already computed for dry run)
if [[ "${g_dry_run}" != true ]]
then
  g_changed_files=$(git diff --name-only "${g_head_before}" "${g_head_after}" 2>/dev/null)
fi

# Get list of installed playbooks from state file
g_echo_note "Checking installed playbooks"
g_installed_playbooks=()

if [[ -f "${g_state_file}" ]]
then
  while read -r g_line
  do
    if [[ "${g_line}" =~ ^([^:]+): ]]
    then
      g_installed_playbooks+=("${BASH_REMATCH[1]}")
    fi
  done < "${g_state_file}"
fi

g_playbooks_count=${#g_installed_playbooks[@]}
g_echo_note "Found ${g_playbooks_count} installed playbook(s):"
for g_playbook in "${g_installed_playbooks[@]}"
do
  g_echo_note "  - ${g_playbook}"
done

# Find installed playbooks that changed
g_updated_playbooks=()
for g_playbook in "${g_installed_playbooks[@]}"
do
  if echo "${g_changed_files}" | grep -q "^${g_playbook}$"
  then
    g_echo_note "  ${g_playbook} - changes detected"
    g_updated_playbooks+=("${g_playbook}")
  fi
done

# Also check if webui source files changed (triggers symbios-ui.yml)
if echo "${g_changed_files}" | grep -q "^webui/"
then
  g_echo_note "  webui source files changed"
  g_updated_playbooks+=("base-services/symbios-ui.yml")
fi

# A playbook newly added to install.sh is absent from every host's state file,
# so the "installed and changed" check above cannot see it. Compare both
# revisions and run the additions once - this is how installations we do not
# know about receive new base services after an update.
if echo "${g_changed_files}" | grep -q '^install.sh$'
then
  g_echo_note "  install.sh changed - checking for newly added base playbooks"
  if git cat-file -e "${g_head_before}:install.sh" 2>/dev/null \
     && git cat-file -e "${g_head_after}:install.sh" 2>/dev/null
  then
    g_old_pb_list="$(git show "${g_head_before}:install.sh" | grep 'f_run_playbook' | grep -oE 'base-services/[a-zA-Z0-9._-]+\.yml' | sort -u)"
    g_new_pb_list="$(git show "${g_head_after}:install.sh" | grep 'f_run_playbook' | grep -oE 'base-services/[a-zA-Z0-9._-]+\.yml' | sort -u)"
    g_added_pb_list="$(comm -13 <(printf '%s\n' "${g_old_pb_list}") <(printf '%s\n' "${g_new_pb_list}"))"

    # Keep install.sh order instead of the alphabetical order of comm.
    while read -r f_pb
    do
      [[ -n "${f_pb}" ]] || continue
      printf '%s\n' "${g_added_pb_list}" | grep -Fxq "${f_pb}" || continue
      if ! f_applies_here "${f_pb}" "${g_head_after}"
      then
        g_echo_note "    SKIP ${f_pb} (platform gate)"
        continue
      fi
      g_echo_note "  ${f_pb} - newly added in install.sh"
      g_updated_playbooks+=("${f_pb}")
    done < <(git show "${g_head_after}:install.sh" | grep 'f_run_playbook' | grep -oE 'base-services/[a-zA-Z0-9._-]+\.yml' | awk '!seen[$0]++')
  fi
fi

# Sort playbooks into the canonical run order: base-services as listed in
# install.sh, then the rest alphabetically. State-file order is install time,
# not dependency order - basics.yml seeds the secret store and must run before
# its consumers (nextcloud, ldap, ...) on hosts where it was installed late.
# This mirrors symbios-playbooks-for-vars.sh. Also drops duplicate paths that
# can arrive twice (changed and newly added, or via the webui trigger).
function f_order_playbooks {
  local f_wanted f_pb
  f_wanted="$(printf '%s\n' "$@" | awk '!seen[$0]++')"
  {
    grep -oE 'base-services/[a-zA-Z0-9._-]+\.yml' install.sh 2>/dev/null | awk '!seen[$0]++'
    printf '%s\n' "${f_wanted}" | sort
  } | awk '!seen[$0]++' | while read -r f_pb
  do
    printf '%s\n' "${f_wanted}" | grep -Fxq "${f_pb}" && printf '%s\n' "${f_pb}"
  done
}

if [[ ${#g_updated_playbooks[@]} -gt 0 ]]
then
  mapfile -t g_updated_playbooks < <(f_order_playbooks "${g_updated_playbooks[@]}")
fi

# Run changed playbooks
if [ ${#g_updated_playbooks[@]} -eq 0 ]
then
  g_echo_note "No updates needed"
else
  g_echo_note "Will update ${#g_updated_playbooks[@]} playbook(s):"
  for g_playbook in "${g_updated_playbooks[@]}"
  do
    g_echo_note "  - ${g_playbook}"
  done

  if [[ "${g_dry_run}" == true ]]
  then
    g_echo_note "Dry run: Skipping actual updates"
  else
    for g_playbook in "${g_updated_playbooks[@]}"
    do
      g_echo_note "Running ${g_playbook}"
      g_echo "ansible-playbook --connection=local --limit localhost --inventory \"${g_inventory}\" \"${g_playbook}\""
      if ansible-playbook --connection=local --limit localhost --inventory "${g_inventory}" "${g_playbook}"
      then
        g_echo_note "  Successfully ran ${g_playbook}"
      else
        g_echo_error "  Failed to run ${g_playbook}"
        g_failed="${g_failed} ${g_playbook}"
      fi
    done
  fi
fi

# Report results
g_echo_note ""
g_echo_note "=== Update Summary ==="
if [[ -z "${g_failed}" ]]
then
  g_echo_note "All playbooks updated successfully"
else
  g_echo_error "FAILED playbooks:${g_failed}"
  g_echo_error "Fix the issues and run again, or reboot to retry."
fi

g_echo_note "Update completed at $(date)"
# The autoupdate dispatcher sources this script via a module, so the last
# command must carry the failure status of the playbook runs above.
[[ -z "${g_failed}" ]]
