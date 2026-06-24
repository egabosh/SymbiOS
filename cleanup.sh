#!/bin/bash
# SymbiOS Cleanup / Uninstall Script
# Removes all changes made by SymbiOS Ansible playbooks.
# apt packages are kept installed.

set -e

# Color definitions for output
g_red="\033[0;31m"
g_green="\033[0;32m"
g_yellow="\033[1;33m"
g_nc="\033[0m"

# Logging helper functions
function f_log_ok   { echo -e "${g_green}[OK]${g_nc} $1"; }
function f_log_warn { echo -e "${g_yellow}[WARN]${g_nc} $1"; }
function f_log_del  { echo -e "${g_red}[DEL]${g_nc} $1"; }

echo "============================================"
echo "  SymbiOS Cleanup Script"
echo "============================================"
echo ""
echo "This will remove:"
echo "  - All SymbiOS Docker containers"
echo "  - /home/docker, /home/ansible, /home/SymbiOS"
echo "  - All files created by SymbiOS playbooks"
echo "  - CA certificates installed by SymbiOS"
echo ""

read -p "Continue? (y/N): " g_confirm
if [[ "$g_confirm" != "y" && "$g_confirm" != "Y" ]]
then
    echo "Aborted."
    exit 0
fi
echo ""

# Remove all SymbiOS-related Docker containers
echo "--- Docker Containers ---"
for g_ct in $(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -iE "symbios|ldap|traefik|acme-pki|authelia")
do
    docker rm -f "$g_ct" >/dev/null 2>&1 && f_log_del "Container: $g_ct" || true
done

# Remove Docker networks created by SymbiOS
echo ""
echo "--- Docker Networks ---"
for g_net in traefik
do
    if docker network ls --format "{{.Name}}" | grep -q "^${g_net}$"
    then
        docker network rm "$g_net" 2>/dev/null && f_log_del "Network: $g_net" || f_log_warn "Could not remove: $g_net"
    fi
done

# Remove Docker volumes created by SymbiOS
echo ""
echo "--- Docker Volumes ---"
for g_vol in $(docker volume ls -q 2>/dev/null | grep -iE "symbios|step|pebble")
do
    docker volume rm "$g_vol" 2>/dev/null && f_log_del "Volume: $g_vol" || true
done

# Remove SymbiOS filesystem directories
echo ""
echo "--- Filesystem ---"
for g_d in /home/docker /home/ansible /home/SymbiOS
do
    if [ -d "$g_d" ]
    then
        rm -rf "$g_d" && f_log_del "$g_d" || f_log_warn "Could not remove $g_d"
    fi
done

# Remove installed CA certificates
echo ""
echo "--- CA Certificates ---"
for g_cert in /usr/share/ca-certificates/symbios-pki-ca.crt \
              /usr/share/ca-certificates/symbios-pki-intermediate-ca.crt \
              /usr/share/ca-certificates/symbios-pebble-ca.crt \
              /usr/local/share/ca-certificates/symbios-pki-ca.crt
do
    if [ -f "$g_cert" ]
    then
        rm -f "$g_cert" && f_log_del "$g_cert" || true
    fi
done

# Clean ca-certificates config
if [ -f /etc/ca-certificates.conf ]
then
    sed -i "/symbios/d" /etc/ca-certificates.conf && f_log_del "Cleaned /etc/ca-certificates.conf" || true
fi

# Remove CA symlinks
for g_link in /etc/ssl/certs/symbios-pki-ca.pem \
              /etc/ssl/certs/symbios-pki-intermediate-ca.pem \
              /etc/ssl/certs/symbios-pebble-ca.pem \
              /etc/ssl/certs/pebble-ca.pem
do
    if [ -L "$g_link" ]
    then
        rm -f "$g_link" && f_log_del "$g_link" || true
    fi
done

# Rebuild CA trust store
command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates --fresh >/dev/null 2>&1 && f_log_ok "Rebuilt CA trust store"

# Remove SymbiOS playbook-related files
echo ""
echo "--- Playbook Files ---"
for g_f in /etc/logrotate.d/traefik \
           /etc/cron.d/traefik-qualys-ssl-labs-check_local \
           /usr/local/sbin/traefik-qualys-ssl-labs-check.sh \
           /usr/local/sbin/runchecks.d/traefik.check \
           /usr/local/sbin/backup.d/ldap-docker.backup \
           /usr/local/bin/symbios-ldapsearch \
           /etc/nslcd.conf \
           /etc/ldap/ldap.conf \
           /etc/ldapscripts/ldapscripts.conf \
           /etc/ldapscripts/ldapscripts.passwd
do
    if [ -e "$g_f" ]
    then
        rm -rf "$g_f" && f_log_del "$g_f" || true
    fi
done

# Remove LAM temp directory
if [ -d /tmp/lam-temp ]
then
    rm -rf /tmp/lam-temp && f_log_del "/tmp/lam-temp" || true
fi

echo ""
echo "============================================"
echo "  Cleanup complete!"
echo "============================================"
echo ""
echo "apt packages kept. Docker images kept."
echo "To reinstall: /root/SymbiOS/install.sh"
echo ""
