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

"""Dynamic catalog of service feature plugins.

Scans /repo/services/ for plugin.yml files and provides a cached API for
the WebUI to discover available features, their parameters, and current state.
"""
import os
import time
import yaml

REPO_BASE = "/repo"
CONFIG_BASE = "/config"

# Cache with TTL (same pattern as playbook_catalog.py).
_CACHE = {"data": None, "updated": 0.0, "ttl": 30.0}


def _scan_plugins():
    """Scan /repo/services/ for plugin.yml files and return parsed manifests."""
    results = []
    services_dir = os.path.join(REPO_BASE, "services")
    if not os.path.isdir(services_dir):
        return results
    for name in sorted(os.listdir(services_dir)):
        plugin_yml = os.path.join(services_dir, name, "plugin.yml")
        if not os.path.isfile(plugin_yml):
            continue
        try:
            with open(plugin_yml) as fh:
                manifest = yaml.safe_load(fh) or {}
        except Exception:
            continue
        if not manifest.get("name"):
            continue
        results.append({
            "service": name,
            "manifest": manifest,
            "plugin_dir": os.path.join(services_dir, name),
        })
    return results


def get_plugins(force=False):
    """Return all discovered feature plugins (cached)."""
    now = time.time()
    if not force and _CACHE["data"] is not None and (now - _CACHE["updated"]) < _CACHE["ttl"]:
        return _CACHE["data"]
    data = _scan_plugins()
    _CACHE["data"] = data
    _CACHE["updated"] = now
    return data


def get_plugin(service_name):
    """Return a single plugin by service name, or None."""
    for plugin in get_plugins():
        if plugin["service"] == service_name:
            return plugin
    return None


def get_plugin_features(service_name):
    """Return the features list for a given service, or empty list."""
    plugin = get_plugin(service_name)
    if not plugin:
        return []
    return plugin["manifest"].get("features", [])


def get_plugin_groups(service_name):
    """Return the groups list for a given service, or empty list."""
    plugin = get_plugin(service_name)
    if not plugin:
        return []
    return plugin["manifest"].get("groups", [])


def get_plugin_state_path(service_name):
    """Return the path to the features-state.yml file for a service.

    State is stored in the writable /config directory (persisted across
    container restarts), falling back to the read-only repo for initial state.
    The host script (symbios-feature-apply.sh) mirrors this path via the
    /config mount -> /symbios/base-services/symbios-ui/config/ on the host.
    """
    config_path = os.path.join(CONFIG_BASE, "services", service_name, "features-state.yml")
    if os.path.isfile(config_path):
        return config_path
    repo_path = os.path.join(REPO_BASE, "services", service_name, "features-state.yml")
    if os.path.isfile(repo_path):
        return repo_path
    return config_path


def load_plugin_state(service_name):
    """Load the current feature state for a service."""
    path = get_plugin_state_path(service_name)
    try:
        with open(path) as fh:
            return yaml.safe_load(fh) or {}
    except (FileNotFoundError, yaml.YAMLError):
        return {}


def save_plugin_state(service_name, state):
    """Save feature state to /config/services/<name>/features-state.yml."""
    config_dir = os.path.join(CONFIG_BASE, "services", service_name)
    os.makedirs(config_dir, exist_ok=True)
    path = os.path.join(config_dir, "features-state.yml")
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w") as fh:
            yaml.dump(state, fh, default_flow_style=False, sort_keys=False)
        os.replace(tmp_path, path)
        return True
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False


def has_plugin(service_name):
    """Check if a service has a plugin.yml (for tab visibility)."""
    return get_plugin(service_name) is not None
