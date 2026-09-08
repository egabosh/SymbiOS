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

"""Views for the feature plugin system.

API endpoints for toggling, saving, applying, and detecting feature parameters.
Features are rendered inline in services_detail.html.
"""
import json
import threading

from django.http import JsonResponse
from django.shortcuts import Http404

from .decorators import login_required
from .plugin_catalog import (
    get_plugin,
    load_plugin_state,
    save_plugin_state,
    has_plugin,
)
from .utils.ssh_exec import run_command
from .utils.jobs import create_job


@login_required
def plugin_feature_toggle(request, service, feature_id):
    """Toggle a feature on/off (POST only). Updates state but does not apply."""
    if request.method != "POST":
        return JsonResponse({"ok": False, "error": "POST required"}, status=405)

    state = load_plugin_state(service)
    feat = state.get(feature_id, {})
    current = feat.get("enabled", False)
    feat["enabled"] = not current
    if not feat.get("status"):
        feat["status"] = "draft" if feat["enabled"] else None
    state[feature_id] = feat
    save_plugin_state(service, state)

    return JsonResponse({
        "ok": True,
        "enabled": feat["enabled"],
        "status": feat["status"],
    })


@login_required
def plugin_feature_save(request, service, feature_id):
    """Save feature parameters (POST only). Sets status to 'draft'."""
    if request.method != "POST":
        return JsonResponse({"ok": False, "error": "POST required"}, status=405)

    try:
        data = json.loads(request.body) if request.content_type == "application/json" else {}
    except (json.JSONDecodeError, ValueError):
        data = {}

    # Also support form-encoded data.
    if not data:
        data = dict(request.POST)

    state = load_plugin_state(service)
    feat = state.get(feature_id, {})
    feat["enabled"] = True
    feat["status"] = "draft"
    feat["error"] = None
    feat.setdefault("params", {})
    feat["params"].update(data)
    state[feature_id] = feat
    save_plugin_state(service, state)

    return JsonResponse({"ok": True, "status": "draft"})


@login_required
def plugin_feature_apply(request, service, feature_id):
    """Apply a feature by running symbios-feature-apply.sh (async job)."""
    if request.method != "POST":
        return JsonResponse({"ok": False, "error": "POST required"}, status=405)

    cmd = "symbios-feature-apply.sh %s %s" % (shlex_quote(service), shlex_quote(feature_id))
    job_id = create_job(cmd, timeout=600)

    # Optimistically update state.
    state = load_plugin_state(service)
    feat = state.get(feature_id, {})
    feat["status"] = "applying"
    feat["error"] = None
    state[feature_id] = feat
    save_plugin_state(service, state)

    # Background thread: wait for job to finish and update state.
    threading.Thread(
        target=_finish_feature_apply,
        args=(service, feature_id, job_id),
        daemon=True,
    ).start()

    return JsonResponse({
        "ok": True,
        "job": job_id,
        "title": "Feature apply: %s" % feature_id,
        "message": "Running playbook...",
    })


def _finish_feature_apply(service, feature_id, job_id):
    """Wait for a feature apply job to complete and update the feature state."""
    from .utils.jobs import get_job_output
    import time
    # Poll until the job is done.
    for _ in range(300):
        result = get_job_output(job_id)
        if result is None:
            return
        _output, done, _ok, _cmd = result
        if done:
            break
        time.sleep(2)
    result = get_job_output(job_id)
    success = bool(result and result[2])
    state = load_plugin_state(service)
    feat = state.get(feature_id, {})
    if success:
        feat["status"] = "applied"
        feat["error"] = None
        from datetime import datetime, timezone
        feat["last_applied"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    else:
        feat["status"] = "error"
        output = (result[0] if result else "")[-500:] if result else ""
        feat["error"] = output.strip() or "Playbook failed"
    state[feature_id] = feat
    save_plugin_state(service, state)


@login_required
def plugin_feature_detect(request, service, feature_id, param_name):
    """Run a detect script to discover available options for a parameter."""
    from .plugin_catalog import get_plugin

    plugin = get_plugin(service)
    if not plugin:
        return JsonResponse({"ok": False, "error": "Plugin not found"}, status=404)

    # Find the detect script for this parameter.
    detect_script = None
    for feat in plugin["manifest"].get("features", []):
        if feat["id"] == feature_id:
            for p in feat.get("params", []):
                if p["name"] == param_name:
                    detect_script = p.get("detect")
                    break
            break

    if not detect_script:
        return JsonResponse({"ok": True, "options": []})

    # Detect scripts run on the host (run_command goes through symbios-exec.sh),
    # so use the host-side helper: it resolves plugin.yml and features/ from the
    # host repo copy instead of a container-local /repo path that does not exist
    # on the host.
    cmd = "symbios-feature-detect.sh %s %s %s" % (
        shlex_quote(service), shlex_quote(feature_id), shlex_quote(param_name)
    )
    ok, stdout, stderr = run_command(cmd, timeout=15)

    try:
        options = json.loads(stdout.strip())
    except (json.JSONDecodeError, ValueError):
        options = []

    if not ok and not options:
        return JsonResponse({"ok": False, "error": stderr or "Detection failed"}, status=500)

    return JsonResponse({"ok": True, "options": options})


@login_required
def plugin_feature_status(request, service):
    """Return the current feature states as JSON (for polling after apply)."""
    state = load_plugin_state(service)
    return JsonResponse({"ok": True, "state": state})


def shlex_quote(s):
    """Minimal shell quoting (avoids importing shlex in the view)."""
    import re as _re
    return "'" + _re.sub(r"'", "'\\''", str(s)) + "'"
