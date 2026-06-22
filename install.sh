#!/bin/bash

set -e
set -x

# install ansible and git
if ! which ansible >/dev/null 2>&1
then
  DEBIAN_FRONTEND=noninteractive apt-get -y update --allow-releaseinfo-change
  DEBIAN_FRONTEND=noninteractive apt-get -y install ansible git
  ansible-galaxy collection install community.general
fi

if ip a | grep -q 172.23.0.226
then
# use dev-dir
  rm -rf /home/SymbiOS
  cp -rp /root/SymbiOS /home
  rm -f ${inventory}
else
# clone SymbiOS
  cd /home
  [[ -d SymbiOS ]] || git clone https://github.com/egabosh/SymbiOS.git
  cd SymbiOS
  if ! git pull
  then
    git stash
    git pull
  fi
fi

# initial inventory
inventory_path="/home/docker/symbios-ui/config"
inventory="${inventory_path}/inventory.yml"
if ! [[ -s ${inventory} ]]
then
  mkdir -p ${inventory_path}
  chmod 700 ${inventory_path}
  cp /home/SymbiOS/inventory.yml ${inventory}
  chmod 600 ${inventory}
fi

# install base-system
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/basics.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/hardening.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/firewall.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/backup.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/autoupdate.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/runchecks.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/docker.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/dedyn.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/acme-pki.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/traefik.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/ldap.yml
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/authelia.yml
if [ -f /proc/device-tree/model ] && grep -qi "raspberry" /proc/device-tree/model
then
  # on raspi
  ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/raspberry.yml
  ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/desktop/firefox.yml
fi
ansible-playbook --limit localhost  --inventory ${inventory} /home/SymbiOS/base-system/symbios-ui.yml


