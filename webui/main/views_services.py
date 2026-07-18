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

from django.shortcuts import render, Http404
from django.http import JsonResponse
import threading
import uuid

# In-memory registry of running action jobs. The WebUI runs a single gunicorn
# worker, so this is shared across requests. Jobs capture live command output
# for the browser to poll. (Not for multi-worker scaling.)
_JOBS = {}
_JOBS_LOCK = threading.Lock()
from django.views.decorators.csrf import csrf_exempt
from .decorators import login_required
from .playbook_catalog import get_catalog, get_playbook
from .utils.ssh_exec import (
    stream_command,
    stream_log,
    stop_log,
    run_service_status,
    build_action_command,
    build_log_command,
)

# Built-in base-services can be managed but never uninstalled from the WebUI.
PROTECTED_GROUPS = {'base-services'}

# Sidebar group display order: user-playbooks on top, then services, then
# base-services at the bottom.
_GROUP_ORDER = ('user-playbooks', 'services', 'base-services')


def _order_catalog(catalog):
    """Return catalog items sorted by _GROUP_ORDER for sidebar display."""
    order = {g: i for i, g in enumerate(_GROUP_ORDER)}
    return sorted(catalog, key=lambda x: order.get(x.get('group'), 99))

# Visual class per action name when rendered as a button. Arbitrary action
# names (e.g. "pommes") fall back to a neutral outline style.
_ACTION_CLS = {
    'install': 'btn-outline-success',
    'reinstall': 'btn-outline-success',
    'start': 'btn-outline-success',
    'stop': 'btn-outline-danger',
    'restart': 'btn-outline-info',
    'reload': 'btn-outline-info',
    'uninstall': 'btn-outline-warning',
}


def _action_button(name):
    return {
        'name': name,
        'label': name[0].upper() + name[1:] if name else name,
        'cls': _ACTION_CLS.get(name, 'btn-outline-secondary'),
    }

# Visual metadata per normalized state, used to render clear status badges.
STATE_META = {
    'running': ('Running', 'bg-success'),
    'stopped': ('Stopped', 'bg-danger'),
    'not-installed': ('Not installed', 'bg-secondary'),
    'error': ('Error', 'bg-warning text-dark'),
}




def _state_badge(state):
    label, cls = STATE_META.get(state, STATE_META['stopped'])
    return {'state': state, 'label': label, 'cls': cls}


def _aggregate_state(states):
    """Overall playbook state from its per-service states."""
    if not states:
        return 'not-installed'
    if all(s == 'not-installed' for s in states):
        return 'not-installed'
    if any(s == 'running' for s in states):
        return 'running'
    return 'stopped'





@login_required
def services(request):
    catalog = get_catalog()
    return render(request, 'main/services.html', {
        'catalog': _order_catalog(catalog),
        'all_services': _order_catalog(catalog),
    })


@login_required
def services_manage(request):
    # Reuse the unified catalog view; the manage page lists deployable
    # service playbooks (those under services/), each linking to its detail.
    catalog = [i for i in get_catalog() if i['group'] == 'services']
    response = render(request, 'main/services.html', {
        'catalog': catalog,
        'all_services': _order_catalog(get_catalog()),
    })
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response


@login_required
def services_detail(request, playbook):
    item = get_playbook(playbook)
    if item is None:
        raise Http404("Service not found")
    # Build the action buttons dynamically from the playbook's docs.actions.
    # Base-services are protected: the uninstall action is never exposed.
    actions = item['docs'].get('actions') or {}
    action_list = []
    for name in actions:
        if name == 'uninstall' and item.get('group') in PROTECTED_GROUPS:
            continue
        action_list.append(_action_button(name))
    logs = (item.get('docs') or {}).get('service_control', {}).get('logs', []) or []
    log_units = [{'name': l.get('name'), 'type': l.get('type', 'log')} for l in logs]
    response = render(request, 'main/services_detail.html', {
        'item': item,
        'action_list': action_list,
        'log_units': log_units,
        'all_services': get_catalog(),
    })
    # Never cache: the inline JS/logic changes frequently during development
    # and a stale cached copy would hide UI fixes.
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response


@csrf_exempt
@login_required
def services_action(request, playbook):
    """Start an action as a background job and return a job id.

    The special action ``__playbook__`` runs the service's Ansible playbook
    (idempotent install/reinstall). Any other action name is resolved locally
    from the playbook's docs.actions into the concrete host command, which is
    then executed via the SSH gateway. The browser polls /output/?job=<id> to
    display progress (no response streaming, which Traefik buffers).
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid action'}, status=400)
    action = request.POST.get('action')
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    # (Re)Install always runs the Ansible playbook; it is allowed for every
    # service. All other actions must be defined in the playbook's docs.actions.
    if action != '__playbook__':
        actions = item['docs'].get('actions') or {}
        if action not in actions:
            return JsonResponse({'error': 'Unknown action: ' + str(action)}, status=400)
        # Built-in base-services are protected: uninstall is never allowed.
        if action == 'uninstall' and item.get('group') in PROTECTED_GROUPS:
            return JsonResponse(
                {'error': 'Uninstall is not allowed for built-in base-services.'},
                status=403,
            )
    cmd = build_action_command(playbook, action)
    display_cmd = cmd
    job_id = uuid.uuid4().hex
    job = {'output': '', 'done': False, 'success': False, 'lock': threading.Lock()}
    with _JOBS_LOCK:
        # Keep the job table small: drop finished jobs before adding a new one.
        for old in [k for k, v in _JOBS.items() if v['done']]:
            _JOBS.pop(old, None)
        _JOBS[job_id] = job
    threading.Thread(target=_run_job, args=(job, cmd), daemon=True).start()
    return JsonResponse({'job': job_id, 'action': action, 'command': display_cmd})


def _run_job(job, cmd):
    """Run the resolved host command, appending output as it arrives."""
    overall_ok = True
    try:
        for kind, text in stream_command(cmd, timeout=900):
            if kind == 'rc':
                if text != 0:
                    overall_ok = False
                continue
            with job['lock']:
                job['output'] += text
    except Exception as e:  # pragma: no cover - defensive
        overall_ok = False
        with job['lock']:
            job['output'] += '\n[ERROR] ' + str(e) + '\n'
    with job['lock']:
        job['done'] = True
        job['success'] = overall_ok


@login_required
def services_output(request, playbook):
    """Return the accumulated output of a running/finished action job."""
    job_id = request.GET.get('job')
    if not job_id or job_id not in _JOBS:
        return JsonResponse({'error': 'Unknown job'}, status=404)
    job = _JOBS[job_id]
    with job['lock']:
        out = job['output']
        done = job['done']
        success = job['success']
    return JsonResponse({'output': out, 'done': done, 'success': success})


@login_required
def services_log_tail(request, playbook):
    """Return only the bytes appended to a live log job since ``offset``.

    Non-blocking: the client polls at a short fixed interval (see the frontend)
    and receives just the new tail, so this view returns immediately and never
    holds a worker. The follow command is wrapped with ``stdbuf`` so it flushes
    line-by-line and new entries appear within the poll interval. ``offset`` is
    an absolute character position into the stream; it is mapped into the
    rolling output window below (see stream_log).
    """
    job_id = request.GET.get('job')
    try:
        offset = int(request.GET.get('offset', '0'))
    except ValueError:
        offset = 0
    if not job_id or job_id not in _JOBS:
        return JsonResponse({'error': 'Unknown job'}, status=404)
    job = _JOBS[job_id]
    with job['lock']:
        out = job['output']
        total = job['total']
        done = job['done']
        success = job['success']
    # Map the browser's absolute offset into the rolling window. The window holds
    # absolute positions [total - len(out), total). If the browser fell behind
    # past the window (its offset was trimmed away), resync to the whole window
    # -- tail -f style, the browser simply jumps to the most recent lines.
    win_start = total - len(out)
    if offset <= win_start:
        delta = out
        new_offset = total
    else:
        delta = out[offset - win_start:]
        new_offset = total
    return JsonResponse({
        'delta': delta,
        'offset': new_offset,
        'done': done,
        'success': success,
    })


@csrf_exempt
@login_required
def services_log_start(request, playbook):
    """Start a live (follow) log stream for one unit and return its job id.

    The follow command runs ONCE on the host and streams into an in-memory job
    buffer; the browser polls that buffer (cheap) instead of re-executing the
    command every few seconds. Stop it with services_log_stop.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid request'}, status=400)
    unit = request.POST.get('unit')
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    logs = (item.get('docs') or {}).get('service_control', {}).get('logs', []) or []
    names = {l.get('name') for l in logs}
    if unit not in names:
        return JsonResponse({'error': 'Unknown log unit: ' + str(unit)}, status=400)
    cmd = build_log_command(playbook, unit)
    if not cmd:
        return JsonResponse({'error': 'No log command for unit: ' + str(unit)}, status=400)
    # Drop finished jobs so stopped follow streams don't pile up in memory.
    with _JOBS_LOCK:
        for old in [k for k, v in _JOBS.items() if v['done']]:
            _JOBS.pop(old, None)
        job_id = uuid.uuid4().hex
        job = {'output': '', 'done': False, 'success': True,
                'channel': None, 'lock': threading.Lock(),
                'total': 0, 'dropped': 0}
        _JOBS[job_id] = job
    threading.Thread(
        target=stream_log,
        args=(cmd, job),
        daemon=True,
    ).start()
    return JsonResponse({'job': job_id, 'unit': unit})


@csrf_exempt
@login_required
def services_log_stop(request, playbook):
    """Stop a live log stream started by services_log_start."""
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid request'}, status=400)
    job_id = request.POST.get('job')
    if not job_id or job_id not in _JOBS:
        return JsonResponse({'error': 'Unknown job'}, status=404)
    stop_log(_JOBS[job_id])
    return JsonResponse({'ok': True})


@login_required
def services_source(request, playbook):
    """Return the raw playbook source (read-only) for display in the WebUI.

    Built-in playbooks are under /repo; user-uploaded playbooks are under
    /config/user-playbooks/. The source is always read locally from disk.
    """
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    if item.get('group') == 'user-playbooks':
        path = '/config/user-playbooks/' + playbook.split('/', 1)[-1]
    else:
        path = '/repo/' + playbook
    try:
        with open(path) as fh:
            out = fh.read()
    except Exception as e:
        return JsonResponse({'error': 'source read failed: ' + str(e)}, status=502)
    return JsonResponse({'source': out})


def _state_from_rc(rc):
    """Map a status command's exit code to a normalized service state.

    Playbook-declared `status:` commands follow this convention:
      0   -> running
      2   -> not-installed (author signal, e.g. `test -d dir || exit 2`)
      4   -> not-installed (systemd `is-active` for a missing unit)
      else-> stopped
    """
    if rc == 0:
        return 'running'
    if rc in (2, 4):
        return 'not-installed'
    return 'stopped'


@login_required
def services_status(request, playbook):
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    services = item['docs'].get('service_control', {}).get('services', [])
    out = []
    for s in services:
        name = s.get('name')
        rc, stdout, stderr = run_service_status(playbook, name)
        state = _state_from_rc(rc)
        out.append({
            'name': name,
            'type': s.get('type'),
            'status': (stdout or stderr or '').strip(),
            'state': state,
            'badge': _state_badge(state),
        })
    states = [s['state'] for s in out]
    overall = _aggregate_state(states)
    return JsonResponse({
        'services': out,
        'overall': overall,
        'overall_badge': _state_badge(overall),
    })
