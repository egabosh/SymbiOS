#!/bin/bash
# SymbiOS Remote Execution Gateway
# Called via SSH command= restriction from the webui container
# The original command from the client is in $SSH_ORIGINAL_COMMAND

source /etc/bash/gaboshlib.include

f_full_command="${SSH_ORIGINAL_COMMAND}"

if [ -z "$f_full_command" ]; then
    echo "interactive"
    exit 0
fi

# Parse: <action> <args...>
IFS=" " read -ra f_parts <<< "$f_full_command"
f_action="${f_parts[0]}"

case "$f_action" in
    playbook)
        # Usage: playbook <path>
        # Only allow playbooks in base-system/ or services/ under /home/SymbiOS
        f_playbook="${f_parts[1]}"
        if [[ "$f_playbook" != "base-system/"* && "$f_playbook" != "/home/SymbiOS/services/"* && "$f_playbook" != "services/"* ]]; then
            echo "ERROR: Playbook path not allowed: $f_playbook"
            g_echo_error "Blocked playbook path: $f_playbook"
            exit 1
        fi
        cd /home/SymbiOS || { echo "ERROR: Cannot cd to /home/SymbiOS"; exit 1; }
        ansible-playbook --connection=local \
            --inventory /home/docker/symbios-ui/config/inventory.yml \
            --limit localhost \
            -e "ansible_python_interpreter=/usr/bin/python3" \
            "$f_playbook"
        exit $?
        ;;
    docker-compose)
        # Usage: docker-compose <service_name> <action>
        f_service_name="${f_parts[1]}"
        f_action_type="${f_parts[2]}"
        if [ "$f_action_type" != "up" ] && [ "$f_action_type" != "down" ]; then
            echo "ERROR: Docker action not allowed: $f_action_type"
            exit 1
        fi
        f_rc=0
        for f_dir in /home/docker/${f_service_name}*; do
            if [ -d "$f_dir" ]; then
                chgrp -R adm "$f_dir" 2>/dev/null || true
                chmod -R g+rX "$f_dir" 2>/dev/null || true
            fi
            if [ -f "$f_dir/docker-compose.yml" ]; then
                cd "$f_dir" || continue
                if [ "$f_action_type" = "up" ]; then
                    docker compose up -d
                else
                    docker compose down
                fi
                f_tmp_rc=$?
                [ $f_tmp_rc -ne 0 ] && f_rc=$f_tmp_rc
            fi
        done
        exit $f_rc
        ;;
    exec)
        # Usage: exec <command...>
        # Only allow specific system commands
        shift
        case "${f_parts[1]}" in
            systemctl)
                exec systemctl "${f_parts[@]:2}"
                ;;
            *)
                echo "ERROR: Exec command not allowed: ${f_parts[1]}"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "ERROR: Unknown action: $f_action"
        g_echo_error "Blocked action: $f_action"
        echo "Allowed: playbook, docker-compose, exec"
        exit 1
        ;;
esac
