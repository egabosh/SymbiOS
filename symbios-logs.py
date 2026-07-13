#!/usr/bin/env python3
"""Fetch the recent logs of every unit managed by a SymbiOS playbook.

Called by symbios-exec.sh as:  symbios-logs.py <playbook> [lines]

Reads the playbook's machine-readable '# docs:' block (no secrets), then tails
the log source of each managed unit:
  - docker:  docker compose logs --no-color --tail <n>
  - systemd: journalctl -n <n> -u <unit> --no-pager --no-hostname
  - cron:    tail -n <n> of the cron file
  - ufw:     ufw status verbose

Prints a single JSON object: {"units": [{"name", "type", "lines": [...]}]}.
"""
import sys
import os
import json
import yaml
import subprocess
import glob

F_BASE = "/home/SymbiOS"
F_EXCLUDE = {"traefik-static.yml", "inventory.yml"}


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


def compose_base(compose_file):
    directory = (compose_file or "").replace("/home/docker/", "").rstrip("/")
    if directory.endswith("/docker-compose.yml"):
        directory = directory[: -len("/docker-compose.yml")]
    directory = directory.split("/")[-1]
    return directory.replace(".{{ inventory_hostname }}", "")


def tail_unit(svc, n):
    t = svc.get("type")
    name = svc.get("name")
    out = ""
    try:
        if t == "docker":
            base = compose_base(svc.get("compose_file"))
            for d in glob.glob("/home/docker/" + base + "*"):
                cf = os.path.join(d, "docker-compose.yml")
                if os.path.isfile(cf):
                    r = subprocess.run(
                        ["docker", "compose", "-f", cf, "logs", "--no-color",
                         "--tail", str(n)],
                        capture_output=True, text=True, timeout=60)
                    out += r.stdout + r.stderr
        elif t == "systemd":
            unit = svc.get("unit")
            if unit:
                r = subprocess.run(
                    ["journalctl", "-n", str(n), "-u", unit,
                     "--no-pager", "--no-hostname"],
                    capture_output=True, text=True, timeout=60)
                out += r.stdout + r.stderr
        elif t == "cron":
            f = svc.get("file")
            if f and os.path.isfile(f):
                r = subprocess.run(["tail", "-n", str(n), f],
                                   capture_output=True, text=True, timeout=60)
                out += r.stdout + r.stderr
            else:
                out = "no cron file at " + str(f)
        elif t == "ufw":
            r = subprocess.run(["ufw", "status", "verbose"],
                               capture_output=True, text=True, timeout=60)
            out += r.stdout + r.stderr
    except Exception as e:
        out += "\n[error] " + str(e)
    return {"name": name, "type": t, "lines": out.splitlines()}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "missing playbook argument"}))
        return
    playbook = sys.argv[1]
    try:
        n = max(1, min(int(sys.argv[2]), 500)) if len(sys.argv) > 2 else 200
    except Exception:
        n = 200
    path = os.path.join(F_BASE, playbook)
    docs = parse_docs(path)
    units = []
    if docs:
        for s in docs.get("service_control", {}).get("services", []):
            units.append(tail_unit(s, n))
    print(json.dumps({"units": units}))


if __name__ == "__main__":
    main()
