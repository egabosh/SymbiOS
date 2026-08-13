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
from .decorators import login_required
from django.contrib import messages
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .utils.secret_file import f_write_secret


@login_required
def change_password(request):
    if request.method == "POST":
        uid = request.user.username
        new_password = request.POST.get("new_password", "")
        confirm_password = request.POST.get("confirm_password", "")

        if not new_password:
            msg = "Password is required."
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect("change_password")

        if new_password == "admin":
            msg = "Password cannot be 'admin'."
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect("change_password")

        if new_password != confirm_password:
            msg = "Passwords do not match."
            if is_ajax_request(request):
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect("change_password")

        f_pw_file = f_write_secret('ldap-password', new_password)
        cmd = f'symbios-ldap-user.sh --modify --uid {uid} --password-file {f_pw_file}'

        if is_ajax_request(request):
            from .utils.jobs import create_job
            job_id = create_job(cmd, timeout=60)
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': 'Changing password...',
                                 'message': 'Password changed successfully.',
                                 'command': cmd})

        ok, stdout, stderr = run_command(cmd, timeout=15)
        output = (stdout + '\n' + stderr).strip()
        if ok:
            request.session["force_password_change"] = False
            messages.success(request, "Password changed successfully.")
            return redirect("/")
        else:
            messages.error(request, f"Error: {output}")

    return render(request, "main/change_password.html")
