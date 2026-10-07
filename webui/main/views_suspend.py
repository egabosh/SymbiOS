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

"""Suspend page: configure which hosts are suspended when idle."""

import json
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .power_targets import (
    entry_from_post,
    load_targets,
    save_targets,
    validate_target,
)
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .views_users import _exec_ldap_command

APPLY_CMD = 'symbios-wol-suspend-apply.sh'


def _error(request, msg):
    """Return an AJAX error or a message + redirect for sync posts."""
    if is_ajax_request(request):
        return JsonResponse({'ok': False, 'error': msg}, status=400)
    messages.error(request, msg)
    return redirect('settings_suspend')


@login_required
def settings_suspend(request):
    targets = [t for t in load_targets() if (t.get('suspend') or {}).get('enabled') or 'suspend' in t]
    ok, stdout, _ = run_command(f'{APPLY_CMD} --status', timeout=30)
    status = {}
    if ok and stdout.strip():
        try:
            for row in json.loads(stdout.strip()):
                status[row.get('name')] = row
        except (ValueError, AttributeError):
            pass
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
    targets = load_targets()
    original = request.POST.get('original_name', '').strip() or None
    entry = entry_from_post(request, original)
    if 'suspend' not in entry:
        return _error(request, 'The suspend block must not be empty.')
    entry['suspend']['enabled'] = 'suspend_enabled' in request.POST
    err = validate_target(entry, targets, original_name=original)
    if err:
        return _error(request, err)
    if original:
        targets = [e for e in targets if e.get('name') != original]
    targets.append(entry)
    targets.sort(key=lambda e: e.get('name', ''))
    save_targets(targets)
    msg = f'Suspend target "{entry["name"]}" saved (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_suspend')


@login_required
def settings_suspend_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    targets = load_targets()
    remaining = [e for e in targets if e.get('name') != name]
    if len(remaining) == len(targets):
        return _error(request, f'No target named "{name}".')
    save_targets(remaining)
    msg = f'Target "{name}" deleted (apply to remove the watchers).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_suspend')


@login_required
def settings_suspend_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    targets = load_targets()
    found = False
    for entry in targets:
        if entry.get('name') == name and isinstance(entry.get('suspend'), dict):
            entry['suspend']['enabled'] = not entry['suspend'].get('enabled', True)
            found = True
    if not found:
        return _error(request, f'No suspend target named "{name}".')
    save_targets(targets)
    msg = f'Suspend target "{name}" toggled (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_suspend')


@login_required
def settings_suspend_apply(request):
    if request.method != 'POST':
        return redirect('settings_suspend')
    return _exec_ldap_command(request, APPLY_CMD,
                              'Applying power targets...',
                              'Power targets applied.',
                              redirect_to='settings_suspend')


@login_required
def settings_suspend_entry(request, name):
    entry = next((e for e in load_targets() if e.get('name') == name), None)
    if entry is None:
        return JsonResponse({'ok': False, 'error': f'No target named "{name}".'}, status=404)
    return JsonResponse({'ok': True, 'entry': entry})


@login_required
def settings_suspend_check(request, name):
    if request.method != 'POST':
        return redirect('settings_suspend')
    cmd = f'{APPLY_CMD} --check {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd,
                              f'Dry-run idle evaluation for "{name}"...',
                              f'Dry-run for "{name}" finished (no suspend).',
                              redirect_to='settings_suspend')
