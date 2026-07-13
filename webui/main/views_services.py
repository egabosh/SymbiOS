from django.shortcuts import render, Http404
from django.http import JsonResponse
import threading
import uuid
import json

# In-memory registry of running action jobs. The WebUI runs a single gunicorn
# worker, so this is shared across requests. Jobs capture live command output
# for the browser to poll. (Not for multi-worker scaling.)
_JOBS = {}
_JOBS_LOCK = threading.Lock()
from django.views.decorators.csrf import csrf_exempt
from .decorators import login_required
from .playbook_catalog import get_catalog, get_playbook, compose_base
from .utils.ssh_exec import run_docker, run_systemctl, run_cron, run_ufw, stream_command

# Built-in base-services can be managed but never uninstalled from the WebUI.
PROTECTED_GROUPS = {'base-services'}

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

# Map (service type, UI action) -> gateway verb/subcommand for status display.
_STATUS_VERB = {
    'docker': 'ps',
    'systemd': 'is-active',
    'cron': 'status',
    'ufw': 'status',
}


def _normalize_state(type_, raw):
    """Turn a raw gateway status string into a clear, comparable state."""
    raw = (raw or '').strip()
    if type_ == 'docker':
        if 'Up ' in raw:
            return 'running'
        if any(k in raw for k in ('Exited', 'Created', 'Restarting', 'Paused')):
            return 'stopped'
        if not raw or 'no container' in raw.lower() or 'no resource' in raw.lower():
            return 'not-installed'
        return 'stopped'
    if type_ == 'systemd':
        if raw == 'active':
            return 'running'
        if raw == 'unknown':
            return 'not-installed'
        if raw == 'failed':
            return 'error'
        return 'stopped'
    if type_ == 'cron':
        if raw.startswith('installed'):
            return 'running'
        if raw == 'not installed':
            return 'not-installed'
        return 'stopped'
    if type_ == 'ufw':
        low = raw.lower()
        if 'active' in low and 'inactive' not in low:
            return 'running'
        if 'inactive' in low:
            return 'stopped'
        return 'stopped'
    return 'stopped'


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


def _dispatch(svc, action):
    """Resolve a (type, action) pair to an execution through the SSH gateway.

    Returns a result dict or None if the action is not applicable to this type.
    """
    t = svc.get('type')
    if t == 'docker':
        base = compose_base(svc.get('compose_file'))
        verb = {'start': 'up', 'stop': 'down', 'restart': 'restart',
                'reload': 'up', 'uninstall': 'remove', 'status': 'ps'}.get(action)
        if not verb or not base:
            return None
        ok, out = run_docker(base, verb, timeout=300)
        return {'target': svc.get('name'), 'type': t, 'ok': ok, 'output': out}
    if t == 'systemd':
        unit = svc.get('unit')
        sub = {'start': 'start', 'stop': 'stop', 'restart': 'restart',
               'reload': 'reload', 'uninstall': 'disable --now',
               'status': 'is-active'}.get(action)
        if not sub or not unit:
            return None
        ok, out = run_systemctl(sub, unit, timeout=120)
        return {'target': svc.get('name'), 'type': t, 'ok': ok, 'output': out}
    if t == 'cron':
        file = svc.get('file')
        sub = {'start': 'enable', 'stop': 'disable', 'restart': 'enable',
               'uninstall': 'remove', 'status': 'status'}.get(action)
        if not sub or not file:
            return None
        ok, out = run_cron(sub, file, timeout=120)
        return {'target': svc.get('name'), 'type': t, 'ok': ok, 'output': out}
    if t == 'ufw':
        sub = {'start': 'enable', 'stop': 'disable', 'restart': 'reload',
               'reload': 'reload', 'uninstall': 'disable', 'status': 'status'}.get(action)
        if not sub:
            return None
        ok, out = run_ufw(sub, timeout=120)
        return {'target': svc.get('name'), 'type': t, 'ok': ok, 'output': out}
    return None


@login_required
def services(request):
    catalog = get_catalog()
    return render(request, 'main/services.html', {
        'catalog': catalog,
        'all_services': catalog,
    })


@login_required
def services_manage(request):
    # Reuse the unified catalog view; the manage page lists deployable
    # service playbooks (those under services/), each linking to its detail.
    catalog = [i for i in get_catalog() if i['group'] == 'services']
    return render(request, 'main/services.html', {
        'catalog': catalog,
        'all_services': get_catalog(),
    })


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
    return render(request, 'main/services_detail.html', {
        'item': item,
        'action_list': action_list,
        'all_services': get_catalog(),
    })


@csrf_exempt
@login_required
def services_action(request, playbook):
    """Start an action as a background job and return a job id.

    The special action ``__playbook__`` runs the service's Ansible playbook
    (idempotent install/reinstall). Any other action name is resolved against
    the playbook's docs.actions dict on the host (via the `service run` gateway
    verb), which executes the associated command. The browser polls
    /output/?job=<id> to display progress (no response streaming, which Traefik
    buffers).
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid action'}, status=400)
    action = request.POST.get('action')
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    # (Re)Install always runs the Ansible playbook; it is allowed for every
    # service. All other actions must be defined in the playbook's docs.actions.
    if action == '__playbook__':
        display_cmd = 'ansible-playbook ' + playbook
    else:
        actions = item['docs'].get('actions') or {}
        if action not in actions:
            return JsonResponse({'error': 'Unknown action: ' + str(action)}, status=400)
        # Built-in base-services are protected: uninstall is never allowed.
        if action == 'uninstall' and item.get('group') in PROTECTED_GROUPS:
            return JsonResponse(
                {'error': 'Uninstall is not allowed for built-in base-services.'},
                status=403,
            )
        display_cmd = actions.get(action, 'service run ' + playbook + ' ' + action)
    job_id = uuid.uuid4().hex
    job = {'output': '', 'done': False, 'success': False, 'lock': threading.Lock()}
    with _JOBS_LOCK:
        # Keep the job table small: drop finished jobs before adding a new one.
        for old in [k for k, v in _JOBS.items() if v['done']]:
            _JOBS.pop(old, None)
        _JOBS[job_id] = job
    threading.Thread(target=_run_job, args=(job, playbook, action), daemon=True).start()
    return JsonResponse({'job': job_id, 'action': action, 'command': display_cmd})


def _run_job(job, playbook, action):
    """Run the action on the host, appending output as it arrives.

    ``__playbook__`` invokes the Ansible playbook directly; any other action is
    resolved by the gateway's `service run` verb from the playbook's
    docs.actions.
    """
    overall_ok = True
    if action == '__playbook__':
        cmd = 'playbook ' + playbook
    else:
        cmd = 'service run ' + playbook + ' ' + action
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
def services_logs(request, playbook):
    """Return the recent logs of every unit managed by the playbook.

    Mirrors the top-level Logs page: a normal JSON GET that the browser polls
    to show live service logs (no response streaming, Traefik-safe).
    """
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    try:
        lines = int(request.GET.get('lines', '200'))
    except ValueError:
        lines = 200
    lines = max(1, min(lines, 500))
    from .utils.ssh_exec import run_service_logs
    ok, out = run_service_logs(playbook, lines)
    if not ok and not out.strip():
        return JsonResponse({'error': out or 'log fetch failed'}, status=502)
    try:
        data = json.loads(out)
    except Exception:
        return JsonResponse({'error': 'bad log output', 'raw': out[:500]}, status=502)
    return JsonResponse(data)


@login_required
def services_source(request, playbook):
    """Return the raw playbook source (read-only) for display in the WebUI."""
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    from .utils.ssh_exec import run_service_source
    ok, out = run_service_source(playbook)
    if not ok and not out.strip():
        return JsonResponse({'error': out or 'source fetch failed'}, status=502)
    return JsonResponse({'source': out})


@login_required
def services_status(request, playbook):
    item = get_playbook(playbook)
    if item is None:
        return JsonResponse({'error': 'Playbook not found'}, status=404)
    services = item['docs'].get('service_control', {}).get('services', [])
    out = []
    for s in services:
        r = _dispatch(s, 'status')
        if r:
            raw = (r.get('output') or '').strip()
            state = _normalize_state(s.get('type'), raw)
            out.append({
                'name': s.get('name'),
                'type': s.get('type'),
                'status': raw,
                'ok': r.get('ok'),
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


@login_required
def services_playbook_log(request, service_name):
    return JsonResponse({'running': False, 'output': ''})


@login_required
def services_playbook_output(request, service_name):
    return JsonResponse({'output': ''})


@login_required
def services_directories(request, service_name):
    return JsonResponse({'directories': []})
