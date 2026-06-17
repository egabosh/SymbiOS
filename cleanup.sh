#!/bin/bash
# SymbiOS Cleanup / Uninstall Script
# Removes all changes made by SymbiOS Ansible playbooks.
# apt packages are kept installed.
set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_del()  { echo -e "${RED}[DEL]${NC} $1"; }

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
read -p "Continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

echo "--- Docker Containers ---"
for ct in $(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -iE "symbios|ldap|traefik|acme-pki|authelia"); do
    docker rm -f "$ct" >/dev/null 2>&1 && log_del "Container: $ct" || true
done

echo ""
echo "--- Docker Networks ---"
for net in traefik; do
    if docker network ls --format "{{.Name}}" | grep -q "^${net}$"; then
        docker network rm "$net" 2>/dev/null && log_del "Network: $net" || log_warn "Could not remove: $net"
    fi
done

echo ""
echo "--- Docker Volumes ---"
for vol in $(docker volume ls -q 2>/dev/null | grep -iE "symbios|step|pebble"); do
    docker volume rm "$vol" 2>/dev/null && log_del "Volume: $vol" || true
done

echo ""
echo "--- Filesystem ---"
for d in /home/docker /home/ansible /home/SymbiOS; do
    if [ -d "$d" ]; then
        rm -rf "$d" && log_del "$d" || log_warn "Could not remove $d"
    fi
done

echo ""
echo "--- CA Certificates ---"
for cert in /usr/share/ca-certificates/symbios-pki-ca.crt \
            /usr/share/ca-certificates/symbios-pki-intermediate-ca.crt \
            /usr/share/ca-certificates/symbios-pebble-ca.crt \
            /usr/local/share/ca-certificates/symbios-pki-ca.crt; do
    [ -f "$cert" ] && rm -f "$cert" && log_del "$cert" || true
done

if [ -f /etc/ca-certificates.conf ]; then
    sed -i "/symbios/d" /etc/ca-certificates.conf && log_del "Cleaned /etc/ca-certificates.conf" || true
fi

for link in /etc/ssl/certs/symbios-pki-ca.pem \
            /etc/ssl/certs/symbios-pki-intermediate-ca.pem \
            /etc/ssl/certs/symbios-pebble-ca.pem \
            /etc/ssl/certs/pebble-ca.pem; do
    [ -L "$link" ] && rm -f "$link" && log_del "$link" || true
done

command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates --fresh >/dev/null 2>&1 && log_ok "Rebuilt CA trust store"

echo ""
echo "--- Playbook Files ---"
for f in /etc/logrotate.d/traefik \
         /etc/cron.d/traefik-qualys-ssl-labs-check_local \
         /usr/local/sbin/traefik-qualys-ssl-labs-check.sh \
         /usr/local/sbin/runchecks.d/traefik.check \
         /usr/local/sbin/backup.d/ldap-docker.backup \
         /usr/local/bin/symbios-ldapsearch \
         /etc/nslcd.conf \
         /etc/ldap/ldap.conf \
         /etc/ldapscripts/ldapscripts.conf \
         /etc/ldapscripts/ldapscripts.passwd; do
    [ -e "$f" ] && rm -rf "$f" && log_del "$f" || true
done

if [ -d /tmp/lam-temp ]; then
    rm -rf /tmp/lam-temp && log_del "/tmp/lam-temp" || true
fi

echo ""
echo "============================================"
echo "  Cleanup complete!"
echo "============================================"
echo ""
echo "apt packages kept. Docker images kept."
echo "To reinstall: /root/SymbiOS/install.sh"
echo ""
