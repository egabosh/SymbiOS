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

"""Minimal login_required replacement (no django.contrib.auth needed).

Only staff users (ldap-admins group, admin/root accounts) may access
management views. Regular ldap-users are rejected - they should use
service-level access (Nextcloud, Matrix, etc.) instead.
"""
from django.conf import settings
from django.shortcuts import redirect, render


def access_denied(request):
    # Authenticated via Authelia, but not authorized for the WebUI (admin
    # only). Render a plain 403 page instead of redirecting to the login
    # page: the login view sends authenticated users back to '/', which
    # caused an infinite redirect loop (ERR_TOO_MANY_REDIRECTS).
    username = getattr(getattr(request, 'user', None), 'username', '') or ''
    return render(request, 'main/access_denied.html', {'username': username},
                  status=403)


def login_required(view_func):
    def wrapper(request, *args, **kwargs):
        if not getattr(request.user, 'is_authenticated', False):
            return redirect(settings.LOGIN_URL)
        if not getattr(request.user, 'is_staff', False):
            return access_denied(request)
        return view_func(request, *args, **kwargs)
    wrapper.__name__ = getattr(view_func, '__name__', 'wrapper')
    return wrapper
