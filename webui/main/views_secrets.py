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

"""WebUI for the central encrypted secret store.

The list only receives names and rotation metadata. Values are read, written
and rotated exclusively by host scripts through the exec gateway. The explicit
reveal endpoint returns one value synchronously to the browser; it never uses a
job. The host audit records the requesting user and secret name, never the value.
"""

import json
import re
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .setup_status import PAGE_EXPLAIN
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .views_users import _exec_ldap_command

SECRET_NAME_RE = re.compile(
    r'^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$')


def _load_store():
    """Fetch names and metadata; never request or parse a secret value."""
    ok, stdout, stderr = run_command('symbios-secrets-list.sh --json', timeout=30)
    if not ok:
        return {
            'initialized': False,
            'secrets': [],
            'error': stderr.strip() or 'Could not read the secret store.',
        }
    try:
        data = json.loads(stdout.strip())
    except (ValueError, AttributeError):
        return {
            'initialized': False,
            'secrets': [],
            'error': 'The secret store returned invalid JSON.',
        }
    if not isinstance(data, dict):
        return {
            'initialized': False,
            'secrets': [],
            'error': 'The secret store returned an unexpected response.',
        }
    secrets = data.get('secrets')
    if not isinstance(secrets, list):
        secrets = []
    return {
        'initialized': bool(data.get('initialized')),
        'secrets': [entry for entry in secrets if isinstance(entry, dict)],
        'error': '',
    }


def _secret_name(request):
    """Return a validated secret name from POST, or None."""
    name = request.POST.get('name', '').strip()
    if not name or not SECRET_NAME_RE.match(name):
        return None
    return name


def _error(request, msg):
    """Return an AJAX error or a message + redirect for sync posts."""
    if is_ajax_request(request):
        return JsonResponse({'ok': False, 'error': msg}, status=400)
    messages.error(request, msg)
    return redirect('settings_secrets')


@login_required
def settings_secrets(request):
    store = _load_store()
    if store['error']:
        status, label, detail = 'error', 'Store error', store['error']
    elif not store['initialized']:
        status, label, detail = (
            'missing', 'Not initialized',
            'The encrypted secret store has not been created yet.')
    else:
        count = len(store['secrets'])
        status, label, detail = (
            'ok', 'Active',
            'The encrypted store is initialized and holds {} credential{}.'
            .format(count, '' if count == 1 else 's'))
    return render(request, 'main/settings_secrets.html', {
        'initialized': store['initialized'],
        'secrets': store['secrets'],
        'store_error': store['error'],
        'page_key': 'secrets',
        'page_icon': 'bi-key',
        'page_title': 'Secrets',
        'page_explain': PAGE_EXPLAIN['secrets'],
        'page_status': status,
        'page_status_label': label,
        'page_status_text': detail,
    })


@login_required
def settings_secrets_reveal(request):
    """Return one value for an explicit, synchronous reveal.

    This deliberately avoids create_job(): job output is streamed and stored,
    while this response is the only place the value is exposed. The host audit
    records the requesting user and secret name, never the value.
    """
    if request.method != 'POST':
        return redirect('settings_secrets')
    name = _secret_name(request)
    if not name:
        return JsonResponse({'ok': False, 'error': 'Invalid secret name.'},
                            status=400)
    actor = getattr(request.user, 'username', '') or 'unknown'
    ok, stdout, stderr = run_command(
        'symbios-secret.sh show {} --actor {}'.format(
            shlex.quote(name), shlex.quote(actor)), timeout=30)
    if not ok:
        return JsonResponse(
            {'ok': False, 'error': stderr.strip() or 'Could not read secret.'},
            status=500)
    response = JsonResponse({'ok': True, 'value': stdout})
    response['Cache-Control'] = 'no-store'
    return response


@login_required
def settings_secrets_plan(request):
    if request.method != 'POST':
        return redirect('settings_secrets')
    name = _secret_name(request)
    if not name:
        return _error(request, 'Invalid secret name.')
    cmd = 'symbios-secret.sh rotate {} --plan'.format(shlex.quote(name))
    return _exec_ldap_command(request, cmd, 'Planning rotation of "{}"...'.format(name),
                              'Rotation plan for "{}" generated.'.format(name),
                              redirect_to='settings_secrets')


@login_required
def settings_secrets_rotate(request):
    if request.method != 'POST':
        return redirect('settings_secrets')
    name = _secret_name(request)
    if not name:
        return _error(request, 'Invalid secret name.')
    cmd = 'symbios-secret.sh rotate {} --apply'.format(shlex.quote(name))
    return _exec_ldap_command(request, cmd, 'Rotating "{}"...'.format(name),
                              'Secret "{}" rotated and propagated.'.format(name),
                              redirect_to='settings_secrets')


@login_required
def settings_secrets_rollback(request):
    if request.method != 'POST':
        return redirect('settings_secrets')
    name = _secret_name(request)
    if not name:
        return _error(request, 'Invalid secret name.')
    cmd = 'symbios-secret.sh rollback {}'.format(shlex.quote(name))
    return _exec_ldap_command(request, cmd, 'Rolling back "{}"...'.format(name),
                              'Secret "{}" rolled back. Reapply consumers.'.format(name),
                              redirect_to='settings_secrets')


@login_required
def settings_secrets_delete(request):
    if request.method != 'POST':
        return redirect('settings_secrets')
    name = _secret_name(request)
    if not name:
        return _error(request, 'Invalid secret name.')
    cmd = 'symbios-secret.sh delete {}'.format(shlex.quote(name))
    return _exec_ldap_command(request, cmd, 'Deleting "{}"...'.format(name),
                              'Secret "{}" deleted.'.format(name),
                              redirect_to='settings_secrets')
