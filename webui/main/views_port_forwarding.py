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

import json


SCRIPT = 'symbios-router-upnp.sh'


def _run_upnp(args, timeout=15):
    cmd = f'{SCRIPT} {args}'
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    if not ok:
        raise RuntimeError(stderr or 'Command failed')
    try:
        return json.loads(stdout)
    except (json.JSONDecodeError, ValueError) as e:
        raise RuntimeError(f'Invalid JSON from script: {stdout[:500]}') from e


@login_required
def settings_port_forwarding(request):
    """Main port forwarding settings page with router detection."""
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
    local_ip = ''
    try:
        ok, stdout, _ = run_command('symbios-get-local-ip.sh', timeout=10)
        if ok and stdout:
            local_ip = stdout.strip()
    except Exception:
        pass

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
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

            elif action == 'add':
                ext_port = request.POST.get('ext_port', '').strip()
                protocol = request.POST.get('protocol', 'TCP').strip().upper()
                int_port = request.POST.get('int_port', '').strip()
                int_client = request.POST.get('int_client', '').strip()
                description = request.POST.get('description', 'SymbiOS').strip()

                if not ext_port or not int_port or not int_client:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'All port fields are required'}, status=400)
                    messages.error(request, 'All port fields are required.')
                    return redirect('settings_port_forwarding')

                args = f'add {ext_port} {protocol} {int_port} {int_client} {_shell_quote(description)}'
                result = _run_upnp(args, timeout=15)
                if result.get('ok'):
                    if is_ajax:
                        from .utils.jobs import create_job
                        job_id = create_job(f'{SCRIPT} {args}', timeout=15)
                        return JsonResponse({'ok': True, 'job': job_id,
                                             'title': 'Adding port forwarding...',
                                             'message': result.get('message', 'Port forwarding added.')})
                    messages.success(request, result.get('message', 'Port forwarding added.'))
                else:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': result.get('error', 'Failed to add')}, status=400)
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
                result = _run_upnp(args, timeout=15)
                if result.get('ok'):
                    if is_ajax:
                        from .utils.jobs import create_job
                        job_id = create_job(f'{SCRIPT} {args}', timeout=15)
                        return JsonResponse({'ok': True, 'job': job_id,
                                             'title': 'Deleting port forwarding...',
                                             'message': result.get('message', 'Port forwarding deleted.')})
                    messages.success(request, result.get('message', 'Port forwarding deleted.'))
                else:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': result.get('error', 'Failed to delete')}, status=400)
                    messages.error(request, result.get('error', 'Failed to delete port forwarding.'))
                return redirect('settings_port_forwarding')

        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
            return redirect('settings_port_forwarding')

    # GET: list current mappings
    mappings = []
    list_error = None
    if credentials_configured:
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
