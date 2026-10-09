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
from django.http import JsonResponse
from .decorators import login_required
from .views import _get_inventory_config
from .utils.ssh_exec import run_command


def _matrix_account_complete(vars_):
    """True when the matrix sender account is fully configured."""
    return bool(vars_.get('matrix_homeserver')
                and vars_.get('matrix_user')
                and vars_.get('matrix_room')
                and (vars_.get('matrix_password') or vars_.get('matrix_token')))


def _smtp_ready(vars_):
    """True when the SMTP relay is configured."""
    return bool(vars_.get('smtp_server') and vars_.get('smtp_from'))



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
    if not homeserver and request.method == 'POST':
        # Generic schema forms POST their fields (same names).
        homeserver = request.POST.get('homeserver',
                                      request.POST.get('matrix_homeserver', '')).strip().rstrip('/')
    if not homeserver:
        return JsonResponse({'ok': False, 'error': 'No homeserver URL provided.'})
    if not homeserver.startswith(('http://', 'https://')):
        homeserver = 'https://' + homeserver
    ok, msg = _probe_homeserver(homeserver)
    if ok:
        return JsonResponse({'ok': True, 'message': msg, 'homeserver': homeserver})
    return JsonResponse({'ok': False, 'error': msg})



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
