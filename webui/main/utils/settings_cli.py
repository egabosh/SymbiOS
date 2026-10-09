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

"""Shared execution helper for settings CLI scripts.

Every symbios-settings-*.sh script follows the same contract (exit 0 ok,
2 validation error, 1 technical error; human lines plus a machine-readable
<domain>-changed / <domain>-unchanged token on the last line; gaboshlib
color codes on the terminal streams). This module maps that contract to
view answers so views keep only reapply chains and probes:

- run_settings_script(): run + parse (ok, changed flag, ANSI-free error).
- settings_failed(): build the dual-mode (AJAX JSON / fallback message)
  failure answer from a result.
"""

import re

from .ssh_exec import run_command

# Matches the state token scripts print last, with or without a suffix:
# "ai-changed", "localization-unchanged: Europe/Berlin ...".
_TOKEN_RE = re.compile(r"([\w-]+)-(changed|unchanged)\b")

# gaboshlib colors the terminal streams; the exec modal renders ANSI via
# ansiToHtml, but Django messages and JSON errors must stay readable.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(text):
    """Remove ANSI color codes from terminal output."""
    if not text:
        return ""
    return _ANSI_RE.sub("", text)


class SettingsResult:
    """Parsed outcome of one settings CLI call."""

    def __init__(self, ok, changed, output, error):
        self.ok = ok                # True when exit code was 0
        self.changed = changed      # True/False from the token, None when absent
        self.output = output        # combined stdout (raw, ANSI kept for the modal)
        self.error = error          # ANSI-free stderr (or stdout fallback)

    def __bool__(self):
        return self.ok


def run_settings_script(cmd, timeout=30, stdin_data=None):
    """Run a settings CLI command and parse the contract outcome.

    Returns a SettingsResult. Never raises on remote failure (ok=False);
    only local SSH breakage propagates as an exception, like run_command.
    """
    ok, stdout, stderr = run_command(cmd, timeout=timeout,
                                     stdin_data=stdin_data)
    output = stdout or ""
    error = strip_ansi(stderr or stdout or "").strip()
    changed = None
    if ok:
        matches = _TOKEN_RE.findall(output)
        if matches:
            changed = matches[-1][1] == "changed"
    return SettingsResult(ok, changed, output, error)


def settings_failed(request, result, redirect_name, fallback_status=400):
    """Dual-mode failure answer for a failed settings call.

    AJAX -> JsonResponse({'ok': False, 'error'}) for the exec modal;
    fallback -> error message + redirect. Returns the response object.
    """
    from django.http import JsonResponse
    from django.contrib import messages
    from django.shortcuts import redirect
    from .http import is_ajax_request
    err = result.error or "Failed to save settings."
    if is_ajax_request(request):
        return JsonResponse({"ok": False, "error": err},
                            status=fallback_status)
    messages.error(request, f"Error: {err}")
    return redirect(redirect_name)
