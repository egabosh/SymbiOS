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

"""Wake-on-LAN page: configure wake targets and wake them on demand.

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


def _error(request, msg):
    """Return an AJAX error or a message + redirect for sync posts."""
    if is_ajax_request(request):
        return JsonResponse({'ok': False, 'error': msg}, status=400)
    messages.error(request, msg)
    return redirect('settings_wol')


def _save_command(request, original):
    """Build the CLI add/set-wake command from POST fields."""
    name = request.POST.get('name', '').strip().lower()
    if not name:
        return None
    action = '--set-wake' if original else '--add-wake'
    parts = [APPLY_CMD, action, '--name', shlex.quote(name)]
    for form_field in ('mac', 'wake_host'):
        cli_flag = 'host' if form_field == 'wake_host' else form_field
        value = request.POST.get(form_field, '').strip()
        if value:
            parts += ['--' + cli_flag, shlex.quote(value)]
    patterns = [p.strip() for p in request.POST.get('patterns', '').splitlines()]
    patterns = [p for p in patterns if p]
    if patterns:
        parts += ['--patterns', shlex.quote(','.join(patterns))]
    if request.POST.get('log_path', '').strip():
        parts += ['--log-path', shlex.quote(request.POST.get('log_path').strip())]
    parts += ['--enabled' if 'wake_enabled' in request.POST else '--disabled']
    return ' '.join(parts)


@login_required
def settings_wol(request):
    ok, stdout, _ = run_command(f'{APPLY_CMD} --dump', timeout=30)
    targets = []
    if ok and stdout.strip():
        try:
            data = json.loads(stdout.strip())
            targets = [t for t in data if isinstance(t, dict) and 'wake' in t]
        except ValueError:
            pass
    ok, stdout, _ = run_command(f'{APPLY_CMD} --status', timeout=30)
    status = {}
    if ok and stdout.strip():
        try:
            for row in json.loads(stdout.strip()):
                status[row.get('name')] = row
        except ValueError:
            pass
    for target in targets:
        live = status.get(target.get('name'), {})
        target['live_awake'] = live.get('awake', False)
    return render(request, 'main/settings_wol.html', {
        'targets': targets,
    })


@login_required
def settings_wol_save(request):
    if request.method != 'POST':
        return redirect('settings_wol')
    original = request.POST.get('original_name', '').strip() or None
    cmd = _save_command(request, original)
    if cmd is None:
        return _error(request, 'Name must not be empty.')
    name = request.POST.get('name', '').strip().lower()
    return _exec_ldap_command(request, cmd, f'Saving wake target "{name}"...',
                              f'Wake target "{name}" saved and applied.',
                              redirect_to='settings_wol')


@login_required
def settings_wol_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    cmd = f'{APPLY_CMD} --delete --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Deleting target "{name}"...',
                              f'Target "{name}" deleted and applied.',
                              redirect_to='settings_wol')


@login_required
def settings_wol_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    cmd = f'{APPLY_CMD} --toggle-wake --name {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd, f'Toggling wake target "{name}"...',
                              f'Wake target "{name}" toggled and applied.',
                              redirect_to='settings_wol')


@login_required
def settings_wol_apply(request):
    if request.method != 'POST':
        return redirect('settings_wol')
    return _exec_ldap_command(request, APPLY_CMD,
                              'Applying power targets...',
                              'Power targets applied.',
                              redirect_to='settings_wol')


@login_required
def settings_wol_wake(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    cmd = f'{APPLY_CMD} --wake {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd,
                              f'Waking "{name}"...',
                              f'Wake packet sent to "{name}".',
                              redirect_to='settings_wol')


@login_required
def settings_wol_entry(request, name):
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
