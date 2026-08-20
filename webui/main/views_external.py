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

"""CRUD views for external systems management.

External systems are remote hosts (Linux Mint, OpenWrt, etc.) that can be
managed via SSH from the SymbiOS host. Playbooks in external-services/ are
executed on these targets using ansible-playbook --connection=ssh.
"""
import json
import os
import yaml
import shlex

from django.http import JsonResponse
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages as flash_messages

from .decorators import login_required
from .playbook_catalog import get_catalog


# Config file for external systems (alongside inventory.yml)
EXTERNAL_SYSTEMS_CONFIG = os.environ.get(
    'EXTERNAL_SYSTEMS_CONFIG',
    os.path.join(os.path.dirname(os.environ.get('CONFIG_PATH', '/config/inventory.yml')),
                 'external-systems.yml'),
)


def _load_systems():
    """Load external systems from config file."""
    try:
        with open(EXTERNAL_SYSTEMS_CONFIG) as fh:
            data = yaml.safe_load(fh) or {}
        return data.get('external_systems', [])
    except (FileNotFoundError, yaml.YAMLError):
        return []


def _save_systems(systems):
    """Save external systems to config file."""
    data = {'external_systems': systems}
    tmp = EXTERNAL_SYSTEMS_CONFIG + '.tmp'
    with open(tmp, 'w') as fh:
        yaml.dump(data, fh, default_flow_style=False, allow_unicode=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, EXTERNAL_SYSTEMS_CONFIG)


def _get_system(system_id):
    """Get a single system by ID."""
    for s in _load_systems():
        if s.get('id') == system_id:
            return s
    return None


def _get_public_key():
    """Read the host's public SSH key."""
    # Read from host via run_command to follow symbios-exec.sh gateway pattern
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command('cat /root/.ssh/id_ed25519.pub', timeout=5)
    if ok and stdout.strip():
        return stdout.strip()
    return ''


def _get_target_types():
    """Collect all unique target types from external-services/ catalog."""
    types = set()
    for item in get_catalog():
        target = (item.get('docs') or {}).get('target') or {}
        t = target.get('type')
        if t:
            types.add(t)
    return sorted(types)


@login_required
def external_systems(request):
    """List all external systems."""
    systems = _load_systems()
    public_key = _get_public_key()
    target_types = _get_target_types()
    return render(request, 'main/external_systems.html', {
        'systems': systems,
        'public_key': public_key,
        'target_types': target_types,
    })


@login_required
def external_system_create(request):
    """Create a new external system."""
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
            return render(request, 'main/external_systems_form.html', {
                'system': request.POST,
                'target_types': _get_target_types(),
                'editing': False,
            })

        # Check for duplicate ID
        for s in systems:
            if s.get('id') == system_id:
                flash_messages.error(request, 'A system with this name already exists.')
                return render(request, 'main/external_systems_form.html', {
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
        return redirect('external_systems')

    return render(request, 'main/external_systems_form.html', {
        'system': {},
        'target_types': _get_target_types(),
        'editing': False,
    })


@login_required
def external_system_edit(request, system_id):
    """Edit an external system."""
    system = _get_system(system_id)
    if system is None:
        return redirect('external_systems')

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
        return redirect('external_systems')

    return render(request, 'main/external_systems_form.html', {
        'system': system,
        'target_types': _get_target_types(),
        'editing': True,
    })


@login_required
def external_system_delete(request, system_id):
    """Delete an external system."""
    if request.method != 'POST':
        return redirect('external_systems')
    systems = _load_systems()
    systems = [s for s in systems if s.get('id') != system_id]
    _save_systems(systems)
    flash_messages.success(request, 'External system deleted.')
    return redirect('external_systems')


@login_required
def external_system_test(request, system_id):
    """Test SSH connectivity to an external system."""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=400)
    system = _get_system(system_id)
    if system is None:
        return JsonResponse({'error': 'System not found'}, status=404)
    from .utils.ssh_exec import run_command
    host = system.get('host', '')
    port = system.get('port', 22)
    user = system.get('user', 'root')
    # Test SSH via run_command (runs on SymbiOS host, which has the SSH key)
    ok, stdout, stderr = run_command(
        'ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p %d %s@%s echo ok' % (port, shlex.quote(user), shlex.quote(host)),
        timeout=10,
    )
    if ok and 'ok' in stdout:
        return JsonResponse({'ok': True, 'message': 'SSH connection successful.'})
    return JsonResponse({'ok': False, 'error': stderr or 'Connection failed.'})


@login_required
def external_system_public_key(request):
    """Return the host's public SSH key as JSON."""
    key = _get_public_key()
    return JsonResponse({'public_key': key})


@login_required
def external_types_api(request):
    """Return all available target types as JSON."""
    return JsonResponse({'types': _get_target_types()})
