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
import shlex
import urllib.request
from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .setup_status import get_page_badge, PAGE_EXPLAIN


def _badge(key, vars_):
    """Small helper: compute the page status badge (status, label, text)."""
    return get_page_badge(key, vars_)


def _matrix_account_complete(vars_):
    """True when the matrix sender account is fully configured."""
    return bool(vars_.get('matrix_homeserver')
                and vars_.get('matrix_user')
                and vars_.get('matrix_room')
                and (vars_.get('matrix_password') or vars_.get('matrix_token')))


def _smtp_ready(vars_):
    """True when the SMTP relay is configured."""
    return bool(vars_.get('smtp_server') and vars_.get('smtp_from'))


@login_required
def settings_matrix(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            if request.POST.get('action') == 'delete':
                # The key deletion lives in the settings CLI.
                set_cmd = 'symbios-settings-matrix.sh remove'
                if is_ajax:
                    from .utils.jobs import create_job
                    cmd = f'{set_cmd} && symbios-run-playbook.sh base-services/matrix-client.yml'
                    job_id = create_job(cmd, timeout=3600)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Deleting matrix account...',
                                         'message': 'Matrix account deleted.',
                                         'command': cmd})
                ok, stdout, stderr = run_command(set_cmd, timeout=30)
                if not ok:
                    messages.error(request, f'Error: {stderr or stdout}')
                return redirect('settings_matrix')

            # Secrets travel via stdin JSON, never as argv (visible in ps).
            # Homeserver normalization and ID/room validation live in the
            # script; the live reachability probe below stays Python.
            payload = json.dumps({
                'matrix_homeserver': request.POST.get('matrix_homeserver', '').strip(),
                'matrix_user': request.POST.get('matrix_user', '').strip(),
                'matrix_password': request.POST.get('matrix_password', '').strip(),
                'matrix_token': request.POST.get('matrix_token', '').strip(),
                'matrix_room': request.POST.get('matrix_room', '').strip(),
            })
            set_cmd = 'symbios-settings-matrix.sh set --json-stdin'

            # Authoritative validation first (no write): the probe needs a
            # well-formed URL for a meaningful error.
            ok, stdout, stderr = run_command(
                f'{set_cmd} --check', timeout=30, stdin_data=payload)
            if not ok:
                err = (stderr or stdout or 'Invalid matrix account.')
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': err}, status=400)
                messages.error(request, err)
                return redirect('settings_matrix')

            homeserver = request.POST.get('matrix_homeserver', '').strip().rstrip('/')
            if not homeserver.startswith(('http://', 'https://')):
                homeserver = 'https://' + homeserver
            ok, err = _probe_homeserver(homeserver)
            if not ok:
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': err}, status=400)
                messages.error(request, err)
                return redirect('settings_matrix')

            cmd = f'{set_cmd} && symbios-run-playbook.sh base-services/matrix-client.yml'
            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=3600, stdin_data=payload)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Applying matrix account...',
                                     'message': 'Matrix account saved. Verify the new device, then check the room.',
                                     'command': cmd})
            # Fallback saves without applying (same as before).
            ok, stdout, stderr = run_command(set_cmd, timeout=30,
                                            stdin_data=payload)
            if not ok:
                messages.error(request, f'Error: {stderr or stdout}')
            else:
                messages.success(request, 'Matrix account saved.')
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_matrix')

    return render(request, 'main/settings_matrix.html', {'vars': vars_,
                                                        'page_key': 'matrix',
                                                        'page_icon': 'bi-chat-dots',
                                                        'page_title': 'Matrix Account',
                                                        'page_explain': PAGE_EXPLAIN['matrix'],
                                                        'page_status': _badge('matrix', vars_)[0],
                                                        'page_status_label': _badge('matrix', vars_)[1],
                                                        'page_status_text': _badge('matrix', vars_)[2]})


def _probe_homeserver(homeserver):
    """Check that a homeserver answers /_matrix/client/versions. Returns (ok, message)."""
    url = homeserver.rstrip('/') + '/_matrix/client/versions'
    try:
        req = urllib.request.Request(url, headers={'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode('utf-8', errors='replace'))
            versions = data.get('versions', [])
            return True, f'Homeserver reachable ({len(versions)} API versions).'
    except Exception as e:
        return False, f'Homeserver not reachable at {homeserver}: {e}'


@login_required
def settings_matrix_probe(request):
    """AJAX GET - probe a homeserver without saving anything."""
    homeserver = request.GET.get('homeserver', '').strip().rstrip('/')
    if not homeserver:
        return JsonResponse({'ok': False, 'error': 'No homeserver URL provided.'})
    if not homeserver.startswith(('http://', 'https://')):
        homeserver = 'https://' + homeserver
    ok, msg = _probe_homeserver(homeserver)
    if ok:
        return JsonResponse({'ok': True, 'message': msg, 'homeserver': homeserver})
    return JsonResponse({'ok': False, 'error': msg})


@login_required
def settings_notifications(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        # Preconditions (sender configured) and the inventory write live
        # in the settings CLI (single source of truth).
        set_cmd = ('symbios-settings-notifications.sh set'
                   f' --mail {shlex.quote(request.POST.get("notify_mail_enabled", "false"))}'
                   f' --matrix {shlex.quote(request.POST.get("notify_matrix_enabled", "false"))}'
                   f' --to {shlex.quote(request.POST.get("notify_mail_to", "").strip())}'
                   f' --level {shlex.quote(request.POST.get("notify_level", "warn").strip())}')
        try:
            ok, stdout, stderr = run_command(set_cmd, timeout=30)
            if not ok:
                err = (stderr or stdout or 'Failed to save notification settings.')
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': err}, status=400)
                messages.error(request, f'Error: {err}')
                return redirect('settings_notifications')
            matrix_enabled = request.POST.get('notify_matrix_enabled') == 'true'
            # Chain matrix-client first when matrix is enabled so the
            # daemon is up before the alias points at its FIFO.
            cmds = []
            if matrix_enabled:
                cmds.append('symbios-run-playbook.sh base-services/matrix-client.yml')
            cmds.append('symbios-run-playbook.sh base-services/notifications.yml')
            cmd = ' && '.join(cmds)
            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=3600)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Applying notification settings...',
                                     'message': 'Notification settings saved.',
                                     'command': cmd})
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_notifications')

    return render(request, 'main/settings_notifications.html', {
        'vars': vars_,
        'smtp_ready': _smtp_ready(vars_),
        'matrix_ready': _matrix_account_complete(vars_),
        'page_key': 'notifications',
        'page_icon': 'bi-bell',
        'page_title': 'Notifications',
        'page_explain': PAGE_EXPLAIN['notifications'],
        'page_status': _badge('notifications', vars_)[0],
        'page_status_label': _badge('notifications', vars_)[1],
        'page_status_text': _badge('notifications', vars_)[2]})


@login_required
def settings_notifications_test_mail(request):
    """AJAX POST - send a test mail via the saved SMTP settings."""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'})
    from .views_mailserver import _send_test_email
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    to_address = (vars_.get('notify_mail_to') or vars_.get('smtp_from', '')).strip()
    if not to_address:
        return JsonResponse({'error': 'No recipient: set a notification address or configure SMTP first.'})
    ok, err = _send_test_email(vars_.get('smtp_server', ''), vars_.get('smtp_port', ''),
                               vars_.get('smtp_user', ''), vars_.get('smtp_password', ''),
                               vars_.get('smtp_from', ''), to_address,
                               vars_.get('smtp_tls', ''))
    if ok:
        return JsonResponse({'success': f'Test notification sent to {to_address}.'})
    return JsonResponse({'error': f'Failed to send: {err}'})


@login_required
def settings_notifications_test_matrix(request):
    """AJAX POST - push a test notification through the matrix daemon on the host."""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'})
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    if not _matrix_account_complete(vars_):
        return JsonResponse({'error': 'No matrix account configured.'})
    body = 'SymbiOS matrix notification test. If you read this, delivery works (E2EE encrypted).'
    cmd = f"printf {shlex.quote(body)} | /usr/local/bin/notify.sh -s {shlex.quote('SymbiOS test notification')}"
    try:
        ok, stdout, stderr = run_command(cmd, timeout=30)
    except Exception as e:
        return JsonResponse({'error': f'Host command failed: {e}'})
    if ok:
        room = vars_.get('matrix_room', '')
        return JsonResponse({'success': f'Test notification handed to the matrix daemon. Check room {room} for arrival.'})
    return JsonResponse({'error': f'Delivery failed: {(stderr or stdout or "unknown error")[:500]}'})
