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

import shlex
from django.shortcuts import render, redirect
from django.http import JsonResponse
from .decorators import login_required
from django.contrib import messages
from .views import _get_ldap_users, _get_ldap_groups
from .utils.ssh_exec import run_command
from .utils.jobs import create_job
from .utils.secret_file import f_write_secret


def _exec_ldap_command(request, cmd, title, success_msg, redirect_to='users'):
    """Handle AJAX/sync dual-mode for LDAP commands via exec modal."""
    from .utils.http import is_ajax_request
    if is_ajax_request(request):
        job_id = create_job(cmd, timeout=300)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': title, 'message': success_msg,
                             'command': cmd})
    ok, stdout, stderr = run_command(cmd, timeout=30)
    output = (stdout + '\n' + stderr).strip()
    if ok:
        messages.success(request, success_msg)
    else:
        messages.error(request, f'Error: {output}')
    return redirect(redirect_to)


@login_required
def users(request):
    users = _get_ldap_users()
    groups = _get_ldap_groups()
    return render(request, 'main/users_groups.html', {'users': users, 'groups': groups})


@login_required
def groups(request):
    groups = _get_ldap_groups()
    users = _get_ldap_users()
    return render(request, 'main/groups.html', {'groups': groups, 'group_members': users})


@login_required
def user_create(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '').strip()
        email = request.POST.get('email', '').strip()
        password = request.POST.get('password', '')
        group = request.POST.get('group', 'users')

        if not uid or not password:
            msg = 'All fields are required.'
            from .utils.http import is_ajax_request
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('users')

        f_pw_file = f_write_secret('ldap-password', password)
        cmd = f'symbios-ldap-user.sh --create --uid {shlex.quote(uid)} --password-file {shlex.quote(f_pw_file)}'
        if email:
            cmd += f' --email {shlex.quote(email)}'
        if group:
            cmd += f' --group {shlex.quote(group)}'

        return _exec_ldap_command(request, cmd, f'Creating user "{uid}"...', f'User "{uid}" created.')
    return redirect('users')


@login_required
def user_delete(request, uid):
    if request.method == 'POST':
        cmd = f'symbios-ldap-user.sh --delete --uid {shlex.quote(uid)}'
        return _exec_ldap_command(request, cmd, f'Deleting user "{uid}"...', f'User "{uid}" deleted.')
    return redirect('users')


@login_required
def user_set_password(request, uid):
    if request.method == 'POST':
        password = request.POST.get('password', '')
        if not password:
            msg = 'Password is required.'
            from .utils.http import is_ajax_request
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('users')

        f_pw_file = f_write_secret('ldap-password', password)
        cmd = f'symbios-ldap-user.sh --modify --uid {shlex.quote(uid)} --password-file {shlex.quote(f_pw_file)}'
        return _exec_ldap_command(request, cmd, f'Setting password for "{uid}"...', f'Password for "{uid}" changed.')
    return redirect('users')


@login_required
def user_update_email(request, uid):
    if request.method == 'POST':
        email = request.POST.get('email', '').strip()
        cmd = f'symbios-ldap-user.sh --modify --uid {shlex.quote(uid)} --email {shlex.quote(email)}'
        return _exec_ldap_command(request, cmd, f'Updating email for "{uid}"...', f'Email for "{uid}" updated.')
    return redirect('users')


@login_required
def group_create(request):
    if request.method == 'POST':
        name = request.POST.get('name', '').strip()
        if not name:
            msg = 'Name is required.'
            from .utils.http import is_ajax_request
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('groups')

        cmd = f'symbios-ldap-groups.sh --create --name {shlex.quote(name)}'
        return _exec_ldap_command(request, cmd, f'Creating group "{name}"...', f'Group "{name}" created.', redirect_to='groups')
    return redirect('groups')


@login_required
def group_delete(request, name):
    if request.method == 'POST':
        cmd = f'symbios-ldap-groups.sh --delete --name {shlex.quote(name)}'
        return _exec_ldap_command(request, cmd, f'Deleting group "{name}"...', f'Group "{name}" deleted.', redirect_to='groups')
    return redirect('groups')


@login_required
def group_add_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --add-user --name {shlex.quote(group)} --uid {shlex.quote(uid)}'
            return _exec_ldap_command(request, cmd, f'Adding "{uid}" to "{group}"...', f'"{uid}" added to "{group}".')
    return redirect('users')


@login_required
def group_remove_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --remove-user --name {shlex.quote(group)} --uid {shlex.quote(uid)}'
            return _exec_ldap_command(request, cmd, f'Removing "{uid}" from "{group}"...', f'"{uid}" removed from "{group}".')
    return redirect('users')
