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

from django.shortcuts import render, redirect
from django.http import JsonResponse
from django.contrib import messages
from .decorators import login_required
from .views import _get_inventory_config, _save_inventory_config
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .setup_status import PAGE_EXPLAIN

import json

# Scripts on the host (in scripts/, on PATH).
_LIST_SCRIPT = 'symbios-bridge-list.sh'
_ASSIGN_SCRIPT = 'symbios-bridge-assign.sh'
_PLAYBOOK = 'base-services/network-bridges.yml'


def _fetch_network_data():
    """Query the host for visible bridges and interfaces.

    Returns a dict with keys 'bridges', 'interfaces', 'current' (the stored
    assignments). Falls back to empty lists when the host cannot be reached
    or the script reports an error.
    """
    empty = {'bridges': [], 'interfaces': [], 'current': {}}
    try:
        ok, stdout, _ = run_command(_LIST_SCRIPT, timeout=15)
        if ok and stdout:
            data = json.loads(stdout)
            return {
                'bridges': data.get('bridges', []),
                'interfaces': data.get('interfaces', []),
                'current': data.get('current') or {},
            }
    except Exception:
        pass
    return empty


@login_required
def settings_network_bridges(request):
    """Settings page: assign physical interfaces to Linux bridges.

    The available bridges exclude Docker-managed ones (br-*, docker*),
    the SymbiOS service networks (symbios_base_services, symbios_services)
    and the reserved base-services / services names. Assignments are saved to
    inventory.yml and applied on the host by symbios-bridge-assign.sh, which
    also persists them in /etc/rc.local.
    """
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    data = _fetch_network_data()

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            # The form sends one select per visible interface named
            # bridge_<iface>; an empty value means "no assignment".
            assignments = {}
            for iface in data['interfaces']:
                bridge = request.POST.get('bridge_' + iface, '').strip()
                if bridge:
                    assignments[iface] = bridge

            vars_['bridge_assignments'] = assignments
            _save_inventory_config(config)

            bridge_json = json.dumps(assignments)
            cmd = 'symbios-run-playbook.sh {} && {}'.format(
                _PLAYBOOK, _ASSIGN_SCRIPT)

            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=300, stdin_data=bridge_json)
                return JsonResponse({
                    'ok': True,
                    'job': job_id,
                    'title': 'Applying network bridge assignments...',
                    'message': 'Bridge assignments saved.',
                    'command': cmd,
                })

            messages.success(request, 'Bridge assignments saved.')
            ok, stdout, stderr = run_command(
                cmd, timeout=120, stdin_data=bridge_json)
            if ok:
                messages.success(request, 'Assignments applied successfully.')
            else:
                output = (stdout + '\n' + stderr).strip()
                messages.error(
                    request, 'Applying assignments failed: {}'.format(
                        output[:500]))
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)},
                                    status=500)
            messages.error(request, 'Error: {}'.format(e))
        return redirect('settings_network_bridges')

    assignments = vars_.get('bridge_assignments') or {}
    status, label, text = _bridge_status(assignments)

    return render(request, 'main/settings_network_bridges.html', {
        'bridges': data['bridges'],
        'interfaces': data['interfaces'],
        'current': assignments,
        'page_key': 'network-bridges',
        'page_icon': 'bi-diagram-3',
        'page_title': 'Network Bridges',
        'page_explain': PAGE_EXPLAIN['network-bridges'],
        'page_status': status,
        'page_status_label': label,
        'page_status_text': text,
    })


@login_required
def settings_network_bridges_list(request):
    """AJAX endpoint: fresh bridges/interfaces/current state from the host."""
    data = _fetch_network_data()
    return JsonResponse(data)


def _bridge_status(assignments):
    """Return the (status, label, text) badge for the settings page."""
    if not assignments:
        return ('none', 'No assignments',
                'No physical interface is assigned to a bridge yet.')
    count = len(assignments)
    names = ', '.join('{} -> {}'.format(k, v) for k, v in assignments.items())
    return ('ok', '{} assignment{}'.format(
                count, '' if count == 1 else 's'),
            names)