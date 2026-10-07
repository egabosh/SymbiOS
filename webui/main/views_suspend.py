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

"""Suspend page: configure which hosts are suspended when idle.

All list and mutation logic lives in symbios-wol-suspend-apply.sh (single
source of truth, shared with shell users); this view only forwards form
data to it and renders the result.
"""

import json
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .views_users import _exec_ldap_command

APPLY_CMD = 'symbios-wol-suspend-apply.sh'


def _load_status():
    """Load the live target status via the CLI script (empty on any error)."""
    ok, stdout, _ = run_command(f'{APPLY_CMD} --status', timeout=30)
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
    return redirect('settings_suspend')


def _save_command(request, original):
    """Build the CLI add/set-suspend command from POST fields."""
    name = request.POST.get('name', '').strip().lower()
    if not name:
        return None
    action = '--set-suspend' if original else '--add-suspend'
    parts = [APPLY_CMD, action, '--name', shlex.quote(name)]
    mapping = (
        ('suspend_host', 'host'), ('iface', 'iface'),
        ('idle_timeout_min', 'timeout'), ('grace_after_wol_sec', 'grace'),
        ('tcp_ports', 'tcp-ports'), ('lan_subnet', 'lan-subnet'),
        ('extra_local_cmd', 'extra-local'), ('extra_remote_cmd', 'extra-remote'),
    )
    for form_field, cli_flag in mapping:
        value = request.POST.get(form_field, '').strip()
        if value:
            parts += ['--' + cli_flag, shlex.quote(value)]
    parts += ['--enabled' if 'suspend_enabled' in request.POST else '--disabled']
    return ' '.join(parts)


@login_required
def settings_suspend(request):
    ok, stdout, _ = run_command(f'{APPLY_CMD} --dump', timeout=30)
    targets = []
    if ok and stdout.strip():
        try:
            data = json.loads(stdout.strip())
            targets = [t for t in data if isinstance(t, dict) and 'suspend' in t]
        except ValueError:
            pass
    status = {row.get('name'): row for row in _load_status()}
    for target in targets:
        live = status.get(target.get('name'), {})
        target['live_idle'] = (live.get('units') or {}).get('wol-idle', '?')
        target['live_awake'] = live.get('awake', False)
    return render(request, 'main/settings_suspend.html', {
        'targets': targets,
    })


@login_required
def settings_suspend_save(request):
    if request.method != 'POST':
        return redirect('settings_suspend')
    original = request.POST.get('original_name', '').strip() or None
    cmd = _save_command(request, original)
    if cmd is None:
        return _error(request, 'Name must not be empty.')
    name = request.POST.get('name', '').strip().lower()
    return _exec_ldap_command(request, cmd, f'Saving suspend target "{name}"...',
                              f'Suspend target "{name}" saved and applied.',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    cmd = f'{APPLY_CMD} --delete --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Deleting target "{name}"...',
                              f'Target "{name}" deleted and applied.',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    cmd = f'{APPLY_CMD} --toggle-suspend --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Toggling suspend target "{name}"...',
                              f'Suspend target "{name}" toggled and applied.',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_apply(request):
    if request.method != 'POST':
        return redirect('settings_suspend')
    return _exec_ldap_command(request, APPLY_CMD,
                              'Applying power targets...',
                              'Power targets applied.',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_check(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    cmd = f'{APPLY_CMD} --check {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd,
                              f'Dry-run idle evaluation for "{name}"...',
                              f'Dry-run for "{name}" finished (no suspend).',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_entry(request, name):
    ok, stdout, _ = run_command(f'{APPLY_CMD} --dump', timeout=30)
    if ok and stdout.strip():
        try:
            data = json.loads(stdout.strip())
            entry = next((e for e in data if isinstance(e, dict) and e.get('name') == name), None)
            if entry is not None:
                return JsonResponse({'ok': True, 'entry': entry})
        except ValueError:
            pass
    return JsonResponse({'ok': False, 'error': f'No target named "{name}".'}, status=404)
