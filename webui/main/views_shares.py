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
import re
import shlex
from django.shortcuts import render, redirect
from django.http import JsonResponse
from .decorators import login_required
from django.contrib import messages
from .views_users import _exec_ldap_command
from .utils.ssh_exec import run_command


def _get_shares():
    """List media shares via symbios-media-share.sh (JSON)."""
    ok, stdout, stderr = run_command('symbios-media-share.sh --list', timeout=60)
    if ok and stdout.strip():
        try:
            shares = json.loads(stdout.strip())
            if isinstance(shares, list):
                return shares
        except Exception:
            pass
    return []


@login_required
def shares(request):
    return render(request, 'main/shares.html', {
        'shares': _get_shares(),
    })


@login_required
def share_create(request):
    if request.method == 'POST':
        from .utils.http import is_ajax_request
        name = request.POST.get('name', '').strip().lower()
        group = request.POST.get('group', '').strip()
        if not re.match(r'^[a-z0-9][a-z0-9-]*$', name):
            msg = 'Invalid share name: must start with a letter or digit, then letters, digits, hyphens.'
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('shares')
        if group and not re.match(r'^[a-zA-Z0-9._-]+$', group):
            msg = 'Invalid group name.'
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('shares')
        cmd = f'symbios-media-share.sh --create --name {shlex.quote(name)}'
        if group:
            cmd += f' --group {shlex.quote(group)}'
        return _exec_ldap_command(request, cmd, f'Creating share "{name}"...',
                                  f'Share "{name}" created.', redirect_to='shares')
    return redirect('shares')


@login_required
def share_delete(request, name):
    if request.method == 'POST':
        cmd = f'symbios-media-share.sh --delete --name {shlex.quote(name)}'
        return _exec_ldap_command(request, cmd, f'Deleting share "{name}"...',
                                  f'Share "{name}" deleted.', redirect_to='shares')
    return redirect('shares')
