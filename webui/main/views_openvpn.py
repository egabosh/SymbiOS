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


def _parse_ufw_ports(text):
    """Parse '8123/tcp, 8889/tcp' into [{port, proto}]."""
    rules = []
    for part in (text or '').split(','):
        part = part.strip()
        if not part:
            continue
        if '/' in part:
            port, proto = part.split('/', 1)
        else:
            port, proto = part, 'tcp'
        port = port.strip()
        proto = proto.strip().lower()
        if not port.isdigit() or int(port) < 1 or int(port) > 65535:
            raise ValueError(f'Invalid port: {port}')
        if proto not in ('tcp', 'udp'):
            raise ValueError(f'Invalid protocol: {proto}')
        rules.append({'port': int(port), 'proto': proto})
    return rules


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
                name = request.POST.get('name', '').strip()
                if not _validate_name(name):
                    msg = 'Invalid tunnel name (a-z, 0-9, _ and - only).'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                mode = request.POST.get('mode', 'upload').strip()
                if mode not in ('upload', 'fetch'):
                    mode = 'upload'
                interface = request.POST.get('interface', '').strip() or 'tun0'
                if not _validate_name(interface):
                    msg = 'Invalid interface name.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                fetch_cmd = request.POST.get('fetch_cmd', '').strip()
                cron = request.POST.get('cron', '').strip() or '*/5 * * * *'
                if len(cron.split()) != 5:
                    msg = 'Refresh schedule must have 5 fields (e.g. */5 * * * *).'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                if mode == 'fetch' and not fetch_cmd:
                    msg = 'Fetch mode needs a fetch command.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                try:
                    ufw_allow = _parse_ufw_ports(request.POST.get('ufw_ports', ''))
                except ValueError as e:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': str(e)}, status=400)
                    messages.error(request, str(e))
                    return redirect('settings_openvpn')
                enabled = request.POST.get('enabled') is not None

                clients = _get_clients(vars_)
                entry = clients.get(name, {})
                entry.update({
                    'enabled': enabled,
                    'mode': mode,
                    'interface': interface,
                    'fetch_cmd': fetch_cmd,
                    'cron': cron,
                    'ufw_allow': ufw_allow,
                })
                clients[name] = entry
                vars_['openvpn_clients'] = clients
                vars_['openvpn_configured'] = True
                _save_inventory_config(config)

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
                if not _validate_name(name):
                    msg = 'Invalid tunnel name (a-z, 0-9, _ and - only).'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
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

                clients = _get_clients(vars_)
                entry = clients.get(name, {})
                entry.update({
                    'enabled': enabled,
                    'mode': 'upload',
                    'interface': entry.get('interface', interface),
                })
                entry.setdefault('cron', '*/5 * * * *')
                entry.setdefault('fetch_cmd', '')
                entry.setdefault('ufw_allow', [])
                clients[name] = entry
                vars_['openvpn_clients'] = clients
                vars_['openvpn_configured'] = True
                _save_inventory_config(config)

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
                    clients = _get_clients(vars_)
                    if name in clients:
                        clients[name]['enabled'] = (op == 'enable')
                        vars_['openvpn_clients'] = clients
                        _save_inventory_config(config)
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
                if not _validate_name(name):
                    msg = 'Invalid tunnel name.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_openvpn')
                clients = _get_clients(vars_)
                clients.pop(name, None)
                vars_['openvpn_clients'] = clients
                _save_inventory_config(config)
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
    return render(request, 'main/settings_openvpn.html',
                  _page_context(vars_, tunnels, installed))


@login_required
def settings_openvpn_status(request):
    """AJAX GET - live tunnel states for refresh without page reload."""
    tunnels, installed = _live_status()
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
