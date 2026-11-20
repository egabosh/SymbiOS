# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
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
All host system data is fetched via symbios-exec.sh (run_command),
not through Docker volume mounts.
"""

import os
import json
import re
import shlex
import subprocess
from django.http import JsonResponse, HttpResponseBadRequest
from ..decorators import login_required
from .ssh_exec import run_command

# SymbiOS logs - written by host scripts, mounted read-write in /log.
# These can be read directly inside the container.
LOCAL_LOG_BASE = "/log"

# System logs on the host - fetched via symbios-exec.sh, not mounted.
HOST_LOG_DIR = "/var/log"

# Docker container logs on the host - fetched via symbios-exec.sh.
HOST_DOCKER_LOG_DIR = "/symbios/docker/containers"

CONTAINER_INDEX = "/log/docker-containers.tsv"

ALLOWED_LOG_FILES = {
    "messages": "messages",
    "syslog": "syslog",
    "docker": "docker.log",
    "auth": "auth.log",
    "cron": "cron.log",
    "ansible": "ansible.log",
    "autoupdate": "/log/autoupdate.log",
    "maintenance": "/log/maintenance.log",
    "dedyn": "/log/dedyn.log",
    "reapply": "/log/reapply.log",
    "playbook-basics": "/log/playbook-basics.log",
    "playbook-symbios-ui": "/log/playbook-symbios-ui.log",
    "playbook-traefik": "/log/playbook-traefik.log",
    "playbook-dedyn": "/log/playbook-dedyn.log",
    "playbook-smtp": "/log/playbook-smtp.log",
    "playbook-authelia": "/log/playbook-authelia.log",
    "playbook-ldap": "/log/playbook-ldap.log",
    "health": "/log/system-health.json",
    "runchecks": "/log/runchecks-results.json",
}

# Only the bare filenames below are read from the host. Every other log is a
# local /log mount file and must be looked up in ALLOWED_LOG_FILES as well:
# a request-supplied log name must never become a host path or shell argument.
HOST_LOG_NAMES = frozenset(
    name for name, path in ALLOWED_LOG_FILES.items()
    if not path.startswith('/')
)

# Container ids in the WebUI are the full 64-hex Docker ids from CONTAINER_INDEX.
DOCKER_ID_RE = re.compile(r'^[a-f0-9]{64}$')

LOG_LABELS = {
    "messages": "System Messages",
    "syslog": "Syslog",
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
    "autoupdate": "Updates (autoupdate)",
    "maintenance": "Maintenance (backup + updates)",
}


def _is_host_log(log_name):
    """Check if this log lives on the host (not in /log mount)."""
    return log_name in HOST_LOG_NAMES


def _resolve_local_log_path(log_name):
    """Resolve a log name to a registered path inside the /log mount."""
    path = ALLOWED_LOG_FILES.get(log_name, "")
    return path if path.startswith(LOCAL_LOG_BASE + "/") else None


def _container_ids():
    """Full Docker ids currently listed in the container index."""
    ids = set()
    try:
        with open(CONTAINER_INDEX) as f:
            for line in f:
                parts = line.strip().split("\t")
                if parts:
                    ids.add(parts[0])
    except FileNotFoundError:
        pass
    return ids


def _fetch_host_log(log_name, offset=0, limit=500):
    """Fetch a registered system log from the host via symbios-exec.sh."""
    filename = ALLOWED_LOG_FILES.get(log_name, "")
    if not filename or filename.startswith('/'):
        return [], 0
    host_path = f"{HOST_LOG_DIR}/{filename}"
    # Single script call: outputs count on first line, then log content.
    # The name came from the allowlist, but quote it anyway: symbios-exec.sh
    # runs the inner command through a root shell.
    ok, stdout, _ = run_command(
        "symbios-fetch-log.sh %s %d %d" % (shlex.quote(host_path), offset, limit),
        timeout=15,
    )
    if not ok or not stdout:
        return [], 0
    lines_raw = stdout.splitlines()
    if not lines_raw:
        return [], 0
    # First line is the total count
    try:
        total = int(lines_raw[0])
    except ValueError:
        total = 0
    # Remaining lines are log content
    lines = lines_raw[1:] if len(lines_raw) > 1 else []
    return lines, total


def _fetch_host_docker_log(container_id, offset=0, limit=500):
    """Fetch a Docker container JSON log from the host via symbios-exec.sh."""
    # Single script call: outputs count on first line, then extracted log messages
    ok, stdout, _ = run_command(
        "symbios-fetch-docker-log.sh %s %d %d" % (shlex.quote(container_id), offset, limit),
        timeout=15,
    )
    if not ok or not stdout:
        return [], 0, container_id
    # Get container name from index
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
    lines_raw = stdout.splitlines()
    if not lines_raw:
        return [], 0, container_name
    # First line is the total count
    try:
        total_host = int(lines_raw[0])
    except ValueError:
        total_host = 0
    # Remaining lines are extracted log messages (no JSON parsing needed)
    entries = lines_raw[1:] if len(lines_raw) > 1 else []
    return entries, total_host, container_name


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


@login_required
def logs_stream(request):
    log_name = request.GET.get("log", "messages")
    offset_param = request.GET.get("offset", "0")

    try:
        offset = int(offset_param)
        if offset < 0:
            raise ValueError
    except ValueError:
        return HttpResponseBadRequest("Invalid offset parameter")

    # Docker container log: only full ids from the local container index are
    # accepted, so a crafted name cannot reach the root host shell or path.
    if log_name.startswith("docker:"):
        container_id = log_name.split(":", 1)[1]
        if not DOCKER_ID_RE.match(container_id) or container_id not in _container_ids():
            return HttpResponseBadRequest("Unknown container")
        return _docker_logs_stream(container_id, offset)

    if _is_host_log(log_name):
        lines, total = _fetch_host_log(log_name, offset)
        return JsonResponse({
            "log_name": log_name,
            "label": LOG_LABELS.get(log_name, log_name),
            "path": f"{HOST_LOG_DIR}/{log_name}",
            "lines": lines,
            "total_lines": total,
        })

    # Local log (from /log/ mount)
    real_path = _resolve_local_log_path(log_name)
    if not real_path:
        return HttpResponseBadRequest("Unknown or disallowed log file")

    if not os.path.exists(real_path):
        return JsonResponse(
            {"log_name": log_name, "path": real_path, "lines": [], "total_lines": 0, "error": "Log file does not exist"},
        )

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
    entries, total_lines, container_name = _fetch_host_docker_log(container_id, offset)

    if offset == 0:
        raw_lines = entries[-500:]
    elif offset > total_lines:
        raw_lines = entries[-500:]
    else:
        raw_lines = entries[offset:]

    lines_to_send = [line if isinstance(line, str) else str(line) for line in raw_lines]

    return JsonResponse({
        "log_name": container_name,
        "path": f"{HOST_DOCKER_LOG_DIR}/{container_id}/{container_id}-json.log",
        "lines": lines_to_send,
        "total_lines": total_lines,
    })
