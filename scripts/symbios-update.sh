#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (C) 2025 SymbiOS Contributors
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
if [ -f /etc/bash/gaboshlib.include ]
then
    source /etc/bash/gaboshlib.include 2>/dev/null || true
fi

g_symbios_dir="${SYMBIOS_DIR:-/home/SymbiOS}"
g_repo_url="https://github.com/egabosh/SymbiOS.git"
g_inventory="${g_inventory:-/home/docker/symbios-ui/config/inventory.yml}"
g_state_file="/home/docker/symbios-ui/config/installed-playbooks.yml"
g_failed=""
g_dry_run=false

function f_usage {
    cat << EOF
Usage: symbios-update.sh [OPTIONS]

Options:
  -h, --help          Show this help message
  -d, --dry-run       Check for changes but do not apply them

Pull latest changes from GitHub and run any updated playbooks.
EOF
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
            f_usage
            exit 1
            ;;
    esac
    shift
done

if [ "${g_dry_run}" = true ]
then
    g_echo_note "Dry run mode - checking changes only"
fi

g_echo_note "Starting SymbiOS update at $(date)"

# Clone or update SymbiOS from GitHub
cd /home
[[ -d SymbiOS ]] || git clone "${g_repo_url}"
cd SymbiOS
git remote set-url origin "${g_repo_url}"

# Save pre-pull HEAD for diff
f_head_before=$(git rev-parse HEAD 2>/dev/null)

if ! git pull
then
    git checkout -- .
    git pull
fi

f_head_after=$(git rev-parse HEAD 2>/dev/null)

# Nothing changed
if [ "${f_head_before}" = "${f_head_after}" ]
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
if [ ! -f "${g_inventory}" ]
then
    g_echo_error "Inventory file not found: ${g_inventory}"
    exit 1
fi

# Get changed files between old and new HEAD
f_changed_files=$(git diff --name-only "${f_head_before}" "${f_head_after}" 2>/dev/null)

# Get list of installed playbooks from state file
g_echo_note "Checking installed playbooks"
f_installed_playbooks=()

if [ -f "${g_state_file}" ]
then
    while read -r f_line
    do
        if [[ "${f_line}" =~ ^([^:]+): ]]
        then
            f_installed_playbooks+=("${BASH_REMATCH[1]}")
        fi
    done < "${g_state_file}"
fi

f_playbooks_count=${#f_installed_playbooks[@]}
g_echo_note "Found ${f_playbooks_count} installed playbook(s):"
for f_playbook in "${f_installed_playbooks[@]}"
do
    g_echo_note "  - ${f_playbook}"
done

# Find installed playbooks that changed
f_updated_playbooks=()
for f_playbook in "${f_installed_playbooks[@]}"
do
    if echo "${f_changed_files}" | grep -q "^${f_playbook}$"
    then
        g_echo_note "  ${f_playbook} - changes detected"
        f_updated_playbooks+=("${f_playbook}")
    fi
done

# Also check if webui source files changed (triggers symbios-ui.yml)
if echo "${f_changed_files}" | grep -q "^webui/"
then
    g_echo_note "  webui source files changed"
    f_updated_playbooks+=("base-services/symbios-ui.yml")
fi

# Run changed playbooks
if [ ${#f_updated_playbooks[@]} -eq 0 ]
then
    g_echo_note "No updates needed"
else
    g_echo_note "Will update ${#f_updated_playbooks[@]} playbook(s):"
    for f_playbook in "${f_updated_playbooks[@]}"
    do
        g_echo_note "  - ${f_playbook}"
    done

    if [ "${g_dry_run}" = true ]
    then
        g_echo_note "Dry run: Skipping actual updates"
    else
        for f_playbook in "${f_updated_playbooks[@]}"
        do
            g_echo_note "Running ${f_playbook}"
            if ansible-playbook --connection=local --limit localhost --inventory "${g_inventory}" "${f_playbook}"
            then
                g_echo_note "  Successfully ran ${f_playbook}"
            else
                g_echo_error "  Failed to run ${f_playbook}"
                g_failed="${g_failed} ${f_playbook}"
            fi
        done
    fi
fi

# Report results
g_echo_note ""
g_echo_note "=== Update Summary ==="
if [ -z "${g_failed}" ]
then
    g_echo_note "All playbooks updated successfully"
else
    g_echo_error "FAILED playbooks:${g_failed}"
    g_echo_error "Fix the issues and run again, or reboot to retry."
fi

g_echo_note "Update completed at $(date)"
