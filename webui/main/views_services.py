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

from django.shortcuts import render, Http404
from django.http import JsonResponse
import threading
import uuid
import os
import re
import yaml
import shlex

from django.contrib import messages as flash_messages
from .decorators import login_required
from .playbook_catalog import get_catalog, get_playbook
from .utils.ssh_exec import (
    stream_log,
    stop_log,
    run_command,
    run_service_status,
    build_action_command,
    build_log_command,
)
from .utils.jobs import create_job, _JOBS, _JOBS_LOCK

def _get_base_domain():
    """Read base_domain from inventory.yml."""
    config_path = os.environ.get('CONFIG_PATH', '/config/inventory.yml')
    try:
        with open(config_path) as fh:
            cfg = yaml.safe_load(fh) or {}
        return cfg.get('all', {}).get('vars', {}).get('base_domain', '')
    except Exception:
        return ''


def _render_service_url(raw_url):
    """Resolve Jinja-like variables in a service URL (e.g. {{ base_domain }})."""
    if not raw_url:
        return ''
    base_domain = _get_base_domain()
    if base_domain:
        raw_url = raw_url.replace('{{ base_domain }}', base_domain)
    return raw_url


# Built-in base-services can be managed but never uninstalled from the WebUI.
PROTECTED_GROUPS = {'base-services'}

# Sidebar group display order: user-playbooks on top, then services, then
# base-services at the bottom.
_GROUP_ORDER = ('user-playbooks', 'services', 'base-services')


def _order_catalog(catalog):
    """Return catalog items sorted by _GROUP_ORDER for sidebar display."""
    order = {g: i for i, g in enumerate(_GROUP_ORDER)}
    return sorted(catalog, key=lambda x: order.get(x.get('group'), 99))


def _get_installed_playbooks():
    """Read the state file and return a set of installed playbook paths."""
    state_file = '/config/installed-playbooks.yml'
    installed = set()
    try:
        with open(state_file) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                path = line.split(':')[0].strip()
                if path:
                    installed.add(path)
    except (FileNotFoundError, PermissionError):
        pass
    return installed


def _get_healthcheck_status():
    """Read runchecks results JSON and return a dict of check_name -> status.

    Status values: 'ok', 'error', 'unknown' (if no data yet).
    """
    results_file = '/log/runchecks-results.json'
    status = {}
    try:
        import json
        with open(results_file) as fh:
            data = json.load(fh)
        for check in data.get('checks', []):
            status[check['name']] = check.get('status', 'unknown')
    except (FileNotFoundError, PermissionError, json.JSONDecodeError, KeyError):
        pass
    return status


def _get_running_containers():
    """Return a set of running Docker container names on the host."""
    from .utils.ssh_exec import run_command
    try:
        ok, stdout, _ = run_command('docker ps --format {{.Names}}', timeout=5)
        if ok and stdout:
            return set(stdout.strip().splitlines())
    except Exception:
        pass
    return set()


def _sidebar_context(catalog):
    """Build context data for the sidebar: installed set and healthcheck status."""
    installed = _get_installed_playbooks()
    running_names = _get_running_containers()
    for item in catalog:
        pb = item.get('playbook', '')
        if pb in installed:
            continue
        svc_names = set()
        for svc in (item.get('docs') or {}).get('service_control', {}).get('services', []):
            name = svc.get('name')
            if name:
                svc_names.add(name)
        if svc_names & running_names:
            installed.add(pb)
    return {
        'installed_playbooks': installed,
        'healthcheck_status': _get_healthcheck_status(),
    }

# Visual class per action name when rendered as a button. Arbitrary action
# names (e.g. "pommes") fall back to a neutral outline style.
_ACTION_CLS = {
    'install': 'btn-outline-success',
    'reinstall': 'btn-outline-success',
    'start': 'btn-outline-success',
    'stop': 'btn-outline-danger',
    'restart': 'btn-outline-info',
    'reload': 'btn-outline-info',
    'uninstall-full': 'btn-outline-danger',
    'uninstall-program': 'btn-outline-dark',
    'uninstall-reset': 'btn-outline-danger',
}

# The three uninstall action names - used for protection checks and state cleanup.
_UNINSTALL_ACTIONS = {'uninstall-full', 'uninstall-program', 'uninstall-reset'}


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
    'inactive': ('Inactive', 'bg-secondary'),
    'error': ('Error', 'bg-warning text-dark'),
}




def _state_badge(state):
    label, cls = STATE_META.get(state, STATE_META['stopped'])
    return {'state': state, 'label': label, 'cls': cls}


def _aggregate_state(states):
    """Overall playbook state from its per-service states."""
    if not states:
        return 'inactive'
    if all(s == 'not-installed' for s in states):
        return 'inactive'
    if any(s == 'running' for s in states):
        return 'running'
    return 'stopped'


def _build_access_context(item):
    """Build access group context from a playbook's docs.access config.

    Returns a dict with 'groups' (list of group dicts for the template) and
    'users' (all LDAP users for the add-user dropdown).  Each group dict has
    'name', 'role' ('admin' or 'user'), and 'members' (list of user dicts).
    """
    from .views import _get_ldap_users
    access = (item.get('docs') or {}).get('access') or {}
    if not access:
        return {'groups': [], 'users': []}
    all_users = _get_ldap_users()
    # Build a uid->user lookup for quick member resolution.
    user_by_uid = {u['uid']: u for u in all_users}
    groups = []
    for role, key in [('admin', 'admin_group'), ('user', 'user_group')]:
        group_name = access.get(key)
        if not group_name:
            continue
        members = [user_by_uid[uid] for uid in user_by_uid
                   if group_name in (user_by_uid[uid].get('groups') or [])]
        # Users not yet in this group (available for the add dropdown).
        available = [u for u in all_users if group_name not in (u.get('groups') or [])]
        groups.append({
            'name': group_name,
            'role': role,
            'role_label': 'Admin' if role == 'admin' else 'User',
            'members': sorted(members, key=lambda u: u['uid']),
            'available': sorted(available, key=lambda u: u['uid']),
        })
    return {'groups': groups, 'users': all_users}





@login_required
def services(request):
    catalog = get_catalog()
    # Load the services documentation markdown
    docs_md = ''
    docs_path = os.path.join(os.path.dirname(__file__), 'docs', 'services.md')
    try:
        with open(docs_path) as fh:
            docs_md = fh.read()
    except FileNotFoundError:
        pass
    ordered = _order_catalog(catalog)
    return render(request, 'main/services.html', {
        'catalog': ordered,
        'all_services': ordered,
        'docs_md': docs_md,
        **_sidebar_context(catalog),
    })


@login_required
def services_manage(request):
    # Reuse the unified catalog view; the manage page lists deployable
    # service playbooks (those under services/), each linking to its detail.
    catalog = [i for i in get_catalog() if i['group'] == 'services']
    all_catalog = get_catalog()
    response = render(request, 'main/services.html', {
        'catalog': catalog,
        'all_services': _order_catalog(all_catalog),
        **_sidebar_context(all_catalog),
    })
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response


@login_required
def services_detail(request, playbook):
    item = get_playbook(playbook)
    if item is None:
        raise Http404("Service not found")
    # Build the action buttons dynamically from the playbook's docs.actions.
    # Base-services are protected: uninstall actions are never exposed.
    # Old-style docs.actions.uninstall is ignored (replaced by docs.uninstall).
    actions = item['docs'].get('actions') or {}
    action_list = []
    for name in actions:
        action_list.append(_action_button(name))
    # Build the 3 uninstall buttons from docs.uninstall (if present and not protected).
    uninstall_buttons = []
    has_uninstall_meta = bool((item.get('docs') or {}).get('uninstall'))
    if has_uninstall_meta and item.get('group') not in PROTECTED_GROUPS:
        uninstall_buttons = [
            {'name': 'uninstall-full', 'label': 'Uninstall',
             'cls': _ACTION_CLS['uninstall-full'],
             'confirm': 'ACHTUNG: Das entire Service wird inklusive ALLER '
                        'Daten (Programm + Userdaten) endgueltig geloescht! '
                        'Sind Sie sich WIRKLICH sicher?'},
            {'name': 'uninstall-program', 'label': 'Uninstall (keep data)',
             'cls': _ACTION_CLS['uninstall-program'],
             'confirm': 'Das Service-Programm wird komplett entfernt. '
                        'Nur die Userdaten bleiben erhalten. '
                        'Fortfahren?'},
            {'name': 'uninstall-reset', 'label': 'Delete Userdata',
             'cls': _ACTION_CLS['uninstall-reset'],
             'confirm': 'ACHTUNG: ALLE Userdaten des Services werden '
                        'geloescht! Das Programm bleibt erhalten und wird '
                        'neu gestartet. Sind Sie sich WIRKLICH sicher?'},
        ]
    logs = (item.get('docs') or {}).get('service_control', {}).get('logs', []) or []
    log_units = [{'name': l.get('name'), 'type': l.get('type', 'log')} for l in logs]
    service_url = _render_service_url((item.get('docs') or {}).get('url'))
    all_catalog = get_catalog()
    # Build access groups context from the playbook's docs.access config.
    access_ctx = _build_access_context(item)
    # External systems: only show compatible systems for this playbook's target type.
    playbook_target = (item.get('docs') or {}).get('target') or {}
    playbook_target_type = playbook_target.get('type', '')
    from .views_external import _load_systems
    all_systems = _load_systems()
    compatible_systems = [s for s in all_systems if s.get('type') == playbook_target_type] if playbook_target_type else []
    response = render(request, 'main/services_detail.html', {
        'item': item,
        'action_list': action_list,
        'uninstall_buttons': uninstall_buttons,
        'log_units': log_units,
        'service_url': service_url,
        'access_groups': access_ctx['groups'],
        'all_ldap_users': access_ctx['users'],
        'all_services': _order_catalog(all_catalog),
        'compatible_systems': compatible_systems,
        'playbook_target_type': playbook_target_type,
        **_sidebar_context(all_catalog),
    })
    # Never cache: the inline JS/logic changes frequently during development
    # and a stale cached copy would hide UI fixes.
    response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    return response


@login_required
def services_action(request, playbook):
    """Start an action as a background job and return a job id.

    The special action ``__playbook__`` runs the service's Ansible playbook
    (idempotent install/reinstall). The three ``uninstall-*`` actions run
    ``symbios-uninstall.sh`` which reads the ``# docs:`` metadata via yq.
    Any other action name is resolved locally from the playbook's docs.actions
    into the concrete host command, which is then executed via the SSH gateway.
    The browser polls /output/?job=<id> to display progress.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid action'}, status=400)
    action = request.POST.get('action')
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    # (Re)Install always runs the Ansible playbook; it is allowed for every
    # service.
    if action != '__playbook__':
        # The three uninstall modes are always allowed if docs.uninstall exists
        # (except for protected base-services, checked below).
        if action not in _UNINSTALL_ACTIONS:
            actions = item['docs'].get('actions') or {}
            if action not in actions:
                return JsonResponse({'error': 'Unknown action: ' + str(action)}, status=400)
        # Built-in base-services are protected: uninstall is never allowed.
        if action in _UNINSTALL_ACTIONS and item.get('group') in PROTECTED_GROUPS:
            return JsonResponse(
                {'error': 'Uninstall is not allowed for built-in base-services.'},
                status=403,
            )
        # Ensure the playbook has docs.uninstall metadata for uninstall actions.
        if action in _UNINSTALL_ACTIONS and not (item.get('docs') or {}).get('uninstall'):
            return JsonResponse(
                {'error': 'No uninstall metadata defined for this service.'},
                status=400,
            )
    cmd = build_action_command(playbook, action)
    display_cmd = cmd
    # Jobs run detached on the host (symbios-run-detached.sh): a WebUI restart
    # or SSH drop cannot abort a running playbook/action. The playbook run is
    # long-running, so the browser polls the job log via /output/?job=<id>.
    job_id = create_job(cmd, timeout=1800)
    threading.Thread(
        target=_run_service_job, args=(job_id, playbook, action), daemon=True
    ).start()
    return JsonResponse({'job': job_id, 'action': action, 'command': display_cmd})


def _run_service_job(job_id, playbook=None, action=None):
    """Wait for a detached service job and update state when it finished."""
    from .utils.jobs import get_job_output
    while True:
        result = get_job_output(job_id)
        if result is None:
            return
        _output, done, _ok, _cmd = result
        if done:
            break
        threading.Event().wait(2)
    # Update the installed-playbooks state file after a successful (Re)Install
    # or Uninstall so symbios-reapply.sh knows which playbooks to re-run.
    # The symbios-uninstall.sh script already handles state cleanup, but we
    # keep this as a safety net in case the script fails mid-way.
    result = get_job_output(job_id)
    overall_ok = bool(result and result[2])
    if playbook and action in ('__playbook__',) and overall_ok:
        state_cmd = 'symbios-state.sh set {}'.format(playbook)
        try:
            from .utils.ssh_exec import run_command as _run_command
            _run_command(state_cmd, timeout=10)
        except Exception:
            pass  # non-critical; log failure silently


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

    # A service is "installed" if the state file tracks it, OR if any
    # unit is running/stopped (installed outside SymbiOS).
    installed = False
    try:
        from .utils.ssh_exec import run_command as _run_command
        ok, _, _ = _run_command(f'symbios-state.sh is-installed {playbook}', timeout=5)
        installed = ok
    except Exception:
        pass
    if not installed:
        installed = overall in ('running', 'stopped')

    return JsonResponse({
        'services': out,
        'overall': overall,
        'overall_badge': _state_badge(overall),
        'installed': installed,
    })


@login_required
def services_access(request, playbook):
    """Add or remove a user from a service's LDAP access group.

    POST parameters: action (add|remove), uid, group.
    Validates that the group is defined in the playbook's docs.access config
    before executing the LDAP change.  Supports both AJAX (exec modal) and
    regular POST (flash + redirect) fallback.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid request'}, status=400)
    action = request.POST.get('action', '').strip()
    uid = request.POST.get('uid', '').strip()
    group = request.POST.get('group', '').strip()
    if action not in ('add', 'remove') or not uid or not group:
        return JsonResponse({'error': 'Missing parameters'}, status=400)
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    # Validate that the group is in the playbook's access config.
    access = (item.get('docs') or {}).get('access') or {}
    allowed_groups = set()
    for key in ('admin_group', 'user_group'):
        g = access.get(key)
        if g:
            allowed_groups.add(g)
    if group not in allowed_groups:
        return JsonResponse({'error': 'Group not in service access config'}, status=403)
    # Build the LDAP command.
    sub = '--add-user' if action == 'add' else '--remove-user'
    cmd = f'symbios-ldap-groups.sh {sub} --name {shlex.quote(group)} --uid {shlex.quote(uid)}'
    # Dual-mode: AJAX -> exec modal job; regular POST -> sync + redirect.
    from .utils.http import is_ajax_request
    if is_ajax_request(request):
        job_id = create_job(cmd, timeout=300)
        title = f'{"Adding" if action == "add" else "Removing"} "{uid}" {"to" if action == "add" else "from"} "{group}"...'
        return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                             'command': cmd})
    ok, stdout, stderr = run_command(cmd, timeout=30)
    output = (stdout + '\n' + stderr).strip()
    if ok:
        flash_messages.success(request, f'"{uid}" {"added to" if action == "add" else "removed from"} "{group}".')
    else:
        flash_messages.error(request, f'Error: {output}')
    return redirect(f'/services/{playbook}/')
