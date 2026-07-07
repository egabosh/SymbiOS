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

# Install base-system playbooks
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/basics.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/hardening.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/firewall.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/backup.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/autoupdate.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/runchecks.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/docker.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/dedyn.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/acme-pki.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/traefik.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/ldap.yml
ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/authelia.yml

# Detect Raspberry Pi and install platform-specific playbooks
if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model
then
  ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/raspberry.yml
  ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/desktop/firefox.yml
fi

ansible-playbook --limit localhost  --inventory ${g_inventory} /home/SymbiOS/base-system/symbios-ui.yml
