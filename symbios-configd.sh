#!/bin/bash
# SymbiOS Config Daemon
# Überwacht Änderungen an inventory.yml und führt passende Playbooks aus

source /etc/bash/gaboshlib/g_echo.bashfunc
source /etc/bash/gaboshlib/g_echo_ok.bashfunc
source /etc/bash/gaboshlib/g_echo_error.bashfunc
source /etc/bash/gaboshlib/g_logger.bashfunc

CONFIG_FILE="${1:-/home/docker/symbios-ui/config/inventory.yml}"
CHECK_INTERVAL=10
LAST_HASH=""

g_echo "SymbiOS Config Daemon gestartet - überwache: ${CONFIG_FILE}"

get_hash() {
    md5sum "${CONFIG_FILE}" 2>/dev/null | awk '{print \$1}'
}

run_playbook() {
    local playbook=$1
    g_echo "Starte Playbook: \${playbook}"
    cd /home/SymbiOS
    local rc=0
    ansible-playbook --connection=local --inventory localhost, \
        --limit localhost \
        -e "ansible_python_interpreter=/usr/bin/python3" \
        "\${playbook}" 2>&1 | g_logger
    rc=\${PIPESTATUS[0]}
    if [ \$rc -eq 0 ]; then
        g_echo_ok "Playbook \${playbook} erfolgreich"
    else
        g_echo_error "Playbook \${playbook} fehlgeschlagen"
    fi
}

LAST_HASH=\$(get_hash)

while true; do
    CURRENT_HASH=\$(get_hash)

    if [ -n "\${LAST_HASH}" ] && [ "\${CURRENT_HASH}" != "\${LAST_HASH}" ]; then
        g_echo "Änderungen an der Konfiguration erkannt!"

        NEW_CONTENT=\$(cat "\${CONFIG_FILE}" 2>/dev/null)

        if echo "\${NEW_CONTENT}" | grep -q "default_domain\|timezone\|locale"; then
            run_playbook "base-system/basics.yml"
        fi

        if echo "\${NEW_CONTENT}" | grep -q "ldap_admin_password\|ldap_basedn"; then
            run_playbook "base-system/ldap.yml"
        fi

        if echo "\${NEW_CONTENT}" | grep -q "ddns_apikey\|ddns_host"; then
            run_playbook "base-system/ddns.yml"
        fi

        if echo "\${NEW_CONTENT}" | grep -q "smtp_server\|smtp_user\|smtp_password"; then
            run_playbook "base-system/smtp.yml"
        fi

        LAST_HASH="\${CURRENT_HASH}"
    fi

    sleep "\${CHECK_INTERVAL}"
done
