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

"""External systems management under Settings."""
import os
import yaml
import shlex

from django.shortcuts import render, redirect
from django.contrib import messages as flash_messages
from django.http import JsonResponse

from .decorators import login_required
from .playbook_catalog import get_catalog, docs_target_type


EXTERNAL_SYSTEMS_CONFIG = os.environ.get(
    'EXTERNAL_SYSTEMS_CONFIG',
    os.path.join(os.path.dirname(os.environ.get('CONFIG_PATH', '/config/inventory.yml')),
                 'external-systems.yml'),
)
EXTERNAL_STATES_DIR = os.environ.get(
    'EXTERNAL_STATES_DIR',
    os.path.join(os.path.dirname(os.environ.get('CONFIG_PATH', '/config/inventory.yml')),
                 'external-systems', 'states'),
)


def _load_systems():
    try:
        with open(EXTERNAL_SYSTEMS_CONFIG) as fh:
            data = yaml.safe_load(fh) or {}
        return data.get('external_systems', [])
    except (FileNotFoundError, yaml.YAMLError):
        return []


def _save_systems(systems):
    from .utils.ssh_exec import run_command
    import json as _json
    ok, _out, err = run_command(
        'symbios-config.py --file external-systems.yml write',
        timeout=30, stdin_data=_json.dumps({'external_systems': systems}))
    if not ok:
        raise RuntimeError(err or 'write failed')


def _get_system(system_id):
    for s in _load_systems():
        if s.get('id') == system_id:
            return s
    return None


def _get_public_key():
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command('cat /root/.ssh/id_ed25519.pub', timeout=5)
    if ok and stdout.strip():
        return stdout.strip()
    return ''


def _get_target_types():
    """All distinct target types declared by any playbook (docs.type).

    This is the dynamic source for the "System Type" dropdown: every type found
    in a playbook's docs block is offered, so adding a new external-services
    playbook with a new type makes it available automatically.
    """
    types = set()
    for item in get_catalog():
        t = docs_target_type(item.get('docs'))
        if t:
            types.add(t)
    return sorted(types)


@login_required
def settings_external_systems(request):
    systems = _load_systems()
    public_key = _get_public_key()
    target_types = _get_target_types()
    return render(request, 'main/settings/external_systems.html', {
        'systems': systems,
        'public_key': public_key,
        'target_types': target_types,
    })


@login_required
def settings_external_system_create(request):
    if request.method == 'POST':
        systems = _load_systems()
        system_id = request.POST.get('name', '').strip().lower().replace(' ', '-')
        name = request.POST.get('name', '').strip()
        host = request.POST.get('host', '').strip()
        port = request.POST.get('port', '22').strip()
        user = request.POST.get('user', 'root').strip()
        system_type = request.POST.get('type', '').strip()
        description = request.POST.get('description', '').strip()

        if not name or not host or not system_type:
            flash_messages.error(request, 'Name, Host, and Type are required.')
            return render(request, 'main/settings/external_systems_form.html', {
                'system': request.POST,
                'target_types': _get_target_types(),
                'editing': False,
            })

        for s in systems:
            if s.get('id') == system_id:
                flash_messages.error(request, 'A system with this name already exists.')
                return render(request, 'main/settings/external_systems_form.html', {
                    'system': request.POST,
                    'target_types': _get_target_types(),
                    'editing': False,
                })

        systems.append({
            'id': system_id,
            'name': name,
            'host': host,
            'port': int(port) if port else 22,
            'user': user,
            'type': system_type,
            'description': description,
        })
        _save_systems(systems)
        flash_messages.success(request, 'External system "%s" created.' % name)
        return redirect('settings_external_systems')

    return render(request, 'main/settings/external_systems_form.html', {
        'system': {},
        'target_types': _get_target_types(),
        'editing': False,
    })


@login_required
def settings_external_system_edit(request, system_id):
    system = _get_system(system_id)
    if system is None:
        return redirect('settings_external_systems')

    if request.method == 'POST':
        systems = _load_systems()
        for s in systems:
            if s.get('id') == system_id:
                s['name'] = request.POST.get('name', s['name']).strip()
                s['host'] = request.POST.get('host', s['host']).strip()
                s['port'] = int(request.POST.get('port', s.get('port', 22)))
                s['user'] = request.POST.get('user', s.get('user', 'root')).strip()
                s['type'] = request.POST.get('type', s['type']).strip()
                s['description'] = request.POST.get('description', '').strip()
                break
        _save_systems(systems)
        flash_messages.success(request, 'External system updated.')
        return redirect('settings_external_systems')

    return render(request, 'main/settings/external_systems_form.html', {
        'system': system,
        'target_types': _get_target_types(),
        'editing': True,
    })


@login_required
def settings_external_system_delete(request, system_id):
    if request.method != 'POST':
        return redirect('settings_external_systems')
    systems = _load_systems()
    systems = [s for s in systems if s.get('id') != system_id]
    _save_systems(systems)
    flash_messages.success(request, 'External system deleted.')
    return redirect('settings_external_systems')


@login_required
def settings_external_system_test(request, system_id):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=400)
    system = _get_system(system_id)
    if system is None:
        return JsonResponse({'error': 'System not found'}, status=404)
    from .utils.ssh_exec import run_command
    host = system.get('host', '')
    port = system.get('port', 22)
    user = system.get('user', 'root')
    ok, stdout, stderr = run_command(
        'ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p %d %s@%s echo ok' % (port, shlex.quote(user), shlex.quote(host)),
        timeout=10,
    )
    if ok and 'ok' in stdout:
        return JsonResponse({'ok': True, 'message': 'SSH connection successful.'})
    return JsonResponse({'ok': False, 'error': stderr or 'Connection failed.'})


@login_required
def settings_external_system_install_key(request, system_id):
    """Install the host's public key on the target so later logins are key-based.

    The one-time password travels on stdin (never argv / audit log) and is only
    used to open this first connection; afterwards the ed25519 key authenticates.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=400)
    system = _get_system(system_id)
    if system is None:
        return JsonResponse({'error': 'System not found'}, status=404)
    password = request.POST.get('password', '')
    if not password:
        return JsonResponse({'error': 'Password required'}, status=400)
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command(
        'symbios-remote-install-key.sh %s' % shlex.quote(system_id),
        timeout=30, stdin_data=password)
    if ok:
        return JsonResponse({'ok': True,
                             'message': 'SSH key installed on %s.' % system.get('name', system_id)})
    return JsonResponse({'ok': False, 'error': (stderr or stdout or 'Install failed.').strip()})


@login_required
def settings_external_system_sync(request, system_id):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=400)
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command(f'symbios-remote-sync.sh {shlex.quote(system_id)}', timeout=60)
    if ok:
        return JsonResponse({'ok': True, 'message': stdout or 'Synced'})
    return JsonResponse({'ok': False, 'error': stderr or stdout or 'Sync failed.'})


@login_required
def settings_external_system_inventory(request, system_id):
    import json
    data = {'managed': []}
    try:
        path = os.path.join(EXTERNAL_STATES_DIR, f'{system_id}.json')
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        pass
    return JsonResponse(data)


@login_required
def settings_external_system_public_key(request):
    key = _get_public_key()
    return JsonResponse({'public_key': key})


@login_required
def settings_external_types_api(request):
    return JsonResponse({'types': _get_target_types()})
