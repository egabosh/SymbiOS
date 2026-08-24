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

from django.shortcuts import render
from .decorators import login_required
from .utils.log_utils import ALLOWED_LOG_FILES


@login_required
def logs(request):
    # Optional ?log=<name> deep link (e.g. from the Updates page); only
    # names registered in ALLOWED_LOG_FILES are accepted.
    default_log_name = 'messages'
    requested = request.GET.get('log', '')
    if requested in ALLOWED_LOG_FILES:
        default_log_name = requested
    response = render(request, 'main/logs.html',
                      {'default_log_name': default_log_name})
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response
