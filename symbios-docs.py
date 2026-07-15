#!/usr/bin/env python3
"""SymbiOS host command dispatcher.

Thin companion to symbios-exec.sh: the shell script only logs the invocation
and hands the whole command to this tool, which knows every verb:

  playbook <path>
  docker-compose <name> <action>
  cron <enable|disable|remove|status> <file>
  ufw <sub>
  exec systemctl <sub> ...
  service <list|info|logs|logfollow|source|run|status> ...

Output is streamed to stdout/stderr and the process exit code reflects the
wrapped command's exit code, so the SSH channel can capture or stream it.
"""
import sys
import os
import json
import glob
import subprocess
import yaml

BASE = "/home/SymbiOS"
EXCLUDE = {"traefik-static.yml", "inventory.yml"}
LOGS_HELPER = os.path.join(BASE, "symbios-logs.py")


def log_err(msg):
    """Write an error to stderr and to syslog."""
    sys.stderr.write("ERROR: %s\n" % msg)
    try:
        subprocess.run(["logger", "-t", "symbios-exec", "ERROR: " + msg],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def parse_docs(path):
    """Return the 'docs:' mapping from a playbook's leading comment block."""
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return None
    if not lines or not lines[0].lstrip().startswith("# docs:"):
        return None
    yaml_lines = []
    for line in lines:
        if not line.startswith("#"):
            break
        yaml_lines.append(line[2:] if line.startswith("# ") else line[1:])
    try:
        doc = yaml.safe_load("\n".join(yaml_lines))
    except Exception:
        return None
    return doc.get("docs") if isinstance(doc, dict) else None


def cmd_catalog(sub, target=""):
    """Build the machine-readable service catalog (or one entry) as JSON."""
    results = []
    for group in ("services", "base-services"):
        d = os.path.join(BASE, group)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".yml") or fn in EXCLUDE:
                continue
            docs = parse_docs(os.path.join(d, fn))
            if not docs:
                continue
            results.append({
                "group": group,
                "name": fn[:-4],
                "playbook": "%s/%s" % (group, fn),
                "title": docs.get("short_description", fn[:-4]),
                "docs": docs,
            })
    if sub == "info":
        results = [r for r in results if r["playbook"] == target]
    print(json.dumps(results))


def resolve_action(path, action):
    """Return the command declared under docs.actions.<action>, or None."""
    docs = parse_docs(path)
    if not docs:
        return None
    actions = docs.get("actions") or {}
    if action not in actions:
        return None
    return actions[action]


def resolve_status(path, name):
    """Return the status command for <name>, or None if not declared."""
    docs = parse_docs(path)
    services = (docs or {}).get("service_control", {}).get("services", []) or []
    for s in services:
        if s.get("name") == name:
            return s.get("status")
    return None


def run_playbook(path):
    os.chdir(BASE)
    rc = subprocess.run([
        "ansible-playbook", "--connection=local",
        "--inventory", "/home/docker/symbios-ui/config/inventory.yml",
        "--limit", "localhost",
        "-e", "ansible_python_interpreter=/usr/bin/python3",
        os.path.join(BASE, path),
    ]).returncode
    sys.exit(rc)


def run_docker_compose(name, action):
    rc = 0
    for d in sorted(glob.glob("/home/docker/%s*" % name)):
        if not os.path.isdir(d):
            continue
        subprocess.run(["chgrp", "-R", "adm", d],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["chmod", "-R", "g+rX", d],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.isfile(os.path.join(d, "docker-compose.yml")):
            rc = subprocess.run(["docker", "compose", action], cwd=d).returncode or rc
    sys.exit(rc)


def run_cron(sub, file):
    if sub == "enable":
        subprocess.run(["sed", "-i", "s/^#//", file])
    elif sub == "disable":
        subprocess.run(["sed", "-i", "s/^/#/", file])
    elif sub == "remove":
        try:
            os.remove(file)
        except OSError as e:
            log_err(str(e))
            sys.exit(1)
    elif sub == "status":
        if os.path.isfile(file):
            print("installed")
            sys.stdout.write(open(file).read())
        else:
            print("not installed")
    else:
        log_err("Unknown cron subcommand: %s" % sub)
        sys.exit(1)


def run_ufw(sub):
    sys.exit(subprocess.run(["ufw", sub]).returncode)


def run_exec(tool, rest):
    if tool != "systemctl":
        log_err("Unsupported exec tool: %s" % tool)
        sys.exit(1)
    sys.exit(subprocess.run(["systemctl"] + rest).returncode)


def run_service(args):
    sub = args[0] if len(args) > 0 else ""
    if sub in ("list", "info"):
        target = args[1] if len(args) > 1 else ""
        cmd_catalog(sub, target)
    elif sub == "logs":
        playbook = args[1] if len(args) > 1 else ""
        lines = args[2] if len(args) > 2 else "200"
        sys.exit(subprocess.run([sys.executable, LOGS_HELPER, playbook, lines]).returncode)
    elif sub == "logfollow":
        if len(args) < 3:
            log_err("missing log unit name")
            sys.exit(1)
        sys.exit(subprocess.run(
            [sys.executable, LOGS_HELPER, "--follow", args[1], args[2]]).returncode)
    elif sub == "source":
        if len(args) < 2:
            log_err("missing playbook")
            sys.exit(1)
        path = os.path.join(BASE, args[1])
        if not os.path.isfile(path):
            log_err("Playbook not found: %s" % args[1])
            sys.exit(1)
        sys.stdout.write(open(path).read())
    elif sub == "run":
        if len(args) < 3:
            log_err("missing action")
            sys.exit(1)
        path = os.path.join(BASE, args[1])
        if not os.path.isfile(path):
            log_err("Playbook not found: %s" % args[1])
            sys.exit(1)
        cmd = resolve_action(path, args[2])
        if not cmd:
            log_err("no command for action %s" % args[2])
            sys.exit(1)
        sys.exit(subprocess.run(["bash", "-c", cmd]).returncode)
    elif sub == "status":
        if len(args) < 3:
            log_err("missing service name")
            sys.exit(1)
        path = os.path.join(BASE, args[1])
        if not os.path.isfile(path):
            log_err("Playbook not found: %s" % args[1])
            sys.exit(1)
        cmd = resolve_status(path, args[2])
        if not cmd:
            log_err("no status command for %s" % args[2])
            sys.exit(1)
        sys.exit(subprocess.run(["bash", "-c", cmd]).returncode)
    else:
        log_err("Unknown service subcommand: %s" % sub)
        sys.exit(1)


def dispatch(argv):
    if not argv:
        log_err("empty command")
        sys.exit(1)
    verb = argv[0]
    rest = argv[1:]
    if verb == "playbook":
        if not rest:
            log_err("missing playbook")
            sys.exit(1)
        run_playbook(rest[0])
    elif verb == "docker-compose":
        if len(rest) < 2:
            log_err("usage: docker-compose <name> <action>")
            sys.exit(1)
        run_docker_compose(rest[0], rest[1])
    elif verb == "cron":
        if len(rest) < 2:
            log_err("usage: cron <sub> <file>")
            sys.exit(1)
        run_cron(rest[0], rest[1])
    elif verb == "ufw":
        if not rest:
            log_err("missing ufw subcommand")
            sys.exit(1)
        run_ufw(rest[0])
    elif verb == "exec":
        if not rest:
            log_err("missing exec tool")
            sys.exit(1)
        run_exec(rest[0], rest[1:])
    elif verb == "service":
        run_service(rest)
    else:
        log_err("Unknown action: %s" % verb)
        sys.stderr.write("Allowed: playbook, docker-compose, cron, ufw, service, exec\n")
        sys.exit(1)


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "run":
        sys.stderr.write("usage: symbios-docs.py run <verb> [args...]\n")
        sys.exit(2)
    dispatch(sys.argv[2:])


if __name__ == "__main__":
    main()
