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

"""Reverse-proxy forwards: one public hostname -> one backend target.

All list and mutation logic lives in symbios-traefik-proxy-apply.sh (single
source of truth, shared with shell users); this view only forwards form
data to it and renders the result.
"""

import json
import re
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .views_services import _get_base_domain
from .views_users import _exec_ldap_command

APPLY_CMD = 'symbios-traefik-proxy-apply.sh'


def _load_forwards():
    """Load the forward list via the CLI script (empty list on any error)."""
    ok, stdout, _ = run_command(f'{APPLY_CMD} --dump', timeout=30)
    if ok and stdout.strip():
        try:
            data = json.loads(stdout.strip())
            if isinstance(data, list):
                return [e for e in data if isinstance(e, dict)]
        except ValueError:
            pass
    return []


def _error(request, msg):
    """Return an AJAX error or a message + redirect for sync posts."""
    if is_ajax_request(request):
        return JsonResponse({'ok': False, 'error': msg}, status=400)
    messages.error(request, msg)
    return redirect('settings_reverse_proxy')


def _save_command(request, original):
    """Build the CLI add/set command from POST fields (all values quoted)."""
    name = request.POST.get('name', '').strip().lower()
    if not name:
        return None
    action = '--set' if original else '--add'
    parts = [APPLY_CMD, action, '--name', shlex.quote(name)]
    for field in ('host', 'scheme', 'target', 'port', 'access'):
        value = request.POST.get(field, '').strip()
        if value:
            parts += ['--' + field, shlex.quote(value)]
    if 'insecure_skip_verify' in request.POST:
        parts += ['--insecure', 'true']
    else:
        parts += ['--insecure', 'false']
    if 'api' in request.POST:
        parts += ['--api']
    else:
        parts += ['--no-api']
    if 'enabled' in request.POST:
        parts += ['--enabled']
    else:
        parts += ['--disabled']
    return ' '.join(parts)


@login_required
def settings_reverse_proxy(request):
    forwards = _load_forwards()
    return render(request, 'main/settings_reverse_proxy.html', {
        'forwards': forwards,
        'base_domain': _get_base_domain(),
    })


@login_required
def settings_reverse_proxy_save(request):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    original = request.POST.get('original_name', '').strip() or None
    cmd = _save_command(request, original)
    if cmd is None:
        return _error(request, 'Name must not be empty.')
    name = request.POST.get('name', '').strip().lower()
    return _exec_ldap_command(request, cmd, f'Saving forward "{name}"...',
                              f'Forward "{name}" saved and applied.',
                              redirect_to='settings_reverse_proxy')


@login_required
def settings_reverse_proxy_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    cmd = f'{APPLY_CMD} --delete --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Deleting forward "{name}"...',
                              f'Forward "{name}" deleted and applied.',
                              redirect_to='settings_reverse_proxy')


@login_required
def settings_reverse_proxy_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    cmd = f'{APPLY_CMD} --toggle --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Toggling forward "{name}"...',
                              f'Forward "{name}" toggled and applied.',
                              redirect_to='settings_reverse_proxy')


@login_required
def settings_reverse_proxy_apply(request):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    return _exec_ldap_command(request, APPLY_CMD,
                              'Applying reverse-proxy forwards...',
                              'Reverse-proxy forwards applied.',
                              redirect_to='settings_reverse_proxy')


@login_required
def settings_reverse_proxy_import(request):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    import_dir = request.POST.get('import_dir', '').strip() or '/root/traefik-import'
    if not re.match(r'^/[A-Za-z0-9._/-]+$', import_dir):
        return _error(request, 'Invalid import directory.')
    cmd = f'{APPLY_CMD} --import {shlex.quote(import_dir)}'
    return _exec_ldap_command(request, cmd,
                              'Importing provider snippets...',
                              'Provider snippets imported (apply to activate).',
                              redirect_to='settings_reverse_proxy')


@login_required
def settings_reverse_proxy_test(request, name):
    entry = next((e for e in _load_forwards() if e.get('name') == name), None)
    if entry is None:
        return JsonResponse({'ok': False, 'error': f'No forward named "{name}".'}, status=404)
    host = entry.get('host', '')
    if not re.match(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$', host or ''):
        return JsonResponse({'ok': False, 'error': f'Stored host "{host}" is invalid.'}, status=400)
    cmd = f"curl -sk -o /dev/null -w '%{{http_code}}' --max-time 10 --resolve {shlex.quote(host)}:443:127.0.0.1 https://{shlex.quote(host)}/"
    ok, stdout, stderr = run_command(cmd, timeout=30)
    code = (stdout or '').strip()[-3:]
    if ok and code.isdigit():
        return JsonResponse({'ok': True, 'code': code})
    return JsonResponse({'ok': False, 'error': (stderr or stdout or 'request failed')[-200:]})
