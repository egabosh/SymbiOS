#!/bin/bash
# SymbiOS Config Daemon
# Monitors changes to inventory.yml and runs matching playbooks

source /etc/bash/gaboshlib.include

# Global configuration
g_config_file="${1:-/home/docker/symbios-ui/config/inventory.yml}"
g_check_interval=10

g_echo "SymbiOS Config Daemon started - monitoring: ${g_config_file}"

# Get current config file MD5 hash
function f_get_hash {
    md5sum "${g_config_file}" 2>/dev/null | awk '{print $1}'
}

# Run an Ansible playbook with output logging
function f_run_playbook {
    local f_playbook=$1
    local f_logfile="/home/docker/symbios-ui/log/playbook-$(basename ${f_playbook} .yml).log"
    g_echo "Running playbook: ${f_playbook} (log: ${f_logfile})"
    cd /home/SymbiOS
    local f_rc=0
    ansible-playbook --connection=local --inventory /home/docker/symbios-ui/config/inventory.yml \
        --limit localhost \
        -e "ansible_python_interpreter=/usr/bin/python3" \
        "${f_playbook}" > "${f_logfile}" 2>&1
    f_rc=$?
    if [ $f_rc -eq 0 ]
    then
        g_echo_ok "Playbook ${f_playbook} completed successfully"
    else
        g_echo_error "Playbook ${f_playbook} failed (exit ${f_rc}, log: ${f_logfile})"
    fi
}

# Initial hash
g_last_hash=$(f_get_hash)

# Main monitoring loop
while true
do
    g_current_hash=$(f_get_hash)

    # Detect config changes
    if [ -n "${g_last_hash}" ] && [ "${g_current_hash}" != "${g_last_hash}" ]
    then
        g_echo "Configuration changes detected!"

        g_new_content=$(cat "${g_config_file}" 2>/dev/null)

        # Run basics playbook on domain/timezone/locale changes
        if echo "${g_new_content}" | grep -q "default_domain\|timezone\|locale"
        then
            f_run_playbook "base-system/basics.yml"
        fi

        # Run LDAP playbook on LDAP config changes
        if echo "${g_new_content}" | grep -q "ldap_admin_password\|ldap_basedn"
        then
            f_run_playbook "base-system/ldap.yml"
        fi

        # Run DDNS playbook on deSEC config changes
        if echo "${g_new_content}" | grep -q "ddns_apikey\|ddns_host"
        then
            f_run_playbook "base-system/dedyn.yml"
        fi

        # Run SMTP playbook on mail config changes
        if echo "${g_new_content}" | grep -q "smtp_server\|smtp_user\|smtp_password"
        then
            f_run_playbook "base-system/smtp.yml"
        fi

        g_last_hash="${g_current_hash}"
    fi

    # Wait before next check
    sleep "${g_check_interval}"
done
