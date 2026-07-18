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

"""Minimal login_required replacement (no django.contrib.auth needed)."""
from django.conf import settings
from django.shortcuts import redirect


def login_required(view_func):
    def wrapper(request, *args, **kwargs):
        if not getattr(request.user, 'is_authenticated', False):
            return redirect(settings.LOGIN_URL)
        return view_func(request, *args, **kwargs)
    wrapper.__name__ = getattr(view_func, '__name__', 'wrapper')
    return wrapper
