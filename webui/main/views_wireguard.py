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

SCRIPT = 'symbios-wireguard-client.sh'
WRITE_SCRIPT = 'symbios-write-wireguard-config.sh'
SETTINGS_SCRIPT = 'symbios-settings-wireguard.sh'
PLAYBOOK = 'base-services/wireguard-client.yml'

# The tunnel name doubles as the WireGuard interface name (15 chars, IFNAMSIZ).
_NAME_RE = re.compile(r'^[a-zA-Z0-9_-]{1,15}$')


def _get_tunnels(vars_):
    """Return the wireguard_clients dict from inventory (never None)."""
    tunnels = vars_.get('wireguard_clients')
    return dict(tunnels) if isinstance(tunnels, dict) else {}


def _validate_name(name):
    return bool(name) and bool(_NAME_RE.match(name))


def _live_status():
    """Query the host for tunnel states, return (tunnels, installed)."""
    try:
        ok, stdout, _ = run_command(f'{SCRIPT} list', timeout=15)
        if ok and stdout:
            data = json.loads(stdout)
            if isinstance(data, dict):
                return data.get('tunnels', []), data.get('wireguard_installed', True)
    except Exception:
        pass
    return [], None


def _merged_tunnels(tunnels, live):
    """Merge inventory tunnels with live host states.

    Tunnels known from inventory but without a config on the host (e.g. data
    volume not mounted yet) show up as down instead of vanishing.
    """
    by_name = {t.get('name'): t for t in live if t.get('name')}
    merged = list(live)
    for name, entry in tunnels.items():
        if name not in by_name:
            merged.append({
                'name': name,
                'active': False,
                'enabled': bool(entry.get('enabled', False)),
                'interface': name,
                'ip4': '',
                'ip6': '',
                'peers': 0,
                'endpoint': '',
                'handshake_age': -1,
                'rx_bytes': 0,
                'tx_bytes': 0,
            })
    return sorted(merged, key=lambda t: t.get('name', ''))


def _page_context(vars_, tunnels, installed):
    badge = get_page_badge('wireguard', vars_)
    return {
        'vars': vars_,
        'tunnels_cfg': _get_tunnels(vars_),
        'tunnels': tunnels,
        'wireguard_installed': installed,
        'page_key': 'wireguard',
        'page_icon': 'bi-shield-lock',
        'page_title': 'WireGuard Client',
        'page_explain': PAGE_EXPLAIN['wireguard'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    }


@login_required
def settings_wireguard(request):
    """WireGuard client tunnel manager (list, save, upload, control, delete)."""
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
                # Save tunnel metadata (enabled, dns, hooks, ports).
                # Validation and the inventory write live in the settings CLI.
                name = request.POST.get('name', '').strip()
                enabled = 'true' if request.POST.get('enabled') is not None else 'false'
                dns = 'true' if request.POST.get('dns') is not None else 'false'
                hooks = 'true' if request.POST.get('hooks') is not None else 'false'
                set_cmd = (f'{SETTINGS_SCRIPT} save'
                           f' --name {shlex.quote(name)}'
                           f' --enabled {enabled}'
                           f' --dns {dns}'
                           f' --hooks {hooks}'
                           f' --ufw-ports {shlex.quote(request.POST.get("ufw_ports", ""))}')
                ok, stdout, stderr = run_command(set_cmd, timeout=30)
                if not ok:
                    err = (stderr or stdout or 'Failed to save tunnel.')
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Error: {err}')
                    return redirect('settings_wireguard')

                cmd = f'symbios-run-playbook.sh {PLAYBOOK}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=300)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Applying tunnel {name}...',
                                         'message': f'Tunnel {name} saved.',
                                         'command': cmd})
                messages.success(request, f'Tunnel {name} saved.')
                messages.info(request, 'Applying WireGuard playbook in the background...')
                from .utils.jobs import create_job
                create_job(cmd, timeout=300)
                return redirect('settings_wireguard')

            elif action == 'upload':
                # Upload a tunnel config (arrives via stdin, never on cmdline).
                name = request.POST.get('name', '').strip()
                cfg_text = request.POST.get('config', '')
                if not cfg_text.strip():
                    msg = 'Empty config - paste or select a WireGuard config file.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_wireguard')
                enabled = request.POST.get('enabled') is not None

                # The writer validates the config text (sections, keys, size)
                # and stores it - before the metadata, so a rejected config
                # never leaves an inventory entry without a config file.
                ok, stdout, stderr = run_command(
                    f'{WRITE_SCRIPT} {shlex.quote(name)}', timeout=60,
                    stdin_data=cfg_text)
                if not ok:
                    err = (stderr or stdout or 'Upload failed.')
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Upload failed: {err[:500]}')
                    return redirect('settings_wireguard')

                # Metadata via the settings CLI (name validation included).
                meta_cmd = (f'{SETTINGS_SCRIPT} save'
                            f' --name {shlex.quote(name)}'
                            f' --enabled {"true" if enabled else "false"}')
                ok, stdout, stderr = run_command(meta_cmd, timeout=30)
                if not ok:
                    err = (stderr or stdout or 'Failed to save tunnel.')
                    # Drop the config again: no orphan without metadata.
                    run_command(f'{SCRIPT} delete {shlex.quote(name)}', timeout=60)
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': err}, status=400)
                    messages.error(request, f'Error: {err}')
                    return redirect('settings_wireguard')

                cmd = f'symbios-run-playbook.sh {PLAYBOOK}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=300)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Uploading tunnel {name}...',
                                         'message': f'Tunnel config {name} uploaded.',
                                         'command': cmd})
                messages.success(request, f'Tunnel config {name} uploaded.')
                messages.info(request, 'Applying WireGuard playbook in the background...')
                from .utils.jobs import create_job
                create_job(cmd, timeout=300)
                return redirect('settings_wireguard')

            elif action == 'tunnel':
                # Control a tunnel: up/down/enable/disable. Enable/disable also
                # persist the inventory flag (the host script owns both).
                name = request.POST.get('name', '').strip()
                op = request.POST.get('op', '').strip()
                if not _validate_name(name):
                    msg = 'Invalid tunnel name.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_wireguard')
                if op not in ('up', 'down', 'enable', 'disable'):
                    msg = 'Unknown operation.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_wireguard')
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
                return redirect('settings_wireguard')

            elif action == 'delete':
                # The host script removes inventory entry, unit state, bind
                # mount, config and runtime copy in one go.
                name = request.POST.get('name', '').strip()
                if not _validate_name(name):
                    msg = 'Invalid tunnel name.'
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': msg}, status=400)
                    messages.error(request, msg)
                    return redirect('settings_wireguard')
                cmd = f'{SCRIPT} delete {shlex.quote(name)}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=60)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': f'Deleting tunnel {name}...',
                                         'message': f'Tunnel {name} deleted.',
                                         'command': cmd})
                ok, stdout, stderr = run_command(cmd, timeout=60)
                if ok:
                    messages.success(request, f'Tunnel {name} deleted.')
                else:
                    messages.error(request, f'Failed: {(stderr or stdout)[:500]}')
                return redirect('settings_wireguard')

            else:
                msg = 'Unknown action.'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg}, status=400)
                messages.error(request, msg)
                return redirect('settings_wireguard')

        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
            return redirect('settings_wireguard')

    # GET: render with live host status merged into the inventory tunnels.
    tunnels, installed = _live_status()
    tunnels = _merged_tunnels(_get_tunnels(vars_), tunnels)
    return render(request, 'main/settings_wireguard.html',
                  _page_context(vars_, tunnels, installed))


@login_required
def settings_wireguard_status(request):
    """AJAX GET - live tunnel states for refresh without page reload."""
    tunnels, installed = _live_status()
    try:
        vars_ = _get_inventory_config().get('all', {}).get('vars', {})
        tunnels = _merged_tunnels(_get_tunnels(vars_), tunnels)
    except Exception:
        pass
    return JsonResponse({'tunnels': tunnels, 'wireguard_installed': installed})


@login_required
def settings_wireguard_log(request):
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
