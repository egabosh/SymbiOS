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
    /bin/bash
  fi
}

# sync time for git
ntpdate time.fu-berlin.de

# Filesystem layout
g_data_root="/symbios"
g_git_root="${g_data_root}/git/SymbiOS"
g_base_services_root="${g_data_root}/base-services"

# Fix interrupted dpkg state (can happen after image expansion / e2fsck)
dpkg --configure -a 2>/dev/null || true

# Install ansible and git if not already present
if ! which ansible >/dev/null 2>&1
then
  DEBIAN_FRONTEND=noninteractive apt-get -y update --allowreleaseinfo-change
  DEBIAN_FRONTEND=noninteractive apt-get -y install ansible git
  ansible-galaxy collection install community.general
fi

# Create the /symbios data root (optional LUKS partition may overlay it later)
mkdir -p "${g_data_root}"
chmod 750 "${g_data_root}"
mkdir -p "${g_base_services_root}"

# Clone or update SymbiOS from GitHub
if [[ ! -d "${g_git_root}/.git" ]]
then
  mkdir -p "$(dirname "${g_git_root}")"
  git clone https://github.com/egabosh/SymbiOS.git "${g_git_root}"
fi
cd "${g_git_root}"
git remote set-url origin https://github.com/egabosh/SymbiOS.git
if ! git pull
then
  git stash
  git pull
fi

# expand PATH to SymbiOS scripts
export PATH="${g_git_root}/scripts:$PATH"

# Create initial inventory if it does not exist
g_inventory_path="${g_base_services_root}/symbios-ui/config"
g_inventory="${g_inventory_path}/inventory.yml"
if ! [[ -s ${g_inventory} ]]
then
  mkdir -p "${g_inventory_path}"
  chmod 700 "${g_inventory_path}"
  cp "${g_git_root}/inventory.yml" "${g_inventory}"
  chmod 600 "${g_inventory}"
fi

# Run base-services playbooks
f_run_playbook "${g_git_root}/base-services/basics.yml"

# optional set password for symbios user (interactive on physical console)
# Systemd's rc-local.service sets stdin=/dev/null, so we redirect from
# the actual console TTY to make passwd read keyboard input correctly.
g_wait=60
echo "Optional set password for symbios user - Waiting $g_wait seconds"
if [ -c /dev/tty1 ]
then
  echo "/dev/tty1"
  timeout -k $g_wait $g_wait passwd symbios < /dev/tty1 > /dev/tty1 2>&1
elif [ -c /dev/console ] 
then
  echo "/dev/console"
  timeout -k $g_wait $g_wait passwd symbios < /dev/console > /dev/console 2>&1
else
  echo "NORMAL"
  timeout -k $g_wait $g_wait passwd symbios
fi

# continue running playbooks
f_run_playbook ${g_git_root}/base-services/localization.yml
f_run_playbook ${g_git_root}/base-services/hardening.yml
f_run_playbook ${g_git_root}/base-services/firewall.yml
f_run_playbook ${g_git_root}/base-services/backup.yml
f_run_playbook ${g_git_root}/base-services/autoupdate.yml
f_run_playbook ${g_git_root}/base-services/runchecks.yml
f_run_playbook ${g_git_root}/base-services/docker.yml
f_run_playbook ${g_git_root}/base-services/kvm.yml
f_run_playbook ${g_git_root}/base-services/dedyn.yml
#f_run_playbook ${g_git_root}/base-services/traefik.yml
f_run_playbook ${g_git_root}/base-services/ldap.yml
#f_run_playbook ${g_git_root}/base-services/authelia.yml

# Detect Raspberry Pi and install platform-specific playbooks
if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model
then
  f_run_playbook ${g_git_root}/base-services/raspberry.yml
  f_run_playbook ${g_git_root}/desktop/firefox.yml
fi

f_run_playbook ${g_git_root}/base-services/symbios-ui.yml

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
