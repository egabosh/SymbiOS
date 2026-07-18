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

#!/bin/bash

set -e
set -x

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
  mkdir -p ${g_inventory_path}
  chmod 700 ${g_inventory_path}
  cp /home/SymbiOS/inventory.yml ${g_inventory}
  chmod 600 ${g_inventory}
fi

# Install base-services playbooks
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/basics.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/hardening.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/firewall.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/backup.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/autoupdate.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/runchecks.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/docker.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/dedyn.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/acme-pki.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/traefik.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/ldap.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/authelia.yml

# Detect Raspberry Pi and install platform-specific playbooks
if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model
then
  ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/raspberry.yml
  ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/desktop/firefox.yml
fi

ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-services/symbios-ui.yml
