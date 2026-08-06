# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .setup_status import get_page_badge, PAGE_EXPLAIN

import json


SCRIPT = 'symbios-router-upnp.sh'


def _run_upnp(args, timeout=15):
    cmd = f'{SCRIPT} {args}'
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    # The router script always emits a single JSON line on stdout, even for
    # expected failures (e.g. a rule the router refuses), which it signals
    # with exit code 1. Parse stdout first and let the caller see the real
    # error; the raw stderr only carries shell-banner noise and must not
    # shadow the structured answer.
    try:
        return json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        pass
    if not ok:
        raise RuntimeError(stderr or 'Command failed')
    raise RuntimeError(f'Invalid JSON from script: {stdout[:500]}')


def _add_ufw_extra_inbound(ext_port, protocol):
    """Record an IPv6 port forward in inventory so a reapply re-opens UFW."""
    try:
        port = int(ext_port)
    except (TypeError, ValueError):
        return
    proto = protocol.lower()
    if proto not in ('tcp', 'udp'):
        return
    from .views import _get_inventory_config, _save_inventory_config
    config = _get_inventory_config()
    vars_ = config.setdefault('all', {}).setdefault('vars', {})
    entries = vars_.setdefault('ufw_extra_inbound', [])
    entry = {'port': port, 'proto': proto}
    if entry not in entries:
        entries.append(entry)
        _save_inventory_config(config)


def _remove_ufw_extra_inbound(ext_port, protocol):
    """Remove a recorded IPv6 port forward from inventory."""
    from .views import _get_inventory_config, _save_inventory_config
    config = _get_inventory_config()
    vars_ = config.setdefault('all', {}).setdefault('vars', {})
    entries = vars_.get('ufw_extra_inbound', [])
    kept = [e for e in entries
            if str(e.get('port', '')) != str(ext_port)
            or str(e.get('proto', '')).lower() != protocol.lower()]
    if len(kept) != len(entries):
        vars_['ufw_extra_inbound'] = kept
        _save_inventory_config(config)


def _get_local_ip():
    """Get the host's primary LAN IP for the default forwarding target."""
    try:
        ok, stdout, _ = run_command('symbios-get-local-ip.sh', timeout=10)
        if ok and stdout:
            return stdout.strip()
    except Exception:
        pass
    return ''


@login_required
def settings_port_forwarding(request):
    """Main port forwarding settings page with router detection."""
    from .views import _get_inventory_config
    config = _get_inventory_config()
    vars_ = (config.get('all', {}).get('vars', {}) if isinstance(config, dict) else {})

    is_ajax = is_ajax_request(request)

    # Change actions must not repeat the expensive GET-time router introspection
    # (IPv6 status ~9s, mapping list ~7s). Resolve only what each action needs
    # so the exec-modal gets the job id immediately.
    if request.method == 'POST':
        action = request.POST.get('action', '')

        try:
            if action == 'save-credentials':
                username = request.POST.get('username', '').strip()
                password = request.POST.get('password', '').strip()
                result = _run_upnp(f'config {_shell_quote(username)} {_shell_quote(password)}', timeout=10)
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job('echo "Router UPnP credentials saved"', timeout=5)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Saving router UPnP credentials...',
                                         'message': 'Credentials saved successfully.'})
                messages.success(request, 'Router UPnP credentials saved.')
                return redirect('settings_port_forwarding')

            elif action == 'quick-enable':
                # One-click: ensure static IP (FRITZ!Box), then add all
                # preset rules (HTTP 80, HTTPS 443, SSH 33).
                # Runs via the exec modal job so the user sees live output.
                from .utils.jobs import create_job
                local_ip = _get_local_ip()
                router_info = None
                try:
                    router_info = _run_upnp('detect', timeout=10)
                except Exception:
                    router_info = None
                static_ip_cmd = ''
                if router_info and router_info.get('router_type') == 'fritzbox' and local_ip:
                    static_ip_cmd = (f'{SCRIPT} staticip {_shell_quote(local_ip)} && ')
                cmd = (static_ip_cmd +
                       f'{SCRIPT} add 80 TCP 80 {_shell_quote(local_ip)} "SymbiOS HTTP" && '
                       f'{SCRIPT} add 443 TCP 443 {_shell_quote(local_ip)} "SymbiOS HTTPS" && '
                       f'{SCRIPT} add 33 TCP 22 {_shell_quote(local_ip)} "SymbiOS SSH"')
                if is_ajax:
                    job_id = create_job(cmd, timeout=90)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Enabling port forwarding...',
                                         'message': 'Ensuring static IP and opening ports 80, 443 and 33 on the router.'})
                ok, stdout, stderr = run_command(cmd, timeout=90)
                if ok:
                    messages.success(request, 'Port forwarding rules added.')
                else:
                    messages.error(request, f'Failed: {stderr or stdout}')
                return redirect('settings_port_forwarding')

            elif action == 'add':
                ext_port = request.POST.get('ext_port', '').strip()
                protocol = request.POST.get('protocol', 'TCP').strip().upper()
                int_port = request.POST.get('int_port', '').strip()
                int_client = request.POST.get('int_client', '').strip()
                description = request.POST.get('description', 'SymbiOS').strip()
                accesstype = request.POST.get('accesstype', 'ipv4').strip()

                if accesstype not in ('ipv4', 'ipv6', 'ipv4_ipv6'):
                    accesstype = 'ipv4'

                if not ext_port or not int_port or not int_client:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'All port fields are required'}, status=400)
                    messages.error(request, 'All port fields are required.')
                    return redirect('settings_port_forwarding')

                args = (f'add {ext_port} {protocol} {int_port} {int_client} '
                        f'{_shell_quote(description)} {accesstype}')
                # IPv6 forwards connect directly to the host's GUA, so an
                # extra UFW allow rule is needed on the host. Keep the
                # inventory in sync so a reapply re-creates it.
                if accesstype in ('ipv6', 'ipv4_ipv6'):
                    _add_ufw_extra_inbound(ext_port, protocol)
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(f'{SCRIPT} {args}', timeout=15)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Adding port forwarding...',
                                         'message': 'Port forwarding added.'})
                result = _run_upnp(args, timeout=15)
                if result.get('ok'):
                    messages.success(request, result.get('message', 'Port forwarding added.'))
                else:
                    messages.error(request, result.get('error', 'Failed to add port forwarding.'))
                return redirect('settings_port_forwarding')

            elif action == 'delete':
                ext_port = request.POST.get('ext_port', '').strip()
                protocol = request.POST.get('protocol', 'TCP').strip().upper()
                if not ext_port:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'Port number required'}, status=400)
                    messages.error(request, 'Port number required.')
                    return redirect('settings_port_forwarding')

                args = f'delete {ext_port} {protocol}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(f'{SCRIPT} {args}', timeout=15)
                    _remove_ufw_extra_inbound(ext_port, protocol)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Deleting port forwarding...',
                                         'message': 'Port forwarding deleted.'})
                result = _run_upnp(args, timeout=15)
                if result.get('ok'):
                    _remove_ufw_extra_inbound(ext_port, protocol)
                    messages.success(request, result.get('message', 'Port forwarding deleted.'))
                else:
                    messages.error(request, result.get('error', 'Failed to delete port forwarding.'))
                return redirect('settings_port_forwarding')

        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
            return redirect('settings_port_forwarding')

    # --- GET: full page render ---
    router_info = None
    detect_error = None
    try:
        router_info = _run_upnp('detect', timeout=10)
    except Exception as e:
        detect_error = str(e)

    # Check if credentials are stored
    credentials_configured = False
    try:
        cfg = _run_upnp('config', timeout=10)
        credentials_configured = cfg.get('configured', False)
    except Exception:
        pass

    # Get local IP for default suggestion
    local_ip = _get_local_ip()

    # IPv6 state (FRITZ!Box only, read-only)
    ipv6_info = None
    try:
        if router_info and router_info.get('router_type') == 'fritzbox':
            ipv6_info = _run_upnp('ipv6info', timeout=20)
    except Exception:
        ipv6_info = None

    # GET: list current mappings
    # FRITZ!Box requires credentials; generic UPnP does not
    should_list = credentials_configured
    if router_info and router_info.get('router_type') == 'generic_upnp':
        should_list = True
    mappings = []
    list_error = None
    if should_list:
        try:
            list_result = _run_upnp('list', timeout=15)
            if list_result.get('ok'):
                mappings = list_result.get('mappings', [])
            else:
                list_error = list_result.get('error', 'Failed to list mappings')
        except Exception as e:
            list_error = str(e)

    return render(request, 'main/settings_port_forwarding.html', {
        'router_info': router_info,
        'detect_error': detect_error,
        'credentials_configured': credentials_configured,
        'local_ip': local_ip,
        'mappings': mappings,
        'list_error': list_error,
        'ipv6_info': ipv6_info,
        'page_key': 'port-forwarding',
        'page_icon': 'bi-diagram-3',
        'page_title': 'Port Forwarding',
        'page_explain': PAGE_EXPLAIN['port-forwarding'],
        'page_status': get_page_badge('port-forwarding', vars_)[0],
        'page_status_label': get_page_badge('port-forwarding', vars_)[1],
        'page_status_text': get_page_badge('port-forwarding', vars_)[2],
    })


@login_required
def settings_port_forwarding_detect(request):
    """AJAX GET — re-detect router (for live refresh)."""
    try:
        router_info = _run_upnp('detect', timeout=10)
        return JsonResponse(router_info)
    except Exception as e:
        return JsonResponse({'available': False, 'error': str(e)})


@login_required
def settings_port_forwarding_list(request):
    """AJAX GET — list port mappings (for live refresh)."""
    try:
        result = _run_upnp('list', timeout=15)
        return JsonResponse(result)
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e), 'mappings': []})


@login_required
def settings_port_forwarding_config(request):
    """AJAX GET/POST — manage router UPnP credentials."""
    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        username = request.POST.get('username', '').strip()
        password = request.POST.get('password', '').strip()
        try:
            ok, stdout, stderr = run_command(
                f'{SCRIPT} config {_shell_quote(username)} {_shell_quote(password)}',
                timeout=10
            )
            if ok and stdout:
                result = json.loads(stdout)
                return JsonResponse(result)
            return JsonResponse({'ok': False, 'error': stderr or 'Failed to save credentials'})
        except Exception as e:
            return JsonResponse({'ok': False, 'error': str(e)})

    # GET: return current config status
    try:
        result = _run_upnp('config', timeout=10)
        return JsonResponse(result)
    except Exception as e:
        return JsonResponse({'ok': True, 'configured': False, 'error': str(e)})


def _shell_quote(s):
    """Simple shell-safe quoting — wrap in single quotes and escape internal single quotes."""
    if not s:
        return "''"
    escaped = s.replace("'", "'\\''")
    return f"'{escaped}'"
