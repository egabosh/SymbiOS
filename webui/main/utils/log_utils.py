# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
Log utility functions for secure log file access and streaming.
Supports system logs and Docker container logs.
"""
import os
import json
from django.http import JsonResponse, HttpResponseBadRequest

LOG_BASE_DIR = "/var/log"
DOCKER_LOG_BASE = "/docker/containers"
CONTAINER_INDEX = "/log/docker-containers.tsv"

ALLOWED_LOG_FILES = {
    "messages": "/var/log/messages",
    "syslog": "/var/log/syslog",
    "reapply": "/home/docker/symbios-ui/log/reapply.log",
    "dedyn": "/log/dedyn.log",
        "playbook-basics": "/log/playbook-basics.log",
    "playbook-symbios-ui": "/log/playbook-symbios-ui.log",
    "playbook-traefik": "/log/playbook-traefik.log",
    "playbook-dedyn": "/log/playbook-dedyn.log",
    "playbook-smtp": "/log/playbook-smtp.log",
    "playbook-authelia": "/log/playbook-authelia.log",
    "playbook-ldap": "/log/playbook-ldap.log",
    "health": "/log/system-health.json",
    "runchecks": "/log/runchecks-results.json",
    "docker": "/var/log/docker.log",
    "auth": "/var/log/auth.log",
    "cron": "/var/log/cron.log",
    "ansible": "/var/log/ansible.log",
}

LOG_LABELS = {
    "messages": "System Messages",
    "syslog": "Syslog",
    "reapply": "Reapply Output",
    "dedyn": "DDNS (deSEC)",
        "playbook-basics": "Playbook: Basics",
    "playbook-symbios-ui": "Playbook: WebUI",
    "playbook-traefik": "Playbook: Traefik",
    "playbook-dedyn": "Playbook: DDNS",
    "playbook-smtp": "Playbook: SMTP",
    "playbook-authelia": "Playbook: Authelia",
    "playbook-ldap": "Playbook: LDAP",
    "health": "System Health (JSON)",
    "runchecks": "Runchecks Results (JSON)",
    "docker": "Docker Daemon",
    "auth": "Authentication",
    "cron": "Cron Jobs",
    "ansible": "Ansible",
}


def _resolve_log_path(log_name):
    if log_name in ALLOWED_LOG_FILES:
        return ALLOWED_LOG_FILES[log_name]
    candidate = os.path.normpath(os.path.join(LOG_BASE_DIR, log_name))
    if os.path.commonpath([candidate, LOG_BASE_DIR]) == LOG_BASE_DIR:
        return candidate
    return None


def _get_container_list():
    containers = []
    try:
        with open(CONTAINER_INDEX) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    containers.append({"id": parts[0], "name": parts[1], "short_id": parts[0][:12]})
    except FileNotFoundError:
        pass
    return containers


def logs_stream(request):
    log_name = request.GET.get("log", "messages")
    offset_param = request.GET.get("offset", "0")

    try:
        offset = int(offset_param)
        if offset < 0:
            raise ValueError
    except ValueError:
        return HttpResponseBadRequest("Invalid offset parameter")

    # Docker container log
    if log_name.startswith("docker:"):
        container_id = log_name.split(":", 1)[1]
        return _docker_logs_stream(container_id, offset)

    real_path = _resolve_log_path(log_name)
    if not real_path:
        return HttpResponseBadRequest("Unknown or disallowed log file")

    if not os.path.exists(real_path):
        return JsonResponse(
            {"log_name": log_name, "path": real_path, "lines": [], "total_lines": 0, "error": "Log file does not exist"},
        )

    # Non-blocking: the browser polls at a short fixed interval, so this returns
    # the current tail immediately without waiting. New entries appear within
    # that interval without ever stalling the single-worker server.
    with open(real_path, "r", encoding="utf-8", errors="ignore") as f:
        all_lines = f.readlines()
    total_lines = len(all_lines)

    if offset == 0:
        raw_lines = all_lines[-500:]
    else:
        if offset > total_lines:
            raw_lines = all_lines[-500:]
        else:
            raw_lines = all_lines[offset:]

    lines_to_send = [line.rstrip('\n') for line in raw_lines]

    # Pretty-print health JSON
    if log_name == "health" and raw_lines:
        try:
            parsed = json.loads("".join(raw_lines))
            pretty = json.dumps(parsed, indent=2, default=str)
            lines_to_send = [pretty]
        except json.JSONDecodeError:
            pass

    return JsonResponse({
        "log_name": log_name,
        "label": LOG_LABELS.get(log_name, log_name),
        "path": real_path,
        "lines": lines_to_send,
        "total_lines": total_lines,
    })


def _docker_logs_stream(container_id, offset=0):
    log_path = os.path.join(DOCKER_LOG_BASE, container_id, f"{container_id}-json.log")

    if not os.path.exists(log_path):
        return JsonResponse(
            {"log_name": container_id, "lines": [], "total_lines": 0, "error": "Container log not found"},
        )

    container_name = container_id
    try:
        with open(CONTAINER_INDEX) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2 and parts[0].startswith(container_id):
                    container_name = parts[1]
                    break
    except FileNotFoundError:
        pass

    raw_lines = []
    total_lines = 0
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            raw = f.read()

        # The json-file log driver writes one JSON object per *entry*, but a
        # single entry's "log" field may contain embedded newlines (multi-line
        # stack traces). So we must not parse line-by-line; instead decode the
        # concatenated stream of JSON objects, preserving ANSI color codes
        # (the WebUI renders them) and embedded newlines (shown as multiple
        # visual lines).
        decoder = json.JSONDecoder()
        entries = []
        idx = 0
        n = len(raw)
        while idx < n:
            while idx < n and raw[idx] in " \r\n\t":
                idx += 1
            if idx >= n:
                break
            try:
                obj, end = decoder.raw_decode(raw, idx)
            except json.JSONDecodeError:
                # Fall back to the rest of the file as one raw blob.
                entries.append(raw[idx:])
                break
            idx = end
            msg = obj.get("log", "")
            if isinstance(msg, str) and msg.endswith("\n"):
                msg = msg[:-1]
            entries.append(msg)

        total_lines = len(entries)

        if offset == 0:
            raw_lines = entries[-500:]
        elif offset > total_lines:
            raw_lines = entries[-500:]
        else:
            raw_lines = entries[offset:]

        lines_to_send = [line if isinstance(line, str) else str(line) for line in raw_lines]
    except FileNotFoundError:
        pass

    return JsonResponse({
        "log_name": container_name,
        "path": log_path,
        "lines": lines_to_send,
        "total_lines": total_lines,
    })
