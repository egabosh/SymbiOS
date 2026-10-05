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

import json
import os
from datetime import datetime
from django.http import JsonResponse
from django.shortcuts import render, redirect
from django.contrib import messages
from zoneinfo import ZoneInfo
from .decorators import login_required
from .playbook_catalog import get_catalog
from .views_services import _get_installed_playbooks, _get_healthcheck_status, _order_catalog
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command

# Snapshot files in the /log volume, written minutely by the
# symbios-dashboard-snapshot.sh cron job so the WebUI never blocks on live
# host commands (see /log/runchecks-results.json for the same pattern).
_STATS_SNAPSHOT = 'dashboard-stats.json'
_NETWORK_SNAPSHOT = 'dashboard-network.json'

# Full scale of the Disk I/O gauge in the dashboard (MB/s).
_IO_MAX_MB = 20


def _timezone_name():
    """Timezone from inventory.yml (``all.vars.timezone``), if any."""
    from .views import _get_inventory_config
    config = _get_inventory_config()
    return str(config.get('all', {}).get('vars', {}).get('timezone') or '')


def _localize_time(value):
    """Convert a UTC timestamp (``...Z``) to the inventory timezone.

    Returns a ``YYYY-MM-DD HH:MM:SS`` string in the local zone, or the
    original value unchanged when no timezone is configured in inventory.yml.
    """
    tz = _timezone_name()
    if not value or not tz:
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return dt.astimezone(ZoneInfo(tz)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return value


def _read_snapshot(name):
    """Read a dashboard snapshot JSON file from the /log volume mount."""
    try:
        with open(os.path.join('/log', name)) as fh:
            return json.load(fh)
    except (FileNotFoundError, PermissionError, json.JSONDecodeError):
        return {}


def _get_host_stats():
    """Load the Host System snapshot (CPU/memory/load/disk I/O statistics).

    Adds derived fields for the server-side template rendering:
    ``io_read_mb``/``io_write_mb`` (throughput in MB/s), ``io_bar`` (the
    Disk I/O gauge width in percent, scaled to ``_IO_MAX_MB``) and per
    device ``rmb``/``wmb`` (MB/s values).
    """
    data = _read_snapshot(_STATS_SNAPSHOT)
    if not data:
        return {}
    try:
        data['timestamp'] = _localize_time(data.get('timestamp'))
        rmb = float(data.get('io_read_kbs', 0) or 0) / 1024.0
        wmb = float(data.get('io_write_kbs', 0) or 0) / 1024.0
        data['io_read_mb'] = round(rmb, 1)
        data['io_write_mb'] = round(wmb, 1)
        data['io_max_mb'] = _IO_MAX_MB
        data['io_bar'] = round(min(100.0, max(rmb, wmb) * 100.0 / _IO_MAX_MB), 1)
        for dev in data.get('io_devices') or []:
            dev['rmb'] = round(float(dev.get('rkbs', 0) or 0) / 1024.0, 1)
            dev['wmb'] = round(float(dev.get('wkbs', 0) or 0) / 1024.0, 1)
        return data
    except Exception:
        return {}


def _get_network_devices():
    """Load the Network Devices snapshot.

    The scan covers every interface with a private IPv4 (default-route LAN,
    OpenWrt VM bridges, ...) except the intentionally internal networks
    (Docker bridges ``br-*``/``docker0`` and the SymbiOS service networks
    ``base-services``/``services``). WiFi stations currently associated to
    the hostapd access point are included as well. The scan itself runs
    minutely via cron (symbios-dashboard-snapshot.sh); this loader never
    triggers it.

    Besides the flat ``devices`` list (kept for compatibility) this also
    builds ``groups``: one entry per subnet with the host's own row as
    ``self`` (its IP/hostname/MAC in that network) and the remaining
    devices in ``devices``, so the dashboard can render one table per
    network without repeating interface/subnet columns.
    """
    data = _read_snapshot(_NETWORK_SNAPSHOT)
    if not data:
        return {}
    try:
        data['scanned_at'] = _localize_time(data.get('scanned_at'))

        # Sort by subnet (the physical default-route LAN first), then IP.
        subnets = data.get('subnets') or []
        subnet_order = {s.get('cidr', ''): i for i, s in enumerate(subnets)}
        devices = data.get('devices') or []

        def _sort_key(device):
            subnet = str(device.get('subnet', ''))
            order = subnet_order.get(subnet, len(subnet_order))
            return [order] + _ip_key(device)

        data['devices'] = sorted(devices, key=_sort_key)

        by_cidr = {}
        for device in data['devices']:
            by_cidr.setdefault(str(device.get('subnet', '')), []).append(device)
        groups = []
        for subnet in subnets:
            cidr = str(subnet.get('cidr', ''))
            members = by_cidr.pop(cidr, [])
            self_row = next((d for d in members if d.get('self')), None)
            groups.append({
                'cidr': cidr,
                'interface': subnet.get('interface', ''),
                'self': self_row,
                'devices': [d for d in members if not d.get('self')],
            })
        # Devices whose subnet is not in the subnets list (should not
        # happen, but keep them visible instead of dropping them).
        for cidr, members in by_cidr.items():
            self_row = next((d for d in members if d.get('self')), None)
            groups.append({
                'cidr': cidr,
                'interface': (members[0].get('interface', '')
                              if members else ''),
                'self': self_row,
                'devices': [d for d in members if not d.get('self')],
            })
        data['groups'] = groups
        return data
    except Exception:
        return {}


def _ip_key(device):
    """Sort key so IPv4 addresses are ordered numerically, not lexically."""
    octets = str(device.get('ip', '0.0.0.0')).split('.')
    try:
        numeric = [int(x) for x in octets]
    except ValueError:
        numeric = [0, 0, 0, 0]
    return numeric + [str(device.get('ip', ''))]


def _get_failing_healthchecks():
    """Read runchecks-results.json and return only checks with status != 'ok'."""
    results_file = '/log/runchecks-results.json'
    try:
        with open(results_file) as fh:
            data = json.load(fh)
    except (FileNotFoundError, PermissionError, json.JSONDecodeError):
        return []
    checks = data.get('checks', [])
    last_run = data.get('last_run', '')
    failing = []
    for c in checks:
        if c.get('status') != 'ok':
            failing.append({
                'name': c.get('name', '?'),
                'status': c.get('status', 'unknown'),
                'message': c.get('message', ''),
                'title': c.get('title', c.get('name', '?')),
                'last_run': c.get('checked', last_run),
            })
    return failing


@login_required
def home(request):
    """Dashboard homepage: failing healthchecks + installed services."""
    from .views import _get_inventory_config, _get_ldap_users
    from .setup_status import setup_steps, is_setup_complete

    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    ldap_users = _get_ldap_users()
    steps = setup_steps(vars_, ldap_users=ldap_users)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']

    # Failing healthchecks
    failing_checks = _get_failing_healthchecks()

    # Installed services with healthcheck status
    catalog = get_catalog()
    installed = _get_installed_playbooks()
    ordered = _order_catalog(catalog)
    healthcheck_status = _get_healthcheck_status()
    installed_services = [i for i in ordered if i.get('playbook', '') in installed
                         and i.get('group') != 'base-services']
    available_services = [i for i in ordered
                         if i.get('group') != 'base-services'
                         and i.get('playbook', '') not in installed]

    return render(request, 'main/home.html', {
        'setup_incomplete': not is_setup_complete(vars_, ldap_users=ldap_users),
        'setup_pending': len(pending),
        'failing_checks': failing_checks,
        'installed_services': installed_services,
        'available_services': available_services,
        'healthcheck_status': healthcheck_status,
        'host_stats': _get_host_stats(),
        'network': _get_network_devices(),
    })


@login_required
def dashboard_stats(request):
    """AJAX endpoint: fresh host CPU/memory/load/disk I/O statistics."""
    return JsonResponse(_get_host_stats())


@login_required
def dashboard_network(request):
    """AJAX endpoint: discovered external LAN devices.

    The scan itself runs minutely via cron (symbios-dashboard-snapshot.sh);
    this endpoint only reads the pre-computed snapshot file.
    """
    return JsonResponse(_get_network_devices())


# Host power script (in scripts/, on PATH) and the only actions it accepts.
_POWER_SCRIPT = 'symbios-power.sh'
_POWER_ACTIONS = ('reboot', 'shutdown')


@login_required
def system_power(request):
    """Reboot or shut down the whole SymbiOS host.

    Change operation behind the exec modal overlay: AJAX submits a
    background job and polls its live output (the host script announces the
    action first, so the modal treats the following connection loss as the
    expected reboot/shutdown). The plain POST fallback runs the command
    synchronously. Only POST with a valid action is accepted.
    """
    if request.method != 'POST':
        return redirect('home')
    is_ajax = is_ajax_request(request)
    action = request.POST.get('action', '').strip()
    if action not in _POWER_ACTIONS:
        if is_ajax:
            return JsonResponse({'ok': False, 'error': 'Unknown power action.'},
                                status=400)
        messages.error(request, 'Unknown power action.')
        return redirect('home')

    cmd = '{} {}'.format(_POWER_SCRIPT, action)
    if action == 'reboot':
        title = 'Rebooting the host...'
        message = ('The host is rebooting. Wait for the boot, unlock LUKS at '
                   'the boot page if asked.')
    else:
        title = 'Shutting down the host...'
        message = ('The host is shutting down and stays off until powered '
                   'on again.')

    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=120)
        return JsonResponse({
            'ok': True,
            'job': job_id,
            'title': title,
            'message': message,
            'command': cmd,
        })

    try:
        run_command(cmd, timeout=30)
    except Exception as e:
        messages.error(request, 'Error: {}'.format(e))
        return redirect('home')
    messages.success(request, message)
    return redirect('home')
