#!/bin/bash

set -e
set -x

# install ansible and git
DEBIAN_FRONTEND=noninteractive apt-get -y update --allow-releaseinfo-change
which ansible >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -y install ansible git
ansible-galaxy collection install community.general

# clone SymbiOS
cd /home
[[ -d SymbiOS ]] || git clone https://github.com/egabosh/SymbiOS.git
cd SymbiOS
git pull -f

# initial inventory
if ! [[ -s /home/ansible/inventory.yml ]]
then
  mkdir -p /home/ansible
  chmod 700 /home/ansible
  cp /home/SymbiOS/inventory.yml /home/ansible/inventory.yml
  chmod 600 /home/ansible/inventory.yml
fi

# install base-system
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/basics.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/hardening.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/firewall.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/backup.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/autoupdate.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/runchecks.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/docker.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/dedyn.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/traefik.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/ldap.yml
ansible-playbook --limit localhost  --inventory /home/ansible/inventory.yml /home/SymbiOS/base-system/authelia.yml

