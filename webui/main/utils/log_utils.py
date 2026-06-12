"""
Log utility functions for secure log file access and streaming.
"""
import os
from django.http import JsonResponse, HttpResponseBadRequest
from .ansi_to_html import ansi_to_html

# Base directory for log files that are allowed to be viewed.
LOG_BASE_DIR = "/var/log"

# Allowlist of logical names to real filesystem paths.
ALLOWED_LOG_FILES = {
    "messages": "/var/log/messages",
    "syslog": "/var/log/syslog",
    "symbios": "/log/symbios.log",
    # Add more names -> paths here.
}


def _resolve_log_path(log_name: str) -> str | None:
    """
    Resolve a logical log name to a real filesystem path.

    Args:
        log_name: Logical name (e.g. "messages") or relative path under LOG_BASE_DIR.

    Returns:
        Absolute filesystem path if valid, None otherwise.
    """
    # First check explicit allowlist.
    if log_name in ALLOWED_LOG_FILES:
        return ALLOWED_LOG_FILES[log_name]

    # Optional: allow paths under LOG_BASE_DIR via relative names.
    candidate = os.path.normpath(os.path.join(LOG_BASE_DIR, log_name))
    # Ensure the candidate path is still inside LOG_BASE_DIR.
    if os.path.commonpath([candidate, LOG_BASE_DIR]) != LOG_BASE_DIR:
        return None
    return candidate


def logs_stream(request):
    """
    Return log content as JSON for generic tail-like viewing in the browser.

    Query parameters:
      - log: logical name (e.g. "messages") or relative path under LOG_BASE_DIR.
      - offset (optional): integer line offset (simple line-based marker).

    Response JSON:
      {
        "log_name": "messages",
        "path": "/var/log/messages",
        "lines": ["line1\n", "line2\n", ...],
        "total_lines": 1234
      }
    """
    log_name = request.GET.get("log", "messages")
    offset_param = request.GET.get("offset", "0")

    try:
        offset = int(offset_param)
        if offset < 0:
            raise ValueError
    except ValueError:
        return HttpResponseBadRequest("Invalid offset parameter")

    real_path = _resolve_log_path(log_name)
    if not real_path:
        return HttpResponseBadRequest("Unknown or disallowed log file")

    if not os.path.exists(real_path):
        return JsonResponse(
            {
                "log_name": log_name,
                "path": real_path,
                "lines": [],
                "total_lines": 0,
                "error": "Log file does not exist",
            },
            status=404,
        )

    # Read all lines (for small/medium logs this is fine).
    with open(real_path, "r", encoding="utf-8", errors="ignore") as f:
        all_lines = f.readlines()

    total_lines = len(all_lines)

    # Handle initial load vs. incremental updates.
    if offset == 0:
        # Initial load: only return the last N lines.
        max_initial_lines = 500
        raw_lines = all_lines[-max_initial_lines:]
    else:
        if offset > total_lines:
            # File rotation/truncation: send last N lines again.
            max_initial_lines = 500
            raw_lines = all_lines[-max_initial_lines:]
        else:
            # Incremental: send only new lines.
            raw_lines = all_lines[offset:]
    lines_to_send = [ansi_to_html(line) for line in raw_lines]

    return JsonResponse(
        {
            "log_name": log_name,
            "path": real_path,
            "lines": lines_to_send,
            "total_lines": total_lines,
        }
    )

