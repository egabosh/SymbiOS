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

import json
from django.shortcuts import render
from .decorators import login_required
from .playbook_catalog import get_catalog
from .views_services import _get_installed_playbooks, _get_healthcheck_status, _order_catalog


def _get_failing_healthchecks():
    """Read runchecks-results.json and return only checks with status != 'ok'."""
    results_file = '/log/runchecks-results.json'
    try:
        with open(results_file) as fh:
            data = json.load(fh)
    except (FileNotFoundError, PermissionError, json.JSONDecodeError):
        return []
    checks = data.get('checks', [])
    last_run = data.get('last_run', '')
    failing = []
    for c in checks:
        if c.get('status') != 'ok':
            failing.append({
                'name': c.get('name', '?'),
                'status': c.get('status', 'unknown'),
                'message': c.get('message', ''),
                'title': c.get('title', c.get('name', '?')),
                'last_run': c.get('checked', last_run),
            })
    return failing


@login_required
def home(request):
    """Dashboard homepage: failing healthchecks + installed services."""
    from .views import _get_inventory_config, _get_ldap_users
    from .setup_status import setup_steps, is_setup_complete

    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    ldap_users = _get_ldap_users()
    steps = setup_steps(vars_, ldap_users=ldap_users)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']

    # Failing healthchecks
    failing_checks = _get_failing_healthchecks()

    # Installed services with healthcheck status
    catalog = get_catalog()
    installed = _get_installed_playbooks()
    ordered = _order_catalog(catalog)
    healthcheck_status = _get_healthcheck_status()
    installed_services = [i for i in ordered if i.get('playbook', '') in installed
                         and i.get('group') != 'base-services']
    available_services = [i for i in ordered
                         if i.get('group') != 'base-services'
                         and i.get('playbook', '') not in installed]

    return render(request, 'main/home.html', {
        'setup_incomplete': not is_setup_complete(vars_, ldap_users=ldap_users),
        'setup_pending': len(pending),
        'failing_checks': failing_checks,
        'installed_services': installed_services,
        'available_services': available_services,
        'healthcheck_status': healthcheck_status,
    })
