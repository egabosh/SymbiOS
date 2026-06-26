#!/bin/bash
# SymbiOS Service Handler
# Handles playbook and docker compose actions for managed services
# Usage: service-handler.sh <action> <service_name> [service_dir]
# Actions: playbook, start, stop

source /etc/bash/gaboshlib.include

SYMBIOS_DIR="/home/SymbiOS"
SERVICES_DIR="/home/SymbiOS/services"
LOG_DIR="/home/docker/symbios-ui/log"
STATUS_FILE="/home/docker/symbios-ui/log/configd-status"

handle_playbook() {
    local f_service_name=$1
    local f_playbook="${SERVICES_DIR}/${f_service_name}.yml"
    local f_log_file="${LOG_DIR}/service-${f_service_name}.log"

    if [ ! -f "$f_playbook" ]; then
        echo "ERROR: Playbook not found: $f_playbook"
        return 1
    fi

    echo "running: ${f_service_name}" > "$STATUS_FILE"
    # Ensure service dir is readable by symbios container
    local f_svc_dir
    f_svc_dir=$(ls -d /home/docker/${f_service_name}* 2>/dev/null | head -1)
    if [ -n "$f_svc_dir" ]; then
        chgrp -R adm "$f_svc_dir" 2>/dev/null || true
        chmod -R g+rX "$f_svc_dir" 2>/dev/null || true
    fi
    echo "=== Playbook run for ${f_service_name} at $(date) ===" > "$f_log_file"

    cd "$SYMBIOS_DIR"
    ansible-playbook --connection=local \
        --inventory /home/docker/symbios-ui/config/inventory.yml \
        --limit localhost \
        -e "ansible_python_interpreter=/usr/bin/python3" \
        "$f_playbook" >> "$f_log_file" 2>&1

    local f_rc=$?
    if [ $f_rc -eq 0 ]; then
        echo "OK: Service ${f_service_name} playbook completed successfully" >> "$f_log_file"
        echo "idle" > "$STATUS_FILE"
    else
        echo "FAIL: Service ${f_service_name} playbook failed (exit $f_rc)" >> "$f_log_file"
        echo "idle" > "$STATUS_FILE"
    fi
    return $f_rc
}

handle_docker() {
    local f_action=$1
    local f_service_dir=$2
    local f_service_name
    f_service_name=$(basename "$(dirname "$f_service_dir")")
    local f_log_file="${LOG_DIR}/service-${f_service_name}.log"
chgrp -R adm "$f_service_dir" 2>/dev/null || true
    chmod -R g+rX "$f_service_dir" 2>/dev/null || true

    if [ ! -d "$f_service_dir" ] || [ ! -f "$f_service_dir/docker-compose.yml" ]; then
        echo "ERROR: Docker Compose not found in $f_service_dir"
        return 1
    fi

    echo "=== Docker $f_action for ${f_service_name} at $(date) ===" >> "$f_log_file"
    
    
    cd "$f_service_dir"
    docker compose "$f_action" >> "$f_log_file" 2>&1
    local f_rc=$?
    if [ $f_rc -eq 0 ]; then
        echo "OK: Docker $f_action for ${f_service_name}" >> "$f_log_file"
    else
        echo "FAIL: Docker $f_action for ${f_service_name}" >> "$f_log_file"
    fi
    return $f_rc
}

case "$1" in
    playbook) handle_playbook "$2" ;;
    start) handle_docker "up -d" "$3" ;;
    stop) handle_docker "down" "$3" ;;
    *) echo "Usage: $0 {playbook|start|stop} <service_name> [service_dir]" ;;
esac
