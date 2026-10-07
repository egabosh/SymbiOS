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

"""Wake-on-LAN page: configure wake targets and wake them on demand."""

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
    return redirect('settings_wol')


@login_required
def settings_wol(request):
    targets = [t for t in load_targets() if (t.get('wake') or {}).get('enabled') or 'wake' in t]
    ok, stdout, _ = run_command(f'{APPLY_CMD} --status', timeout=30)
    status = {}
    if ok and stdout.strip():
        try:
            for row in json.loads(stdout.strip()):
                status[row.get('name')] = row
        except (ValueError, AttributeError):
            pass
    for target in targets:
        target['live'] = status.get(target.get('name'), {})
    return render(request, 'main/settings_wol.html', {
        'targets': targets,
    })


@login_required
def settings_wol_save(request):
    if request.method != 'POST':
        return redirect('settings_wol')
    targets = load_targets()
    original = request.POST.get('original_name', '').strip() or None
    entry = entry_from_post(request, original)
    if 'wake' not in entry:
        return _error(request, 'The wake block must not be empty.')
    entry['wake']['enabled'] = 'wake_enabled' in request.POST
    err = validate_target(entry, targets, original_name=original)
    if err:
        return _error(request, err)
    if original:
        targets = [e for e in targets if e.get('name') != original]
    targets.append(entry)
    targets.sort(key=lambda e: e.get('name', ''))
    save_targets(targets)
    msg = f'Wake target "{entry["name"]}" saved (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_wol')


@login_required
def settings_wol_delete(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    targets = load_targets()
    remaining = [e for e in targets if e.get('name') != name]
    if len(remaining) == len(targets):
        return _error(request, f'No target named "{name}".')
    save_targets(remaining)
    msg = f'Target "{name}" deleted (apply to remove the watchers).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_wol')


@login_required
def settings_wol_toggle(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    targets = load_targets()
    found = False
    for entry in targets:
        if entry.get('name') == name and isinstance(entry.get('wake'), dict):
            entry['wake']['enabled'] = not entry['wake'].get('enabled', True)
            found = True
    if not found:
        return _error(request, f'No wake target named "{name}".')
    save_targets(targets)
    msg = f'Wake target "{name}" toggled (apply to activate).'
    if is_ajax_request(request):
        return JsonResponse({'ok': True, 'message': msg})
    messages.success(request, msg)
    return redirect('settings_wol')


@login_required
def settings_wol_apply(request):
    if request.method != 'POST':
        return redirect('settings_wol')
    return _exec_ldap_command(request, APPLY_CMD,
                              'Applying power targets...',
                              'Power targets applied.',
                              redirect_to='settings_wol')


@login_required
def settings_wol_entry(request, name):
    entry = next((e for e in load_targets() if e.get('name') == name), None)
    if entry is None:
        return JsonResponse({'ok': False, 'error': f'No target named "{name}".'}, status=404)
    return JsonResponse({'ok': True, 'entry': entry})


@login_required
def settings_wol_wake(request, name):
    if request.method != 'POST':
        return redirect('settings_wol')
    cmd = f'{APPLY_CMD} --wake {shlex.quote(name)}'
    return _exec_ldap_command(request, cmd,
                              f'Waking "{name}"...',
                              f'Wake packet sent to "{name}".',
                              redirect_to='settings_wol')
