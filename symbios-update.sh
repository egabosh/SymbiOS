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

# symbios-update.sh - Pull changes from Git repo and apply updates to installed playbooks
# 
# This script checks for updates to installed playbooks and runs them. It works by:
# 1. Cloning/updating the SymbiOS repo from GitHub (https)
# 2. Reading the installed-playbooks state file to know which playbooks are installed
# 3. For each installed playbook, check if the version in the updated repo is newer (via git diff)
# 4. If newer, backup old version and replace with new version
# 5. Then run the playbook via ansible

# Source gaboshlib if available
if [ -f /etc/bash/gaboshlib.include ]
then
    source /etc/bash/gaboshlib.include 2>/dev/null || true
fi

g_symbios_dir="${SYMBIOS_DIR:-/home/SymbiOS}"
g_repo_url="https://github.com/egabosh/SymbiOS.git"
g_inventory="${g_inventory:-/home/docker/symbios-ui/config/inventory.yml}"
g_failed=""
g_verbose=false
g_dry_run=false
g_no_reapply=false

function f_usage {
    cat << EOF
Usage: symbios-update.sh [OPTIONS]

Options:
  -h, --help          Show this help message
  -v, --verbose       Increase verbosity
  -d, --dry-run       Check for changes but do not apply them
  -n, --no-reapply    Do not start reapply script after updates
  
Update SymbiOS base-services playbooks from the official GitHub repository.

The script will:
  1. Clone or update the SymbiOS repository from GitHub
  2. Check for changes in each installed playbook
  3. Update and run playbooks that have changes
  4. Start the background reapply script (unless disabled)
EOF
}

function f_notice {
    local f_msg="${1}"
    f_echo_norm "*** ${f_msg}"
}

function f_error {
    local f_msg="${1}"
    g_echo_error "${f_msg}" 1>&2
}

# Parse arguments
while [ $# -gt 0 ]
do
    case "${1}" in
        -v|--verbose)
            g_verbose=true
            ;;
        -d|--dry-run)
            g_dry_run=true
            ;;
        -n|--no-reapply)
            g_no_reapply=true
            ;;
        -h|--help)
            f_usage
            exit 0
            ;;
        *)
            f_error "Unknown option: ${1}"
            f_usage
            exit 1
            ;;
    esac
    shift
done

if [ "${g_verbose}" = true ]
then
    f_notice "Verbose mode enabled"
fi

if [ "${g_dry_run}" = true ]
then
    f_notice "Dry run mode - checking changes only"
fi

if [ "${g_no_reapply}" = true ]
then
    f_notice "Will not start reapply script"
fi

f_notice "Starting SymbiOS update at $(date)"

# Clone or update the SymbiOS repository
if [ ! -d "${g_symbios_dir}" ]
then
    f_notice "Cloning SymbiOS repository into ${g_symbios_dir}"
    if [ ! -d "$(dirname "${g_symbios_dir}")" ]
    then
        mkdir -p "$(dirname "${g_symbios_dir}")"
    fi
    if git clone "${g_repo_url}" "${g_symbios_dir}"
    then
        f_notice "  Successfully cloned repository"
    else
        f_error "  Failed to clone repository"
        exit 1
    fi
else
    f_notice "Updating SymbiOS repository in ${g_symbios_dir}"
    cd "${g_symbios_dir}" || {
        f_error "Could not change to SymbiOS directory"
        exit 1
    }
    if git remote get-url origin | grep -q "https"
    then
        f_notice "  Repository source is HTTPS - pulling from remote"
        if git checkout main 2>/dev/null
        then
            if git pull origin main
            then
                f_notice "  Successfully updated repository"
            else
                f_error "  Failed to update repository"
                exit 1
            fi
        else
            f_notice "  On detached HEAD - doing a hard pull"
            if git fetch origin main && git reset --hard origin/main
            then
                f_notice "  Successfully updated repository"
            else
                f_error "  Failed to update repository"
                exit 1
            fi
        fi
    else
        f_notice "  Repository source is SSH - using git pull"
        if git pull
        then
            f_notice "  Successfully updated repository"
        else
            f_error "  Failed to update repository"
            exit 1
        fi
    fi
fi

# Change to SymbiOS directory
cd "${g_symbios_dir}" || {
    f_error "Could not change to SymbiOS directory"
    exit 1
}

# Check if ansible is available
if ! which ansible >/dev/null 2>&1
then
    f_error "Ansible is not installed. Please install ansible first."
    exit 1
fi

# Check if we have an inventory file
if [ ! -f "${g_inventory}" ]
then
    f_error "Inventory file not found: ${g_inventory}"
    exit 1
fi

# Get list of installed playbooks from state file
f_notice "Checking installed playbooks"
f_installed_playbooks=()
f_line=""

if [ -f "installed-playbooks.yml" ]
then
    while read -r f_line
    do
        if [[ "${f_line}" =~ ^(.+): ]]
        then
            f_playbook="${BASH_REMATCH[1]}"
            f_installed_playbooks+=("${f_playbook}")
        fi
    done < "installed-playbooks.yml"
fi

f_playbooks_count=${#f_installed_playbooks[@]}
f_notice "Found ${f_playbooks_count} installed playbook(s):"
for f_playbook in "${f_installed_playbooks[@]}"
do
    f_notice "  - ${f_playbook}"
done

# Check each installed playbook for changes
f_updated_playbooks=()
for f_playbook in "${f_installed_playbooks[@]}"
do
    f_notice "Checking ${f_playbook} for changes"
    f_repo_file="${g_symbios_dir}/${f_playbook}"
    f_installed_path="${f_playbook}"

    if [ ! -f "${f_repo_file}" ]
    then
        f_notice "  Warning: Playbook not found in SymbiOS repository: ${f_playbook}"
        continue
    fi

    if [ ! -f "${f_installed_path}" ]
    then
        f_notice "  Warning: Installed playbook file not found: ${f_installed_path}"
        continue
    fi

    if [ "${f_installed_path}" != "${f_repo_file}" ]
    then
        f_diff_count=0
        f_diff_count=$(diff -u "${f_installed_path}" "${f_repo_file}" 2>/dev/null | wc -l)
        if [ "${f_diff_count}" -gt 0 ]
        then
            f_notice "  Changes detected - will update"
            f_updated_playbooks+=("${f_playbook}")
        else
            f_notice "  Already up-to-date"
        fi
    else
        f_notice "  Already up-to-date (same file)"
    fi
done

if [ ${#f_updated_playbooks[@]} -eq 0 ]
then
    f_notice "No updates needed"
else
    f_notice "Will update ${#f_updated_playbooks[@]} playbook(s):"
    for f_playbook in "${f_updated_playbooks[@]}"
    do
        f_notice "  - ${f_playbook}"
    done

    if [ "${g_dry_run}" = true ]
    then
        f_notice "Dry run: Skipping actual updates"
    else
        # Update and run each updated playbook
        for f_playbook in "${f_updated_playbooks[@]}"
        do
            f_notice "Processing ${f_playbook}"
            f_repo_file="${g_symbios_dir}/${f_playbook}"
            f_installed_path="${f_playbook}"

            # Backup existing file if it exists
            if [ -f "${f_installed_path}" ]
            then
                f_notice "  Backing up existing ${f_installed_path} to ${f_installed_path}.backup"
                cp "${f_installed_path}" "${f_installed_path}.backup"
            fi

            # Copy new file
            f_notice "  Copying ${f_repo_file} to ${f_installed_path}"
            if ! cp "${f_repo_file}" "${f_installed_path}"
            then
                f_error "  Failed to copy ${f_repo_file} to ${f_installed_path}"
                continue
            fi

            f_notice "  Running ${f_playbook}"
            if ansible-playbook --connection=local --limit localhost --inventory "${g_inventory}" "${f_installed_path}"
            then
                f_notice "  Successfully ran ${f_playbook}"
            else
                f_error "  Failed to run ${f_playbook}"
                g_failed="${g_failed} ${f_playbook}"
            fi
        done
    fi
fi

# Report results
f_notice ""
f_notice "=== Update Summary ==="
if [ -z "${g_failed}" ]
then
    f_notice "All playbooks updated successfully"
else
    f_notice "FAILED playbooks:${g_failed}"
    f_notice "Fix the issues and run again, or reboot to retry."
fi

if [ "${g_no_reapply}" = false ]
then
    f_notice "Starting reapply script for background processing"
    if command -v nohup >/dev/null 2>&1 && command -v sleep >/dev/null 2>&1
    then
        nohup /usr/local/sbin/symbios-reapply.sh > /dev/null 2>&1 &
        f_notice "Reapply script started with PID $!"
    else
        f_notice "Nohup or sleep not available - cannot start reapply script"
    fi
else
    f_notice "Skipping reapply script start"
fi

f_notice "Update completed at $(date)"