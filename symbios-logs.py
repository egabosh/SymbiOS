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


def follow_log(entry):
    """Stream a single named log command forever (tail -f style).

    The command itself is responsible for following (docker compose logs -f,
    journalctl -f, tail -F, ...); we just exec it with inherited stdout/stderr
    so its output streams straight back to the caller (e.g. the WebUI's live
    log viewer). Returns the process exit code.
    """
    name = entry.get("name")
    cmd = entry.get("command")
    if not cmd:
        sys.stderr.write("no command for log " + str(name) + "\n")
        return 1
    # Inherit stdout/stderr so the follow output reaches the SSH channel.
    proc = subprocess.Popen(["bash", "-c", cmd])
    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        return 1


def main():
    args = sys.argv[1:]
    # Follow mode: stream ONE named log unit continuously (no JSON wrapping).
    if args and args[0] == "--follow":
        if len(args) < 3:
            sys.stderr.write("usage: symbios-logs.py --follow <playbook> <name>\n")
            sys.exit(2)
        main_follow(args[1], args[2])
        return
    if len(args) < 1:
        print(json.dumps({"error": "missing playbook argument"}))
        return
    playbook = args[0]
    try:
        n = max(1, min(int(args[1]), 500)) if len(args) > 1 else 200
    except Exception:
        n = 200
    path = os.path.join(F_BASE, playbook)
    docs = parse_docs(path)
    units = []
    if docs:
        for entry in docs.get("service_control", {}).get("logs", []) or []:
            units.append(tail_log(entry, n))
    print(json.dumps({"units": units}))


def main_follow(playbook, name):
    # Guard against path traversal: only allow simple playbook paths under F_BASE.
    if not playbook.endswith(".yml") or ".." in playbook or "/" not in playbook:
        sys.stderr.write("invalid playbook path: " + str(playbook) + "\n")
        sys.exit(2)
    path = os.path.join(F_BASE, playbook)
    docs = parse_docs(path)
    if not docs:
        sys.stderr.write("no docs for playbook: " + str(playbook) + "\n")
        sys.exit(1)
    for entry in docs.get("service_control", {}).get("logs", []) or []:
        if entry.get("name") == name:
            sys.exit(follow_log(entry))
    sys.stderr.write("log unit not found: " + str(name) + "\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
