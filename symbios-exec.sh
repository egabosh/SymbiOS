#!/bin/bash
# SymbiOS Remote Execution Gateway
# Called via SSH command= restriction from the webui container
# The original command from the client is in $SSH_ORIGINAL_COMMAND

source /etc/bash/gaboshlib.include

# Audit logging for the exec gateway: record every command and its source.
# SSH_CONNECTION = "<clientip> <clientport> <serverip> <serverport>"
f_client_ip="unknown"
if [ -n "$SSH_CONNECTION" ]; then
    f_client_ip="${SSH_CONNECTION%% *}"
fi

f_audit_log() {
    local f_msg="$1"
    logger -t symbios-exec -- "$f_msg" 2>/dev/null || true
    echo "$(date -Iseconds) client=$f_client_ip $f_msg" >> /var/log/symbios-exec.log 2>/dev/null || true
}

f_full_command="${SSH_ORIGINAL_COMMAND}"

if [ -z "$f_full_command" ]; then
    echo "interactive"
    exit 0
fi

# Parse: <action> <args...>
IFS=" " read -ra f_parts <<< "$f_full_command"
f_action="${f_parts[0]}"
f_audit_log "action=$f_action cmd=$f_full_command"

case "$f_action" in
    playbook)
        # Usage: playbook <path>
        # Only allow playbooks in base-services/ or services/ under /home/SymbiOS
        f_playbook="${f_parts[1]}"
        if [[ "$f_playbook" != "base-services/"* && "$f_playbook" != "/home/SymbiOS/services/"* && "$f_playbook" != "services/"* ]]; then
            echo "ERROR: Playbook path not allowed: $f_playbook"
            f_audit_log "BLOCKED playbook path=$f_playbook"
            g_echo_error "Blocked playbook path: $f_playbook"
            exit 1
        fi
        cd /home/SymbiOS || { echo "ERROR: Cannot cd to /home/SymbiOS"; exit 1; }
        PYTHONUNBUFFERED=1 ansible-playbook --connection=local \
            --inventory /home/docker/symbios-ui/config/inventory.yml \
            --limit localhost \
            -e "ansible_python_interpreter=/usr/bin/python3" \
            "$f_playbook"
        exit $?
        ;;
    docker-compose)
        # Usage: docker-compose <service_name> <action>
        # Allowed actions: up, down, restart, remove (down -v), ps, logs
        f_service_name="${f_parts[1]}"
        f_action_type="${f_parts[2]}"
        case "$f_action_type" in
            up|down|restart|remove|ps|logs) ;;
            *)
                echo "ERROR: Docker action not allowed: $f_action_type"
                f_audit_log "BLOCKED docker action=$f_action_type"
                g_echo_error "Blocked docker action: $f_action_type"
                exit 1
                ;;
        esac
        f_rc=0
        for f_dir in /home/docker/${f_service_name}*; do
            if [ -d "$f_dir" ]; then
                chgrp -R adm "$f_dir" 2>/dev/null || true
                chmod -R g+rX "$f_dir" 2>/dev/null || true
            fi
            if [ -f "$f_dir/docker-compose.yml" ]; then
                cd "$f_dir" || continue
                case "$f_action_type" in
                    up) docker compose up -d ;;
                    down) docker compose down ;;
                    restart) docker compose restart ;;
                    remove) docker compose down -v ;;
                    ps) docker compose ps ;;
                    logs) docker compose logs --tail=100 ;;
                esac
                f_tmp_rc=$?
                [ $f_tmp_rc -ne 0 ] && f_rc=$f_tmp_rc
            fi
        done
        exit $f_rc
        ;;
    cron)
        # Usage: cron <enable|disable|remove|status> <file>
        # Only files under /etc/cron.d are permitted.
        f_cron_file="${f_parts[2]}"
        f_cron_sub="${f_parts[1]}"
        if [[ "$f_cron_file" != /etc/cron.d/* ]]; then
            echo "ERROR: Cron file not allowed: $f_cron_file"
            f_audit_log "BLOCKED cron file=$f_cron_file"
            g_echo_error "Blocked cron file: $f_cron_file"
            exit 1
        fi
        case "$f_cron_sub" in
            enable) sed -i 's/^#//' "$f_cron_file" ;;
            disable) sed -i 's/^/#/' "$f_cron_file" ;;
            remove) rm -f "$f_cron_file" ;;
            status)
                if [ -f "$f_cron_file" ]; then
                    echo "installed"; cat "$f_cron_file"
                else
                    echo "not installed"
                fi
                ;;
            *)
                echo "ERROR: Cron subcommand not allowed: $f_cron_sub"
                f_audit_log "BLOCKED cron sub=$f_cron_sub"
                g_echo_error "Blocked cron subcommand: $f_cron_sub"
                exit 1
                ;;
        esac
        exit $?
        ;;
    ufw)
        # Usage: ufw <enable|disable|reload|status>
        f_ufw_sub="${f_parts[1]}"
        case "$f_ufw_sub" in
            enable|disable|reload|status) exec ufw "$f_ufw_sub" ;;
            *)
                echo "ERROR: ufw subcommand not allowed: $f_ufw_sub"
                f_audit_log "BLOCKED ufw sub=$f_ufw_sub"
                g_echo_error "Blocked ufw subcommand: $f_ufw_sub"
                exit 1
                ;;
        esac
        ;;
    service)
        # Usage: service list | service info <playbook>
        # Parses the machine-readable '# docs:' blocks of every playbook and
        # returns ONLY that metadata as JSON (no secrets from the repo are
        # exposed). The WebUI uses this to build its service catalog.
        f_service_sub="${f_parts[1]}"
        case "$f_service_sub" in
            list|info)
                python3 - "$f_service_sub" "${f_parts[2]}" <<'PY'
import sys, os, json, yaml
f_sub = sys.argv[1]
f_target = sys.argv[2] if len(sys.argv) > 2 else ""
f_base = "/home/SymbiOS"
f_exclude = {"traefik-static.yml", "inventory.yml"}

def parse_docs(path):
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return None
    if not lines or not lines[0].lstrip().startswith("# docs:"):
        return None
    yl = []
    for line in lines:
        if line.startswith("#"):
            yl.append(line[2:] if line.startswith("# ") else line[1:])
        else:
            break
    try:
        doc = yaml.safe_load("\n".join(yl))
        return doc.get("docs") if isinstance(doc, dict) else None
    except Exception:
        return None

results = []
for group in ("services", "base-services"):
    d = os.path.join(f_base, group)
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".yml"):
            continue
        if fn in f_exclude:
            continue
        docs = parse_docs(os.path.join(d, fn))
        if not docs:
            continue
        results.append({
            "group": group,
            "name": fn[:-4],
            "playbook": f"{group}/{fn}",
            "title": docs.get("short_description", fn[:-4]),
            "docs": docs,
        })
if f_sub == "info":
    results = [r for r in results if r["playbook"] == f_target]
print(json.dumps(results))
PY
                ;;
            logs)
                # Usage: service logs <playbook> [lines]
                # Tails the recent log of every unit managed by <playbook>
                # (docker compose logs / journalctl / cron / ufw) from the host.
                f_playbook="${f_parts[2]}"
                f_lines="${f_parts[3]:-200}"
                python3 /home/SymbiOS/symbios-logs.py "$f_playbook" "$f_lines"
                ;;
            *)
                echo "ERROR: service subcommand not allowed: $f_service_sub"
                f_audit_log "BLOCKED service sub=$f_service_sub"
                g_echo_error "Blocked service subcommand: $f_service_sub"
                exit 1
                ;;
        esac
        exit $?
        ;;
    exec)
        # Usage: exec <command...>
        # Only allow a safe subset of systemctl subcommands. Dangerous
        # operations (reboot, poweroff, isolate, set-environment, mask, ...)
        # are rejected so the forced-command key cannot be abused for them.
        case "${f_parts[1]}" in
            systemctl)
                f_sub="${f_parts[2]}"
                case "$f_sub" in
                    status|is-active|is-enabled|show|cat|list-units|start|stop|restart|reload|enable|disable)
                        exec systemctl "${f_parts[@]:2}"
                        ;;
                    *)
                        echo "ERROR: systemctl subcommand not allowed: $f_sub"
                        f_audit_log "BLOCKED systemctl subcommand=$f_sub"
                        g_echo_error "Blocked systemctl subcommand: $f_sub"
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "ERROR: Exec command not allowed: ${f_parts[1]}"
                f_audit_log "BLOCKED exec=${f_parts[1]}"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "ERROR: Unknown action: $f_action"
        f_audit_log "BLOCKED action=$f_action"
        g_echo_error "Blocked action: $f_action"
        echo "Allowed: playbook, docker-compose, exec"
        exit 1
        ;;
esac
