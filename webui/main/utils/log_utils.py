"""
Log utility functions for secure log file access and streaming.
Supports system logs and Docker container logs.
"""
import os
import json
from django.http import JsonResponse, HttpResponseBadRequest
from .ansi_to_html import ansi_to_html

LOG_BASE_DIR = "/var/log"
DOCKER_LOG_BASE = "/docker/containers"
CONTAINER_INDEX = "/log/docker-containers.tsv"

ALLOWED_LOG_FILES = {
    "messages": "/var/log/messages",
    "syslog": "/var/log/syslog",
    "symbios": "/log/symbios.log",
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
                    containers.append({"id": parts[0][:12], "name": parts[1]})
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
            status=404,
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

    lines_to_send = [ansi_to_html(line) for line in raw_lines]

    return JsonResponse({
        "log_name": log_name,
        "path": real_path,
        "lines": lines_to_send,
        "total_lines": total_lines,
    })


def _docker_logs_stream(container_id, offset=0):
    log_path = os.path.join(DOCKER_LOG_BASE, container_id, f"{container_id}-json.log")

    if not os.path.exists(log_path):
        return JsonResponse(
            {"log_name": container_id, "lines": [], "total_lines": 0, "error": "Container log not found"},
            status=404,
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
            all_lines = []
            for line in f:
                all_lines.append(line)
            total_lines = len(all_lines)

            if offset == 0:
                raw_lines = all_lines[-500:]
            elif offset > total_lines:
                raw_lines = all_lines[-500:]
            else:
                raw_lines = all_lines[offset:]

        lines_to_send = []
        for line in raw_lines:
            line = line.strip()
            if line:
                try:
                    entry = json.loads(line)
                    msg = entry.get("log", line)
                    ts = entry.get("time", "")
                except json.JSONDecodeError:
                    msg = line
                    ts = ""
                lines_to_send.append(ansi_to_html(msg))
            else:
                lines_to_send.append("")
    except FileNotFoundError:
        pass

    return JsonResponse({
        "log_name": container_name,
        "path": log_path,
        "lines": lines_to_send,
        "total_lines": total_lines,
    })


def container_list(request):
    containers = _get_container_list()
    return JsonResponse({"containers": containers})
