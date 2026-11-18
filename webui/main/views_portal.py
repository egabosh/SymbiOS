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

from urllib.parse import urlsplit

from django.shortcuts import render

from .playbook_catalog import get_catalog
from .views import _get_inventory_config
from .views_home import home as admin_home
from .views_services import _get_installed_playbooks, _render_service_url


def root(request):
    """Serve the user portal on portal.<base_domain>, the dashboard on the apex."""
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {}) or {}
    base_domain = str(vars_.get('base_domain') or '')
    host = request.get_host().split(':')[0]
    if base_domain and host == 'portal.' + base_domain:
        return portal_home(request, vars_)
    return admin_home(request)


def portal_home(request, vars_=None):
    """Render tiles for installed services the current user may access.

    The groups come from the Authelia forward-auth response and are attached
    to the user by AutheliaMiddleware only when the request came from Traefik.
    Admins (ldap-admins / local break-glass) see every service.
    """
    if vars_ is None:
        config = _get_inventory_config()
        vars_ = config.get('all', {}).get('vars', {}) or {}
    base_domain = str(vars_.get('base_domain') or '')

    user = request.user
    groups = set(getattr(user, 'groups', None) or [])
    is_admin = bool(getattr(user, 'is_staff', False))

    installed = _get_installed_playbooks()
    tiles = []
    for item in get_catalog():
        if item.get('group') != 'services':
            continue
        if item.get('playbook') not in installed:
            continue

        docs = item.get('docs') or {}
        url = _render_service_url(docs.get('url'))
        # Only browser-reachable services get a tile. Non-HTTP endpoints
        # (TURN, SFTP, ...) cannot be launched from a portal page.
        if not url.lower().startswith(('http://', 'https://')):
            continue

        access = docs.get('access') or {}
        if not is_admin and isinstance(access, dict) and 'none' not in access:
            allowed = {access.get('user_group'), access.get('admin_group')} - {None}
            if not allowed.intersection(groups):
                continue

        tiles.append({
            'name': item.get('menu_label') or docs.get('name') or item.get('playbook'),
            'description': docs.get('short_description') or '',
            'url': url,
            'host': urlsplit(url).hostname or url,
            'icon': str(docs.get('icon') or 'bi-box-seam'),
        })
    tiles.sort(key=lambda tile: tile['name'].lower())

    logout_url = ('https://auth.' + base_domain + '/logout') if base_domain else '/authelia-logout/'
    return render(request, 'main/portal.html', {
        'tiles': tiles,
        'logout_url': logout_url,
    })
