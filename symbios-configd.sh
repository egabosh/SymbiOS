#!/bin/bash
# SymbiOS Config Daemon
# Monitors changes to inventory.yml and runs matching playbooks
# Also watches trigger files for service management

source /etc/bash/gaboshlib.include

# Global configuration
g_config_file="${1:-/home/docker/symbios-ui/config/inventory.yml}"
g_check_interval=10
g_configd_log="/home/docker/symbios-ui/log/configd.log"
g_status_file="/home/docker/symbios-ui/log/configd-status"
G_TRIGGER_DIR="/config/triggers"

# Create trigger directory
mkdir -p "${G_TRIGGER_DIR}"

# Initial log entry
echo "$(date +%Y-%m-%d %H:%M:%S) [START] SymbiOS Config Daemon started - monitoring: ${g_config_file}" >> "${g_configd_log}"
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

# Handle trigger files from the WebUI
function f_handle_trigger {
    local f_trigger_file=$1
    local f_filename
    f_filename=$(basename "${f_trigger_file}")
    local f_action_name
    f_action_name=$(echo "${f_filename}" | cut -d- -f2)
    local f_service_name
    f_service_name=$(echo "${f_filename}" | cut -d- -f3- | sed 's/_.*//; s/\.trigger$//')

    local f_handler="/home/SymbiOS/services/service-handler.sh"

    case "${f_action_name}" in
        playbook)
            echo "$(date +%Y-%m-%d %H:%M:%S) [TRIGGER] Running playbook for ${f_service_name}" >> "/home/docker/symbios-ui/log/configd.log"
            bash "${f_handler}" playbook "${f_service_name}" &
            ;;
        start|stop)
            # Find service dir
            local f_sdir
            f_sdir=$(ls -d /home/docker/${f_service_name}.* 2>/dev/null | head -1)
            if [ -n "${f_sdir}" ]; then
                echo "$(date +%Y-%m-%d %H:%M:%S) [TRIGGER] Docker ${f_action_name} for ${f_service_name}" >> "/home/docker/symbios-ui/log/configd.log"
                bash "${f_handler}" "${f_action_name}" "${f_service_name}" "${f_sdir}" &
            fi
            ;;
    esac

    rm -f "${f_trigger_file}"
}

# Initial hash
g_last_hash=$(f_get_hash)

# Watch service files directory for new playbooks
inotifywait -m -e create -e delete /home/SymbiOS/services/ 2>/dev/null | while read path action file; do
    if echo "${file}" | grep -q "\.yml$"; then
        echo "$(date +%Y-%m-%d %H:%M:%S) [DISCOVERY] Service file change: ${path}${file}" >> "/home/docker/symbios-ui/log/configd.log"
    fi
done &

# Watch trigger directory for trigger files
inotifywait -m -e create -e delete "${G_TRIGGER_DIR}" 2>/dev/null | while read path action file; do
    if echo "${file}" | grep -q "\.trigger$"; then
        f_handle_trigger "${path}${file}"
    fi
done &

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
        if echo "${g_new_content}" | grep -q "smtp_server\|smtp_user\|smtp_password\|smtp_port\|smtp_from\|smtp_tls"
        then
            f_run_playbook "base-system/smtp.yml"
            f_run_playbook "base-system/authelia.yml"
        fi

        # Run Authelia playbook on 2FA toggle changes
        if echo "${g_new_content}" | grep -q "twofa_enabled"
        then
            f_run_playbook "base-system/authelia.yml"
        fi

        g_last_hash="${g_current_hash}"
    fi

    # Check for trigger files (every 5 seconds, fallback for inotify)
    find "${G_TRIGGER_DIR}" -name "*.trigger" -mmin -1 -type f 2>/dev/null | while read f_trigger_file; do
        f_handle_trigger "${f_trigger_file}"
    done

    # Wait before next check
    sleep "${g_check_interval}"
done
