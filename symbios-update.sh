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
g_dry_run=false
g_no_reapply=false

function f_usage {
    cat << EOF
Usage: symbios-update.sh [OPTIONS]

Options:
  -h, --help          Show this help message
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

# Parse arguments
while [ $# -gt 0 ]
do
case "${1}" in
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

if [ "${g_no_reapply}" = true ]
then
    g_echo_note "Will not start reapply script"
fi

g_echo_note "Starting SymbiOS update at $(date)"

# Clone or update the SymbiOS repository
if [ ! -d "${g_symbios_dir}" ]
then
    g_echo_note "Cloning SymbiOS repository into ${g_symbios_dir}"
    if [ ! -d "$(dirname "${g_symbios_dir}")" ]
    then
        mkdir -p "$(dirname "${g_symbios_dir}")"
    fi
    if git clone "${g_repo_url}" "${g_symbios_dir}"
    then
        g_echo_note "  Successfully cloned repository"
    else
        g_echo_error "  Failed to clone repository"
        exit 1
    fi
else
    g_echo_note "Updating SymbiOS repository in ${g_symbios_dir}"
    cd "${g_symbios_dir}" || {
        g_echo_error "Could not change to SymbiOS directory"
        exit 1
    }
    if git remote get-url origin | grep -q "https"
    then
        g_echo_note "  Repository source is HTTPS - pulling from remote"
        if git checkout main 2>/dev/null
        then
            if git pull origin main
            then
                g_echo_note "  Successfully updated repository"
            else
                g_echo_error "  Failed to update repository"
                exit 1
            fi
        else
            g_echo_note "  On detached HEAD - doing a hard pull"
            if git fetch origin main && git reset --hard origin/main
            then
                g_echo_note "  Successfully updated repository"
            else
                g_echo_error "  Failed to update repository"
                exit 1
            fi
        fi
    else
        g_echo_note "  Repository source is SSH - using git pull"
        if git pull
        then
            g_echo_note "  Successfully updated repository"
        else
            g_echo_error "  Failed to update repository"
            exit 1
        fi
    fi
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

# Get list of installed playbooks from state file
g_echo_note "Checking installed playbooks"
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
g_echo_note "Found ${f_playbooks_count} installed playbook(s):"
for f_playbook in "${f_installed_playbooks[@]}"
do
    g_echo_note "  - ${f_playbook}"
done

# Check each installed playbook for changes
f_updated_playbooks=()
for f_playbook in "${f_installed_playbooks[@]}"
do
    g_echo_note "Checking ${f_playbook} for changes"
    f_repo_file="${g_symbios_dir}/${f_playbook}"
    f_installed_path="${f_playbook}"

    if [ ! -f "${f_repo_file}" ]
    then
        g_echo_warn "  Warning: Playbook not found in SymbiOS repository: ${f_playbook}"
        continue
    fi

    if [ ! -f "${f_installed_path}" ]
    then
        g_echo_warn "  Warning: Installed playbook file not found: ${f_installed_path}"
        continue
    fi

    if [ "${f_installed_path}" != "${f_repo_file}" ]
    then
        f_diff_count=0
        f_diff_count=$(diff -u "${f_installed_path}" "${f_repo_file}" 2>/dev/null | wc -l)
        if [ "${f_diff_count}" -gt 0 ]
        then
            g_echo_note "  Changes detected - will update"
            f_updated_playbooks+=("${f_playbook}")
        else
            g_echo_note "  Already up-to-date"
        fi
    else
        g_echo_note "  Already up-to-date (same file)"
    fi
done

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
        # Update and run each updated playbook
        for f_playbook in "${f_updated_playbooks[@]}"
        do
            g_echo_note "Processing ${f_playbook}"
            f_repo_file="${g_symbios_dir}/${f_playbook}"
            f_installed_path="${f_playbook}"

            # Backup existing file if it exists
            if [ -f "${f_installed_path}" ]
            then
                g_echo_note "  Backing up existing ${f_installed_path} to ${f_installed_path}.backup"
                cp "${f_installed_path}" "${f_installed_path}.backup"
            fi

            # Copy new file
            g_echo_note "  Copying ${f_repo_file} to ${f_installed_path}"
            if ! cp "${f_repo_file}" "${f_installed_path}"
            then
                g_echo_error "  Failed to copy ${f_repo_file} to ${f_installed_path}"
                continue
            fi

            g_echo_note "  Running ${f_playbook}"
            if ansible-playbook --connection=local --limit localhost --inventory "${g_inventory}" "${f_installed_path}"
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

if [ "${g_no_reapply}" = false ]
then
    g_echo_note "Starting reapply script for background processing"
    if command -v nohup >/dev/null 2>&1 && command -v sleep >/dev/null 2>&1
    then
        nohup /usr/local/sbin/symbios-reapply.sh > /dev/null 2>&1 &
        g_echo_note "Reapply script started with PID $!"
    else
        g_echo_warn "Nohup or sleep not available - cannot start reapply script"
    fi
else
    g_echo_note "Skipping reapply script start"
fi

g_echo_note "Update completed at $(date)"