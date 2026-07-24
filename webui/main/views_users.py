# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from .views import _get_ldap_users, _get_ldap_groups
from .utils.ssh_exec import run_command


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
            messages.error(request, 'All fields are required.')
            return redirect('users')

        cmd = f'symbios-ldap-user.sh --create --uid {uid} --password {password}'
        if email:
            cmd += f' --email {email}'
        if group:
            cmd += f' --group {group}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'User "{uid}" created.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@login_required
def user_delete(request, uid):
    if request.method == 'POST':
        cmd = f'symbios-ldap-user.sh --delete --uid {uid}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'User "{uid}" deleted.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@login_required
def user_set_password(request, uid):
    if request.method == 'POST':
        password = request.POST.get('password', '')
        if not password:
            messages.error(request, 'Password is required.')
            return redirect('users')

        cmd = f'symbios-ldap-user.sh --modify --uid {uid} --password {password}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Password for "{uid}" changed.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@login_required
def user_update_email(request, uid):
    if request.method == 'POST':
        email = request.POST.get('email', '').strip()
        cmd = f'symbios-ldap-user.sh --modify --uid {uid} --email {email}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Email for "{uid}" updated.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@login_required
def group_create(request):
    if request.method == 'POST':
        name = request.POST.get('name', '').strip()
        if not name:
            messages.error(request, 'Name is required.')
            return redirect('groups')

        cmd = f'symbios-ldap-groups.sh --create --name {name}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Group "{name}" created.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('groups')


@login_required
def group_delete(request, name):
    if request.method == 'POST':
        cmd = f'symbios-ldap-groups.sh --delete --name {name}'
        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Group "{name}" deleted.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('groups')


@login_required
def group_add_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --add-user --name {group} --uid {uid}'
            ok, stdout, stderr = run_command(cmd, timeout=30)
            output = (stdout + '\n' + stderr).strip()
            if ok:
                messages.success(request, f'"{uid}" added to "{group}".')
            else:
                messages.error(request, f'Error: {output}')
    return redirect('users')


@login_required
def group_remove_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --remove-user --name {group} --uid {uid}'
            ok, stdout, stderr = run_command(cmd, timeout=30)
            output = (stdout + '\n' + stderr).strip()
            if ok:
                messages.success(request, f'"{uid}" removed from "{group}".')
            else:
                messages.error(request, f'Error: {output}')
    return redirect('users')
