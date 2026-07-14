#!/bin/bash
# SymbiOS Remote Execution - trivial resolver + executor + audit logger.
# The webui's SSH key is a normal root key (no command= restriction): trusted
# admins operate the host. This script only translates the webui's high-level
# verbs into concrete commands and logs every invocation. No allow-lists.
# Logging uses the gaboshlib helpers (g_logger -> syslog, g_echo_error).

# Load shared bash helpers (g_echo_error, g_logger, ...).
source /etc/bash/gaboshlib.include

# Tag for syslog messages via g_logger.
g_syslogtag="symbios-exec"

# Client IP for the audit trail (from the SSH connection metadata).
g_client_ip="unknown"
if [ -n "$SSH_CONNECTION" ]
then
    g_client_ip="${SSH_CONNECTION%% *}"
fi

# Build the command tokens (forced command or explicit arguments).
set -f
set -- ${SSH_ORIGINAL_COMMAND:-$*}
set +f

# Nothing to do -> interactive shell was requested.
if [ -z "$1" ]
then
    echo "interactive"
    exit 0
fi

# Audit every invocation: syslog (gaboshlib) and a local log file.
g_logger "client=${g_client_ip} action=$1 cmd=$*"
echo "$(date -Iseconds) client=${g_client_ip} action=$1 cmd=$*" >> /var/log/symbios-exec.log 2>/dev/null || true

# Dispatch on the leading verb.
case "$1" in
    # Run an ansible playbook from the SymbiOS tree.
    playbook)
        cd /home/SymbiOS || exit 1
        PYTHONUNBUFFERED=1 ansible-playbook --connection=local \
            --inventory /home/docker/symbios-ui/config/inventory.yml \
            --limit localhost \
            -e "ansible_python_interpreter=/usr/bin/python3" \
            "/home/SymbiOS/$2"
        ;;
    # docker-compose <name> <action> on every /home/docker/<name>* directory.
    docker-compose)
        for g_dir in /home/docker/$2*
        do
            if [ ! -d "$g_dir" ]
            then
                continue
            fi
            chgrp -R adm "$g_dir" 2>/dev/null || true
            chmod -R g+rX "$g_dir" 2>/dev/null || true
            if [ -f "$g_dir/docker-compose.yml" ]
            then
                ( cd "$g_dir" && docker compose "$3" )
            fi
        done
        ;;
    # cron <sub> <file> - manage the given cron file directly.
    cron)
        case "$2" in
            enable) sed -i 's/^#//' "$3" ;;
            disable) sed -i 's/^/#/' "$3" ;;
            remove) rm -f "$3" ;;
            status)
                if [ -f "$3" ]
                then
                    echo "installed"
                    cat "$3"
                else
                    echo "not installed"
                fi
                ;;
            *) g_echo_error "Unknown cron subcommand: $2"; exit 1 ;;
        esac
        ;;
    # ufw <sub> - run the requested firewall subcommand.
    ufw)
        exec ufw "$2"
        ;;
    # exec systemctl <sub> ... - run the requested systemctl command.
    exec)
        if [ "$2" != "systemctl" ]
        then
            g_echo_error "Unsupported exec tool: $2"
            exit 1
        fi
        exec systemctl "${@:3}"
        ;;
    # service <sub> ... - metadata / log / action dispatch from playbook docs.
    service)
        case "$2" in
            # list|info - machine-readable service catalog from docs.
            list|info)
                python3 - "$2" "$3" <<'PY'
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
            # logs <playbook> [lines] - recent log of every managed unit.
            logs)
                python3 /home/SymbiOS/symbios-logs.py "$3" "${4:-200}"
                ;;
            # logfollow <playbook> <unit> - stream one named log forever.
            logfollow)
                if [ -z "$4" ]
                then
                    g_echo_error "missing log unit name"
                    exit 1
                fi
                python3 /home/SymbiOS/symbios-logs.py --follow "$3" "$4"
                ;;
            # source <playbook> - print the raw playbook (read-only).
            source)
                if [ ! -f "/home/SymbiOS/$3" ]
                then
                    g_echo_error "Playbook not found: $3"
                    exit 1
                fi
                cat "/home/SymbiOS/$3"
                ;;
            # run <playbook> <action> - run a pre-declared action command.
            run)
                if [ -z "$4" ]
                then
                    g_echo_error "missing action"
                    exit 1
                fi
                if [ ! -f "/home/SymbiOS/$3" ]
                then
                    g_echo_error "Playbook not found: $3"
                    exit 1
                fi
                g_cmd="$(python3 - "/home/SymbiOS/$3" "$4" <<'PY'
import sys, yaml
f_path, f_action = sys.argv[1], sys.argv[2]
try:
    lines = open(f_path).read().splitlines()
except Exception:
    sys.exit(0)
if not lines or not lines[0].lstrip().startswith("# docs:"):
    sys.exit(0)
yl = []
for line in lines:
    if line.startswith("#"):
        yl.append(line[2:] if line.startswith("# ") else line[1:])
    else:
        break
try:
    doc = yaml.safe_load("\n".join(yl))
except Exception:
    sys.exit(0)
docs = doc.get("docs") if isinstance(doc, dict) else None
if not docs:
    sys.exit(0)
actions = docs.get("actions") or {}
if f_action not in actions:
    sys.stderr.write("ERROR: action not defined in playbook: %s\n" % f_action)
    sys.exit(2)
print(actions[f_action])
PY
)"
                if [ -z "$g_cmd" ]
                then
                    g_echo_error "no command for action $4"
                    exit 1
                fi
                bash -c "$g_cmd"
                ;;
            # status <playbook> <name> - run the pre-declared status command.
            status)
                if [ -z "$4" ]
                then
                    g_echo_error "missing service name"
                    exit 1
                fi
                if [ ! -f "/home/SymbiOS/$3" ]
                then
                    g_echo_error "Playbook not found: $3"
                    exit 1
                fi
                g_cmd="$(python3 - "/home/SymbiOS/$3" "$4" <<'PY'
import sys, yaml
f_path, f_name = sys.argv[1], sys.argv[2]
try:
    lines = open(f_path).read().splitlines()
except Exception:
    sys.exit(0)
if not lines or not lines[0].lstrip().startswith("# docs:"):
    sys.exit(0)
yl = []
for line in lines:
    if line.startswith("#"):
        yl.append(line[2:] if line.startswith("# ") else line[1:])
    else:
        break
try:
    doc = yaml.safe_load("\n".join(yl))
except Exception:
    sys.exit(0)
docs = doc.get("docs") if isinstance(doc, dict) else None
services = (docs or {}).get("service_control", {}).get("services", []) or []
for s in services:
    if s.get("name") == f_name:
        c = s.get("status")
        if c:
            print(c)
        sys.exit(0)
sys.stderr.write("ERROR: status not defined for %s\n" % f_name)
sys.exit(2)
PY
)"
                if [ -z "$g_cmd" ]
                then
                    g_echo_error "no status command for $4"
                    exit 1
                fi
                bash -c "$g_cmd"
                ;;
            *) g_echo_error "Unknown service subcommand: $2"; exit 1 ;;
        esac
        ;;
    *) g_echo_error "Unknown action: $1"
      echo "Allowed: playbook, docker-compose, cron, ufw, service, exec"
      exit 1
      ;;
esac
