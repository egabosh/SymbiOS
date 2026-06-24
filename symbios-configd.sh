#!/bin/bash
# SymbiOS Config Daemon
# Monitors changes to inventory.yml and runs matching playbooks

source /etc/bash/gaboshlib.include

# Global configuration
g_config_file="${1:-/home/docker/symbios-ui/config/inventory.yml}"
g_check_interval=10
g_configd_log="/home/docker/symbios-ui/log/configd.log"
g_status_file="/home/docker/symbios-ui/log/configd-status"

# Initial log entry
echo "$(date '+%Y-%m-%d %H:%M:%S') [START] SymbiOS Config Daemon started - monitoring: ${g_config_file}" >> "${g_configd_log}"
g_echo "SymbiOS Config Daemon started - monitoring: ${g_config_file}"
echo "idle" > "${g_status_file}"

# Get current config file MD5 hash
function f_get_hash {
    md5sum "${g_config_file}" 2>/dev/null | awk '{print $1}'
}

# Run an Ansible playbook with output logging and status tracking
function f_run_playbook {
    local f_playbook=$1
    local f_logfile="/home/docker/symbios-ui/log/playbook-$(basename ${f_playbook} .yml).log"
    local f_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${f_ts} [RUNNING] ${f_playbook}" >> "${g_configd_log}"
    echo "running: $(basename ${f_playbook} .yml)" > "${g_status_file}"
    g_echo "Running playbook: ${f_playbook} (log: ${f_logfile})"
    cd /home/SymbiOS
    local f_rc=0
    ansible-playbook --connection=local --inventory /home/docker/symbios-ui/config/inventory.yml \
        --limit localhost \
        -e "ansible_python_interpreter=/usr/bin/python3" \
        "${f_playbook}" > "${f_logfile}" 2>&1
    f_rc=$?
    local f_ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ $f_rc -eq 0 ]
    then
        echo "${f_ts} [OK] ${f_playbook} completed successfully" >> "${g_configd_log}"
        g_echo_ok "Playbook ${f_playbook} completed successfully"
    else
        echo "${f_ts} [FAIL] ${f_playbook} failed (exit ${f_rc})" >> "${g_configd_log}"
        g_echo_error "Playbook ${f_playbook} failed (exit ${f_rc}, log: ${f_logfile})"
    fi
    echo "idle" > "${g_status_file}"
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

        # default_domain affects acme_resolver and all services using it
        if echo "${g_new_content}" | grep -q "default_domain"
        then
            g_echo_note "default_domain changed - running all domain-dependent playbooks"
            f_run_playbook "base-system/basics.yml"
            f_run_playbook "base-system/ldap.yml"
            f_run_playbook "base-system/traefik.yml"
            f_run_playbook "base-system/authelia.yml"
            f_run_playbook "base-system/symbios-ui.yml"
        fi

        # symbios_domain change requires web UI restart
        if echo "${g_new_content}" | grep -q "symbios_domain"
        then
            f_run_playbook "base-system/symbios-ui.yml"
        fi

        # Run basics playbook on timezone/locale changes (not domain - handled above)
        if echo "${g_new_content}" | grep -q "timezone\|locale"
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
