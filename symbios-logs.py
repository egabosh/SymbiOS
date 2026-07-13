#!/usr/bin/env python3
"""Fetch the recent logs of every unit managed by a SymbiOS playbook.

Called by symbios-exec.sh as:  symbios-logs.py <playbook> [lines]

Reads the playbook's machine-readable '# docs:' block (no secrets), then runs
each command from the named `service_control.logs` list and captures its output
(arbitrary commands are supported: docker compose logs, journalctl, grep, ...).

Prints a single JSON object: {"units": [{"name", "type", "lines": [...]}]}.
"""
import sys
import os
import json
import yaml
import subprocess

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


def tail_log(entry, n):
    """Run one named log command and return its (capped) output lines."""
    name = entry.get("name")
    cmd = entry.get("command")
    out = ""
    if not cmd:
        out = "no command for log " + str(name)
    else:
        try:
            r = subprocess.run(["bash", "-c", cmd],
                                capture_output=True, text=True, timeout=60)
            out = (r.stdout or "") + (r.stderr or "")
        except Exception as e:
            out = "\n[error] " + str(e)
    lines = out.splitlines()
    if len(lines) > n:
        lines = lines[-n:]
    return {"name": name, "type": entry.get("type", "log"), "lines": lines}


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
        for entry in docs.get("service_control", {}).get("logs", []) or []:
            units.append(tail_log(entry, n))
    print(json.dumps({"units": units}))


if __name__ == "__main__":
    main()
