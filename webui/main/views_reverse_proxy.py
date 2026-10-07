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

The forward list is stored as YAML in the container's /config mount
(traefik/forwards.yml, same directory the host resolves as config dir)
and rendered into Traefik file-provider snippets by
base-services/traefik-proxy.yml (via symbios-traefik-proxy-apply.sh).
"""

import os
import re
import shlex

import yaml
from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .utils.http import is_ajax_request
from .utils.jobs import create_job
from .utils.ssh_exec import run_command
from .views_services import _get_base_domain
from .views_users import _exec_ldap_command

CONFIG_FILE = '/config/traefik/forwards.yml'
APPLY_CMD = 'symbios-traefik-proxy-apply.sh'

NAME_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')
HOST_RE = re.compile(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$')
TARGET_RE = re.compile(r'^[A-Za-z0-9.-]+$')
RESERVED_NAMES = {'default', 'symbios-services', 'traefik', 'authelia'}
ACCESS_MODES = ('open', 'local', 'authelia')


def _load_forwards():
    """Load the forward list (empty list when absent or invalid)."""
    try:
        with open(CONFIG_FILE, 'r') as handle:
            data = yaml.safe_load(handle) or []
            if isinstance(data, list):
                return [e for e in data if isinstance(e, dict)]
    except (OSError, yaml.YAMLError):
        pass
    return []


def _save_forwards(forwards):
    """Persist the forward list, creating the directory when needed."""
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, 'w') as handle:
        yaml.safe_dump(forwards, handle, default_flow_style=False, sort_keys=False)


def _validate(entry, forwards, original_name=None):
    """Validate one entry against the list. Returns an error string or None."""
    name = entry.get('name', '')
    if not NAME_RE.match(name):
        return 'Invalid name: must start with a letter or digit, then letters, digits or hyphens.'
    if name in RESERVED_NAMES:
        return f'Name "{name}" is reserved for SymbiOS internals.'
    if name != original_name and any(e.get('name') == name for e in forwards):
        return f'A forward named "{name}" already exists.'
    host = (entry.get('host') or '').lower()
    if not HOST_RE.match(host):
        return 'Invalid host: must be a lowercase FQDN (e.g. app.example.com).'
    if any(e.get('host', '').lower() == host and e.get('name') != original_name for e in forwards):
        return f'Host "{host}" is already forwarded.'
    if entry.get('scheme', 'http') not in ('http', 'https'):
        return 'Invalid scheme: must be http or https.'
    if not TARGET_RE.match(entry.get('target') or ''):
        return 'Invalid target: must be a hostname or IP address.'
    try:
        port = int(entry.get('port', 0))
    except (TypeError, ValueError):
        return 'Invalid port: must be a number.'
    if port < 1 or port > 65535:
        return 'Invalid port: must be between 1 and 65535.'
    if entry.get('access', 'open') not in ACCESS_MODES:
        return 'Invalid access mode.'
    return None


def _entry_from_post(request):
    """Build a forward entry from POST fields (checkbox aware)."""
    return {
        'name': request.POST.get('name', '').strip().lower(),
        'enabled': 'enabled' in request.POST,
        'host': request.POST.get('host', '').strip().lower(),
        'scheme': request.POST.get('scheme', 'http').strip(),
        'target': request.POST.get('target', '').strip(),
        'port': int(request.POST.get('port', '0') or 0),
        'insecure_skip_verify': 'insecure_skip_verify' in request.POST,
        'access': request.POST.get('access', 'open').strip(),
    }


def _error(request, msg):
    """Return an AJAX error or a message + redirect for sync posts."""
    if is_ajax_request(request):
        return JsonResponse({'ok': False, 'error': msg}, status=400)
    messages.error(request, msg)
    return redirect('settings_reverse_proxy')


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
    forwards = _load_forwards()
    original = request.POST.get('original_name', '').strip() or None
    entry = _entry_from_post(request)
    err = _validate(entry, forwards, original_name=original)
    if err:
        return _error(request, err)
    if original:
        forwards = [e for e in forwards if e.get('name') != original]
    forwards.append(entry)
    forwards.sort(key=lambda e: e.get('name', ''))
    _save_forwards(forwards)
    msg = f'Forward "{entry["name"]}" saved (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_reverse_proxy')


@login_required
def settings_reverse_proxy_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    forwards = _load_forwards()
    remaining = [e for e in forwards if e.get('name') != name]
    if len(remaining) == len(forwards):
        return _error(request, f'No forward named "{name}".')
    _save_forwards(remaining)
    msg = f'Forward "{name}" deleted (apply to remove the route).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_reverse_proxy')


@login_required
def settings_reverse_proxy_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_reverse_proxy')
    forwards = _load_forwards()
    found = False
    for entry in forwards:
        if entry.get('name') == name:
            entry['enabled'] = not entry.get('enabled', True)
            found = True
    if not found:
        return _error(request, f'No forward named "{name}".')
    _save_forwards(forwards)
    msg = f'Forward "{name}" toggled (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_reverse_proxy')


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
    forwards = _load_forwards()
    entry = next((e for e in forwards if e.get('name') == name), None)
    if entry is None:
        return JsonResponse({'ok': False, 'error': f'No forward named "{name}".'}, status=404)
    host = entry.get('host', '')
    if not HOST_RE.match(host):
        return JsonResponse({'ok': False, 'error': f'Stored host "{host}" is invalid.'}, status=400)
    cmd = f"curl -sk -o /dev/null -w '%{{http_code}}' --max-time 10 --resolve {shlex.quote(host)}:443:127.0.0.1 https://{shlex.quote(host)}/"
    ok, stdout, stderr = run_command(cmd, timeout=30)
    code = (stdout or '').strip()[-3:]
    if ok and code.isdigit():
        return JsonResponse({'ok': True, 'code': code})
    return JsonResponse({'ok': False, 'error': (stderr or stdout or 'request failed')[-200:]})
