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
from .views import _get_inventory_config
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .setup_status import get_page_badge, PAGE_EXPLAIN

import json
import re
import shlex

SCRIPT = 'symbios-openvpn-client.sh'
WRITE_SCRIPT = 'symbios-write-openvpn-config.sh'
PLAYBOOK = 'base-services/openvpn-client.yml'

_NAME_RE = re.compile(r'^[a-zA-Z0-9_-]+$')


def _get_clients(vars_):
    """Return the openvpn_clients dict from inventory (never None)."""
    clients = vars_.get('openvpn_clients')
    return dict(clients) if isinstance(clients, dict) else {}


def _validate_name(name):
    return bool(name) and bool(_NAME_RE.match(name))


def _live_status():
    """Query the host for tunnel states, return the tunnels list."""
    try:
        ok, stdout, _ = run_command(f'{SCRIPT} list', timeout=15)
        if ok and stdout:
            data = json.loads(stdout)
            if isinstance(data, dict):
                return data.get('tunnels', []), data.get('openvpn_installed', True)
    except Exception:
        pass
    return [], None


def _merged_tunnels(clients, live):
    """Merge inventory tunnels with live host states.

    Tunnels known from inventory but not bound on the host (e.g. data
    volume not mounted yet) show up as down instead of vanishing.
    """
    by_name = {t.get('name'): t for t in live if t.get('name')}
    merged = list(live)
    for name, entry in clients.items():
        if name not in by_name:
            merged.append({
                'name': name,
                'active': False,
                'enabled': bool(entry.get('enabled', False)),
                'interface': entry.get('interface', ''),
                'ip': '',
                'fetch_mode': entry.get('mode', 'upload') == 'fetch',
            })
    return sorted(merged, key=lambda t: t.get('name', ''))


def _page_context(vars_, tunnels, installed):
    badge = get_page_badge('openvpn', vars_)
    return {
        'vars': vars_,
        'clients': _get_clients(vars_),
        'tunnels': tunnels,
        'openvpn_installed': installed,
        'page_key': 'openvpn',
        'page_icon': 'bi-hdd-network',
        'page_title': 'OpenVPN Client',
        'page_explain': PAGE_EXPLAIN['openvpn'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    }


@login_required
def settings_openvpn(request):
    """OpenVPN client tunnel manager (list, save, upload, control, delete)."""
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        action = request.POST.get('action', '')

        try:
            if action == 'save':
                # Save tunnel metadata (mode, interface, fetch source, ports).
                # Validation and the inventory write live in the settings CLI.
                name = request.POST.get('name', '').strip()
                mode = request.POST.get('mode', 'upload').strip()
                enabled = 'true' if request.POST.get('enabled') is not None else 'false'
                set_cmd = ('symbios-settings-openvpn.sh save'
                           f' --name {shlex.quote(name)}'
                           f' --mode {shlex.quote(mode)}'
                           f' --interface {shlex.quote(request.POST.get("interface", "").strip())}'
                           f' --fetch-cmd {shlex.quote(request.POST.get("fetch_cmd", "").strip())}'
                           f' --cron {shlex.quote(request.POST.get("cron", "").strip())}'
                           f' --ufw-ports {shlex.quote(request.POST.get("ufw_ports", ""))}'
                           f' --enabled {enabled}')
                ok, stdout, stderr = run_command(set_cmd, timeout=30)
                if not ok:
                    err = (stderr or stdout or 'Failed to save tunnel.')
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Error: {err}')
                    return redirect('settings_openvpn')

                cmd = f'symbios-run-playbook.sh {PLAYBOOK}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=300)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Applying tunnel {name}...',
                                         'message': f'Tunnel {name} saved.',
                                         'command': cmd})
                messages.success(request, f'Tunnel {name} saved.')
                messages.info(request, 'Applying OpenVPN playbook in the background...')
                from .utils.jobs import create_job
                create_job(cmd, timeout=300)
                return redirect('settings_openvpn')

            elif action == 'upload':
                # Upload a tunnel config (arrives via stdin, never on cmdline).
                name = request.POST.get('name', '').strip()
                cfg_text = request.POST.get('config', '')
                if not cfg_text or 'remote' not in cfg_text or 'dev' not in cfg_text:
                    msg = 'Invalid config: remote and dev directives required.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                enabled = request.POST.get('enabled') is not None
                # Derive the interface from the dev directive when possible.
                interface = 'tun0'
                for line in cfg_text.splitlines():
                    stripped = line.strip()
                    if stripped.startswith('dev '):
                        candidate = stripped.split()[1] if len(stripped.split()) > 1 else ''
                        if candidate not in ('tun', 'tap', 'null') and _validate_name(candidate):
                            interface = candidate
                        break

                # Metadata via the settings CLI (name validation included);
                # the config text itself goes to the writer via stdin.
                # An already stored interface wins over the derived one
                # (same as before: only new tunnels take the derived value).
                stored_iface = _get_clients(vars_).get(name, {}).get('interface', '')
                meta_cmd = ('symbios-settings-openvpn.sh save'
                            f' --name {shlex.quote(name)}'
                            ' --mode upload'
                            f' --enabled {"true" if enabled else "false"}')
                if not stored_iface:
                    meta_cmd += f' --interface {shlex.quote(interface)}'
                ok, stdout, stderr = run_command(meta_cmd, timeout=30)
                if not ok:
                    err = (stderr or stdout or 'Failed to save tunnel.')
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Error: {err}')
                    return redirect('settings_openvpn')

                cmd = f'{WRITE_SCRIPT} {shlex.quote(name)} && symbios-run-playbook.sh {PLAYBOOK}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=300, stdin_data=cfg_text)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Uploading tunnel {name}...',
                                         'message': f'Tunnel config {name} uploaded.',
                                         'command': cmd})
                ok, stdout, stderr = run_command(
                    cmd, timeout=120, stdin_data=cfg_text)
                if ok:
                    messages.success(request, f'Tunnel config {name} uploaded.')
                else:
                    messages.error(request, f'Upload failed: {(stderr or stdout)[:500]}')
                return redirect('settings_openvpn')

            elif action == 'tunnel':
                # Control a tunnel: up/down/enable/disable/fetch.
                name = request.POST.get('name', '').strip()
                op = request.POST.get('op', '').strip()
                if not _validate_name(name):
                    msg = 'Invalid tunnel name.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                if op not in ('up', 'down', 'enable', 'disable', 'fetch'):
                    msg = 'Unknown operation.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                if op in ('enable', 'disable'):
                    # Inventory flag via the settings CLI - only for known
                    # tunnels (same as before); the daemon control below
                    # runs regardless.
                    if name in _get_clients(vars_):
                        flag_cmd = ('symbios-settings-openvpn.sh save'
                                    f' --name {shlex.quote(name)}'
                                    ' --enabled {}'.format('true' if op == 'enable' else 'false'))
                        ok, stdout, stderr = run_command(flag_cmd, timeout=30)
                        if not ok:
                            err = (stderr or stdout or 'Failed to update tunnel.')
                            if is_ajax:
                                return JsonResponse({'ok': False, 'error': err}, status=400)
                            messages.error(request, f'Error: {err}')
                            return redirect('settings_openvpn')
                cmd = f'{SCRIPT} {op} {shlex.quote(name)}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=120)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Tunnel {name}: {op}...',
                                         'message': f'Running {op} on {name}.',
                                         'command': cmd})
                ok, stdout, stderr = run_command(cmd, timeout=60)
                if ok:
                    messages.success(request, f'Tunnel {name}: {op} done.')
                else:
                    messages.error(request, f'Failed: {(stderr or stdout)[:500]}')
                return redirect('settings_openvpn')

            elif action == 'delete':
                name = request.POST.get('name', '').strip()
                # Inventory entry via the settings CLI (name validation
                # included); the host-side tunnel is removed right after.
                meta_cmd = ('symbios-settings-openvpn.sh remove'
                            f' --name {shlex.quote(name)}')
                ok, stdout, stderr = run_command(meta_cmd, timeout=30)
                if not ok:
                    err = (stderr or stdout or 'Failed to delete tunnel.')
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Error: {err}')
                    return redirect('settings_openvpn')
                cmd = f'{SCRIPT} delete {shlex.quote(name)}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=60)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Deleting tunnel {name}...',
                                         'message': f'Tunnel {name} deleted.',
                                         'command': cmd})
                run_command(cmd, timeout=60)
                messages.success(request, f'Tunnel {name} deleted.')
                return redirect('settings_openvpn')

            else:
                msg = 'Unknown action.'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg}, status=400)
                messages.error(request, msg)
                return redirect('settings_openvpn')

        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
            return redirect('settings_openvpn')

    # GET: render with live host status merged into the inventory tunnels.
    tunnels, installed = _live_status()
    tunnels = _merged_tunnels(_get_clients(vars_), tunnels)
    return render(request, 'main/settings_openvpn.html',
                  _page_context(vars_, tunnels, installed))


@login_required
def settings_openvpn_status(request):
    """AJAX GET - live tunnel states for refresh without page reload."""
    tunnels, installed = _live_status()
    try:
        vars_ = _get_inventory_config().get('all', {}).get('vars', {})
        tunnels = _merged_tunnels(_get_clients(vars_), tunnels)
    except Exception:
        pass
    return JsonResponse({'tunnels': tunnels, 'openvpn_installed': installed})


@login_required
def settings_openvpn_log(request):
    """AJAX GET - last journal lines of one tunnel (?name=, ?lines=50)."""
    name = request.GET.get('name', '').strip()
    lines = request.GET.get('lines', '50').strip()
    if not _validate_name(name):
        return JsonResponse({'ok': False, 'error': 'Invalid tunnel name'}, status=400)
    if not lines.isdigit():
        lines = '50'
    try:
        ok, stdout, stderr = run_command(
            f'{SCRIPT} log {shlex.quote(name)} {shlex.quote(lines)}', timeout=15)
        if ok:
            return JsonResponse({'ok': True, 'log': stdout})
        return JsonResponse({'ok': False, 'error': (stderr or stdout)[:500]})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)}, status=500)
