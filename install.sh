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

set -x

# Track failed playbooks for final report
g_failed=""

function f_run_playbook {
    local f_playbook="${1}"
    echo ">>> Running: $(basename "${f_playbook}")"
    if ansible-playbook --limit localhost --inventory "${g_inventory}" "${f_playbook}"
    then
        echo ">>> OK: $(basename "${f_playbook}")"
    else
        echo ">>> FAILED: $(basename "${f_playbook}") (exit $?)"
        g_failed="${g_failed} $(basename "${f_playbook}")"
    fi
}

# Fix interrupted dpkg state (can happen after image expansion / e2fsck)
dpkg --configure -a 2>/dev/null || true

# Install ansible and git if not already present
if ! which ansible >/dev/null 2>&1
then
    DEBIAN_FRONTEND=noninteractive apt-get -y update --allow-releaseinfo-change
    DEBIAN_FRONTEND=noninteractive apt-get -y install ansible git
    ansible-galaxy collection install community.general
fi

# Clone or update SymbiOS from GitHub
cd /home
[[ -d SymbiOS ]] || git clone https://github.com/egabosh/SymbiOS.git
cd SymbiOS
git remote set-url origin https://github.com/egabosh/SymbiOS.git
if ! git pull
then
    git stash
    git pull
fi

# Create initial inventory if it does not exist
g_inventory_path="/home/docker/symbios-ui/config"
g_inventory="${g_inventory_path}/inventory.yml"
if ! [[ -s ${g_inventory} ]]
then
    mkdir -p "${g_inventory_path}"
    chmod 700 "${g_inventory_path}"
    cp /home/SymbiOS/inventory.yml "${g_inventory}"
    chmod 600 "${g_inventory}"
fi

# Run base-services playbooks
f_run_playbook /home/SymbiOS/base-services/basics.yml
f_run_playbook /home/SymbiOS/base-services/hardening.yml
f_run_playbook /home/SymbiOS/base-services/firewall.yml
f_run_playbook /home/SymbiOS/base-services/backup.yml
f_run_playbook /home/SymbiOS/base-services/autoupdate.yml
f_run_playbook /home/SymbiOS/base-services/runchecks.yml
f_run_playbook /home/SymbiOS/base-services/docker.yml
f_run_playbook /home/SymbiOS/base-services/dedyn.yml
f_run_playbook /home/SymbiOS/base-services/acme-pki.yml
f_run_playbook /home/SymbiOS/base-services/traefik.yml
f_run_playbook /home/SymbiOS/base-services/ldap.yml
f_run_playbook /home/SymbiOS/base-services/authelia.yml

# Detect Raspberry Pi and install platform-specific playbooks
if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model
then
    f_run_playbook /home/SymbiOS/base-services/raspberry.yml
    f_run_playbook /home/SymbiOS/desktop/firefox.yml
fi

f_run_playbook /home/SymbiOS/base-services/symbios-ui.yml

# Report results
echo ""
echo "=== Installation summary ==="
if [ -n "${g_failed}" ]
then
    echo "FAILED playbooks:${g_failed}"
    echo "Fix the issues and run again, or reboot to retry."
    exit 1
else
    echo "All playbooks completed successfully."
    exit 0
fi
