#!/bin/bash -xe

date >>/etc/dohardening

# download playbook installer
wget https://raw.githubusercontent.com/egabosh/linux-setups/refs/heads/main/debian/install.sh -O /usr/local/sbin/linux_setups_debian_install.sh
chmod 700 /usr/local/sbin/linux_setups_debian_install.sh

# define playbooks
export PLAYBOOKS="debian/basics/basics.yml
debian/basics/hardening.yml
debian/firewall/firewall.yml
debian/runchecks/runchecks.yml
debian/backup/backup.yml
debian/autoupdate/autoupdate.yml
debian/docker/docker.yml 
debian/traefik.server/traefik.yml
debian/vnet.network/vnet.yml
debian/dedyn.client/dedyn.yml
debian/rsyslog.server/syslog-server.yml
https://raw.githubusercontent.com/egabosh/gtc-rename/refs/heads/main/gtc-rename.yml 
https://raw.githubusercontent.com/egabosh/gtc-crypt/refs/heads/main/gtc-crypt.yml
"
echo $PLAYBOOKS >/usr/local/etc/playbooks

# run
/usr/local/sbin/linux_setups_debian_install.sh


