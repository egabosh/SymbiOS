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

import subprocess
from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from .views import _get_ldap_vars, LDAP_URI


@login_required
def change_password(request):
    if request.method == "POST":
        new_password = request.POST.get("new_password", "")
        confirm_password = request.POST.get("confirm_password", "")

        if not new_password:
            messages.error(request, "Password is required.")
            return redirect("change_password")

        if new_password == "admin":
            messages.error(request, "Password cannot be 'admin'.")
            return redirect("change_password")

        if new_password != confirm_password:
            messages.error(request, "Passwords do not match.")
            return redirect("change_password")

        # Change password in LDAP
        ldap = _get_ldap_vars()
        user_dn = f"uid={request.user.username},ou=users,{ldap['base_dn']}"
        ldif = f"""dn: {user_dn}
changetype: modify
replace: userPassword
userPassword: {new_password}
"""
        cmd = ["ldapmodify", "-x", "-H", LDAP_URI, "-D", f"cn=head-of-ldap,{ldap['base_dn']}", "-w", ldap["admin_pw"]]
        try:
            proc = subprocess.run(cmd, input=ldif, capture_output=True, text=True, timeout=10)
            if proc.returncode == 0:
                request.session["force_password_change"] = False
                messages.success(request, "Password changed successfully.")
                return redirect("/")
            else:
                messages.error(request, f"Error: {proc.stderr}")
        except Exception as e:
            messages.error(request, f"Error: {e}")

    return render(request, "main/change_password.html")
