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
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from .decorators import login_required
from django.contrib import messages
from .views import _get_ldap_users, _get_ldap_groups
from .utils.ssh_exec import run_command
from .utils.jobs import create_job


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


@csrf_exempt
@login_required
def user_create(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '').strip()
        email = request.POST.get('email', '').strip()
        password = request.POST.get('password', '')
        group = request.POST.get('group', 'users')

        if not uid or not password:
            msg = 'All fields are required.'
            if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('users')

        cmd = f'symbios-ldap-user.sh --create --uid {uid} --password {password}'
        if email:
            cmd += f' --email {email}'
        if group:
            cmd += f' --group {group}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Creating user "{uid}"...',
                                 'message': f'User "{uid}" created.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'User "{uid}" created.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@csrf_exempt
@login_required
def user_delete(request, uid):
    if request.method == 'POST':
        cmd = f'symbios-ldap-user.sh --delete --uid {uid}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Deleting user "{uid}"...',
                                 'message': f'User "{uid}" deleted.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'User "{uid}" deleted.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@csrf_exempt
@login_required
def user_set_password(request, uid):
    if request.method == 'POST':
        password = request.POST.get('password', '')
        if not password:
            msg = 'Password is required.'
            if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('users')

        cmd = f'symbios-ldap-user.sh --modify --uid {uid} --password {password}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Setting password for "{uid}"...',
                                 'message': f'Password for "{uid}" changed.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Password for "{uid}" changed.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@csrf_exempt
@login_required
def user_update_email(request, uid):
    if request.method == 'POST':
        email = request.POST.get('email', '').strip()
        cmd = f'symbios-ldap-user.sh --modify --uid {uid} --email {email}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Updating email for "{uid}"...',
                                 'message': f'Email for "{uid}" updated.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Email for "{uid}" updated.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('users')


@csrf_exempt
@login_required
def group_create(request):
    if request.method == 'POST':
        name = request.POST.get('name', '').strip()
        if not name:
            msg = 'Name is required.'
            if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('groups')

        cmd = f'symbios-ldap-groups.sh --create --name {name}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Creating group "{name}"...',
                                 'message': f'Group "{name}" created.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Group "{name}" created.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('groups')


@csrf_exempt
@login_required
def group_delete(request, name):
    if request.method == 'POST':
        cmd = f'symbios-ldap-groups.sh --delete --name {name}'

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            job_id = create_job(cmd, timeout=300)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': f'Deleting group "{name}"...',
                                 'message': f'Group "{name}" deleted.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=30)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            messages.success(request, f'Group "{name}" deleted.')
        else:
            messages.error(request, f'Error: {output}')
    return redirect('groups')


@csrf_exempt
@login_required
def group_add_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --add-user --name {group} --uid {uid}'

            if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
                job_id = create_job(cmd, timeout=300)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': f'Adding "{uid}" to "{group}"...',
                                     'message': f'"{uid}" added to "{group}".',
                                     'command': cmd})

            ok, stdout, stderr = run_command(cmd, timeout=30)
            output = (stdout + '\n' + stderr).strip()
            if ok:
                messages.success(request, f'"{uid}" added to "{group}".')
            else:
                messages.error(request, f'Error: {output}')
    return redirect('users')


@csrf_exempt
@login_required
def group_remove_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            cmd = f'symbios-ldap-groups.sh --remove-user --name {group} --uid {uid}'

            if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
                job_id = create_job(cmd, timeout=300)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': f'Removing "{uid}" from "{group}"...',
                                     'message': f'"{uid}" removed from "{group}".',
                                     'command': cmd})

            ok, stdout, stderr = run_command(cmd, timeout=30)
            output = (stdout + '\n' + stderr).strip()
            if ok:
                messages.success(request, f'"{uid}" removed from "{group}".')
            else:
                messages.error(request, f'Error: {output}')
    return redirect('users')
