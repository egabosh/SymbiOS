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

Provides the Features tab on service detail pages, parameter detection,
and feature application via the generic symbios-feature-apply.sh script.
"""
import json
import os
import yaml
import time
from datetime import datetime, timezone

from django.http import JsonResponse
from django.shortcuts import render, Http404

from .decorators import login_required
from .plugin_catalog import (
    get_plugin,
    get_plugin_features,
    get_plugin_groups,
    load_plugin_state,
    save_plugin_state,
    has_plugin,
)
from .utils.ssh_exec import run_command
from .utils.jobs import create_job
from .views_services import _sidebar_context, get_catalog


@login_required
def plugin_features(request, service):
    """Render the Features tab for a service that has a plugin.yml."""
    plugin = get_plugin(service)
    if not plugin:
        raise Http404("No plugin found for service: %s" % service)

    manifest = plugin["manifest"]
    features = manifest.get("features", [])
    groups = manifest.get("groups", [])
    state = load_plugin_state(service)

    # Group features by their group id.
    grouped = {}
    for group in groups:
        grouped[group["id"]] = {
            "name": group["name"],
            "icon": group.get("icon", "puzzle"),
            "features": [],
        }
    # Ungrouped features go into a default group.
    grouped["_ungrouped"] = {
        "name": "Weitere",
        "icon": "puzzle",
        "features": [],
    }

    for feat in features:
        fid = feat["id"]
        feat_state = state.get(fid, {})
        feat_data = {
            "id": fid,
            "name": feat.get("name", fid),
            "icon": feat.get("icon", "puzzle"),
            "description": feat.get("description", ""),
            "enabled": feat_state.get("enabled", False),
            "status": feat_state.get("status"),
            "error": feat_state.get("error"),
            "last_applied": feat_state.get("last_applied"),
            "params": feat.get("params", []),
            "values": feat_state.get("params", {}),
            "has_params": bool(feat.get("params")),
        }
        gid = feat.get("group", "_ungrouped")
        if gid not in grouped:
            grouped[gid] = {"name": gid, "icon": "puzzle", "features": []}
        grouped[gid]["features"].append(feat_data)

    # Remove empty groups.
    groups_out = [g for g in grouped.values() if g["features"]]

    # Sidebar context (same as services pages).
    catalog = get_catalog()
    sidebar_ctx = _sidebar_context(catalog)

    # Load playbook source for each feature (small preview).
    features_with_source = []
    for g in groups_out:
        for feat in g["features"]:
            playbook_file = None
            for f in plugin["manifest"].get("features", []):
                if f["id"] == feat["id"]:
                    playbook_file = f.get("playbook")
                    break
            if playbook_file:
                src_path = os.path.join(plugin["plugin_dir"], "features", playbook_file)
                try:
                    with open(src_path) as fh:
                        feat["playbook_source"] = fh.read()
                except (OSError, IOError):
                    feat["playbook_source"] = ""
            else:
                feat["playbook_source"] = ""

    return render(request, "main/plugin_features.html", {
        "service": service,
        "manifest": manifest,
        "groups": groups_out,
        **sidebar_ctx,
    })


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

    return JsonResponse({
        "ok": True,
        "job": job_id,
        "title": "Feature anwenden: %s" % feature_id,
        "message": "Playbook wird ausgefuhrt...",
    })


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

    script_path = os.path.join(plugin["plugin_dir"], "features", detect_script)
    if not os.path.isfile(script_path):
        return JsonResponse({"ok": False, "error": "Detect script not found"}, status=404)

    ok, stdout, stderr = run_command("bash %s" % shlex_quote(script_path), timeout=15)
    if not ok:
        return JsonResponse({"ok": False, "error": stderr or "Detection failed"}, status=500)

    try:
        options = json.loads(stdout.strip())
    except (json.JSONDecodeError, ValueError):
        options = []

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
