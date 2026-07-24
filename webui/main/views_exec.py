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

"""Generic command execution endpoints.

Provides /exec/start/ and /exec/output/ for running arbitrary host commands
with live output streamed to a modal overlay in the browser.
"""

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from .decorators import login_required
from .utils.jobs import create_job, get_job_output


@csrf_exempt
@login_required
def exec_start(request):
    """Start a command as a background job and return its id.

    POST with ``command`` parameter. The command is executed on the host via
    the SSH exec gateway. The browser polls /exec/output/?job=<id> to display
    live output in a modal overlay.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=400)
    command = request.POST.get('command', '').strip()
    if not command:
        return JsonResponse({'error': 'No command provided'}, status=400)
    title = request.POST.get('title', '').strip() or 'Running command...'
    job_id = create_job(command, timeout=900)
    return JsonResponse({'job': job_id, 'title': title, 'command': command})


@login_required
def exec_output(request):
    """Return the accumulated output of a running/finished exec job."""
    job_id = request.GET.get('job')
    if not job_id:
        return JsonResponse({'error': 'No job id'}, status=400)
    result = get_job_output(job_id)
    if result is None:
        return JsonResponse({'error': 'Unknown job'}, status=404)
    output, done, success = result
    return JsonResponse({'output': output, 'done': done, 'success': success})
