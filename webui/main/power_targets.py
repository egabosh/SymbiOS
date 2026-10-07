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

"""Shared Power-target helpers for the Suspend and Wake-on-LAN pages.

The target list is stored as YAML in the container's /config mount
(power/targets.yml, same directory the host resolves as config dir).
Each target may carry a wake block, a suspend block, or both.
"""

import os
import re

import yaml

CONFIG_FILE = '/config/power/targets.yml'

NAME_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')
MAC_RE = re.compile(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')
HOST_RE = re.compile(r'^[A-Za-z0-9.-]+$')


def load_targets():
    """Load the target list (empty list when absent or invalid)."""
    try:
        with open(CONFIG_FILE, 'r') as handle:
            data = yaml.safe_load(handle) or []
            if isinstance(data, list):
                return [e for e in data if isinstance(e, dict)]
    except (OSError, yaml.YAMLError):
        pass
    return []


def save_targets(targets):
    """Persist the target list, creating the directory when needed."""
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, 'w') as handle:
        yaml.safe_dump(targets, handle, default_flow_style=False, sort_keys=False)


def validate_target(entry, targets, original_name=None):
    """Validate one entry against the list. Returns an error string or None."""
    name = entry.get('name', '')
    if not NAME_RE.match(name):
        return 'Invalid name: must start with a letter or digit, then letters, digits or hyphens.'
    if name != original_name and any(e.get('name') == name for e in targets):
        return f'A target named "{name}" already exists.'
    wake = entry.get('wake') or {}
    suspend = entry.get('suspend') or {}
    if not wake and not suspend:
        return 'A target needs a wake block, a suspend block, or both.'
    if wake.get('enabled'):
        if not MAC_RE.match(wake.get('mac') or ''):
            return 'Invalid MAC address (expected AA:BB:CC:DD:EE:FF).'
        if not HOST_RE.match(wake.get('host') or ''):
            return 'Invalid wake host: must be a hostname or IP address.'
        if not wake.get('patterns'):
            return 'Wake patterns must not be empty (one hostname per line).'
    if suspend.get('enabled'):
        if not HOST_RE.match(suspend.get('host') or ''):
            return 'Invalid suspend host: must be a hostname or IP address.'
        if not re.match(r'^[a-zA-Z0-9]+$', suspend.get('iface') or ''):
            return 'Invalid network interface (e.g. eno1, eth0).'
        try:
            timeout = int(suspend.get('idle_timeout_min', 0))
        except (TypeError, ValueError):
            return 'Invalid idle timeout: must be minutes as a number.'
        if timeout < 5 or timeout > 600:
            return 'Invalid idle timeout: must be between 5 and 600 minutes.'
    return None


def entry_from_post(request, original):
    """Build a target entry from POST fields, keeping the untouched block."""
    targets = load_targets()
    old = next((e for e in targets if e.get('name') == original), {}) if original else {}
    entry = {'name': request.POST.get('name', '').strip().lower()}
    if 'wake_enabled' in request.POST or 'wake' in old:
        patterns = [p.strip() for p in request.POST.get('patterns', '').splitlines()]
        patterns = [p for p in patterns if p]
        if not patterns and isinstance(old.get('wake'), dict):
            patterns = old['wake'].get('patterns') or []
        entry['wake'] = {
            'enabled': 'wake_enabled' in request.POST,
            'mac': request.POST.get('mac', (old.get('wake') or {}).get('mac', '')).strip(),
            'host': request.POST.get('wake_host', (old.get('wake') or {}).get('host', '')).strip(),
            'patterns': patterns,
        }
        if request.POST.get('log_path', '').strip():
            entry['wake']['log_path'] = request.POST.get('log_path').strip()
    if 'suspend_enabled' in request.POST or 'suspend' in old:
        entry['suspend'] = {
            'enabled': 'suspend_enabled' in request.POST,
            'host': request.POST.get('suspend_host', (old.get('suspend') or {}).get('host', '')).strip(),
            'iface': request.POST.get('iface', (old.get('suspend') or {}).get('iface', '')).strip(),
            'idle_timeout_min': int(request.POST.get('idle_timeout_min', (old.get('suspend') or {}).get('idle_timeout_min', 15)) or 15),
            'grace_after_wol_sec': int(request.POST.get('grace_after_wol_sec', (old.get('suspend') or {}).get('grace_after_wol_sec', 300)) or 300),
            'tcp_ports': request.POST.get('tcp_ports', (old.get('suspend') or {}).get('tcp_ports', '')).strip(),
            'lan_subnet': request.POST.get('lan_subnet', (old.get('suspend') or {}).get('lan_subnet', '')).strip(),
            'extra_local_cmd': request.POST.get('extra_local_cmd', (old.get('suspend') or {}).get('extra_local_cmd', '')).strip(),
            'extra_remote_cmd': request.POST.get('extra_remote_cmd', (old.get('suspend') or {}).get('extra_remote_cmd', '')).strip(),
        }
    return entry
