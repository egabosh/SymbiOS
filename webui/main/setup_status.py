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

"""Setup status derivation for the WebUI.

Derives the state of every setup step from real configuration
(inventory.yml + runchecks-results.json), so the /setup/ assistant and
the per-page status badges never go stale and are never duplicated.

No host execution happens here - only local file reads inside the
container (/config and /log mounts).
"""

import json
import os

RUNCHECKS_FILE = '/log/runchecks-results.json'

# Plain-language explanations shown on each settings page ("What is this page for?").
PAGE_EXPLAIN = {
    'dns': (
        'The server needs a name on the internet, e.g. '
        '<code>my-server.dedyn.io</code>. All services will be reachable '
        'under this name and Let\u2019s Encrypt will issue certificates for it.'
    ),
    'mailserver': (
        'For notifications and 2-Factor Authentication (2FA), the server '
        'needs the ability to send emails. For that, an SMTP account is '
        'configured.'
    ),
    'auth': (
        'Authelia protects all web services with a login. With 2FA, a code '
        'or TOTP token is additionally required when logging in \u2014 this '
        'protects you even if your password is stolen.'
    ),
    'acme': (
        'To prevent the browser from showing a security warning, valid TLS '
        'certificates from Let\u2019s Encrypt are obtained for all services '
        'and renewed automatically.'
    ),
    'ssh-keys': (
        'Here you define which SSH keys may log in as root on the server. '
        'This is more secure than a password.'
    ),
    'backup': (
        'The server can regularly back up its data to an external SFTP '
        'server. This way your data survives a failure.'
    ),
    'port-forwarding': (
        'For the server to be reachable from outside, ports 80 (HTTP) and '
        '443 (HTTPS) must be forwarded from the router to the server. '
        'SymbiOS can open these ports for you automatically on the router '
        '(or you can do it manually).'
    ),
    'disk': (
        'By default, all data is stored on the system SD card. A separate '
        'hard disk provides more space and \u2014 optionally encrypted \u2014 '
        'more security.'
    ),
    'localization': (
        'Timezone, keyboard and language are used so that times and input '
        'on the server and in the web interface are correct.'
    ),
}

# Map settings page -> runchecks check name (for the status badge).
PAGE_CHECK = {
    'mailserver': 'smtp',
    'auth': 'twofa',
    'acme': 'certs',
    'disk': 'disk',
}


def _load_runchecks():
    """Read the runchecks daemon output, return {name: status}."""
    try:
        with open(RUNCHECKS_FILE) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        return {}
    result = {}
    for c in data.get('checks', []):
        name = c.get('name')
        if name:
            result[name] = c.get('status', 'unknown')
    return result


def get_page_badge(page_key, inventory_vars):
    """Compute the status badge for a settings page.

    Returns (status, label, text) where status is one of
    'ok' / 'warn' / 'missing' / 'none'.
    """
    checks = _load_runchecks()

    if page_key == 'localization':
        if inventory_vars.get('localization_configured'):
            return ('ok', 'Configured',
                    'Timezone and keyboard are set up.')
        return ('missing', 'Not configured',
                'Timezone and keyboard are not set up yet.')

    if page_key == 'dns':
        if inventory_vars.get('dns_configured'):
            return ('ok', 'Configured',
                    'The DNS name is set up.')
        return ('missing', 'Not configured',
                'The server has no name on the internet yet.')

    if page_key == 'port-forwarding':
        if inventory_vars.get('port_forwarding_configured'):
            return ('ok', 'All good',
                    'Ports 80/443 are forwarded to the server.')
        if inventory_vars.get('base_domain'):
            return ('warn', 'Configured',
                    'DNS is set up. Open ports 80/443 on the router '
                    '(Port Forwarding page).')
        return ('missing', 'DNS required',
                'First set up a name under DNS.')

    check_name = PAGE_CHECK.get(page_key)
    status = checks.get(check_name) if check_name else None
    if status == 'ok':
        return ('ok', 'All good', 'The service is running and configured.')
    if status == 'error':
        return ('error', 'Problem found',
                'The service reports a problem \u2014 see details on the Health page.')
    if status == 'warn':
        return ('warn', 'Warning', 'The service reports a warning.')
    return ('none', 'Not set up yet', 'This service is not set up yet.')


def setup_steps(inventory_vars):
    """Compute the ordered list of setup steps for the /setup/ assistant.

    The steps must be completed in order: the server connection type first
    (it decides which of the following steps are needed), then localization,
    DNS and port forwarding. Optional settings (disk, TLS, SMTP, 2FA) are
    handled on their own settings pages and are deliberately not part of the
    assistant.

    Each step is a dict: key, title, subtitle, optional, status
    ('done' / 'pending' / 'optional') and url.
    """
    network_type = inventory_vars.get('network_type', '')
    steps = []

    # Step 1: Connection type — first mandatory choice. Determines whether
    # the "Open Ports" step is needed at all.
    steps.append({
        'key': 'network',
        'title': 'Server connection type',
        'subtitle': ('First decision: home connection behind a router or '
                     'root server with its own public IP?'),
        'optional': False,
        'status': 'done' if network_type else 'pending',
        'url': '/setup/#step-network',
    })

    # Step 2: Localization — done only after the user explicitly confirmed the
    # settings in the WebUI (the shipped timezone/keyboard defaults alone do
    # not count as configuration).
    loc_done = bool(inventory_vars.get('localization_configured'))
    steps.append({
        'key': 'localization',
        'title': 'Language, Timezone & Keyboard',
        'subtitle': 'Foundation for correct times and input.',
        'optional': False,
        'status': 'done' if loc_done else 'pending',
        'url': '/settings/localization/',
    })

    # Step 3: DNS — done after the user explicitly saved the DNS settings in
    # the WebUI (the runcheck status is not part of the setup state; it only
    # reflects whether the ddns updater currently works).
    dns_done = bool(inventory_vars.get('dns_configured'))
    steps.append({
        'key': 'dns',
        'title': 'Set up a Name (DNS)',
        'subtitle': 'E.g. <code>my-server.dedyn.io</code> \u2014 prerequisite '
                    'for everything else.',
        'optional': False,
        'status': 'done' if dns_done else 'pending',
        'url': '/settings/dns/',
    })

    # Step 4: Port forwarding — only needed on a home connection; a root
    # server has its own public IP and ports 80/443 are already reachable.
    ports_configured = bool(inventory_vars.get('port_forwarding_configured'))
    ports_optional = network_type == 'root'
    if ports_optional:
        ports_status = 'optional'
        ports_subtitle = ('Not needed \u2014 a root server has its own '
                          'public IP.')
    elif ports_configured:
        ports_status = 'done'
        ports_subtitle = 'Forward ports 80/443 from the router to the server.'
    else:
        ports_status = 'pending'
        ports_subtitle = 'Forward ports 80/443 from the router to the server.'
    steps.append({
        'key': 'ports',
        'title': 'Open Ports',
        'subtitle': ports_subtitle,
        'optional': ports_optional,
        'status': ports_status,
        'url': '/settings/port-forwarding/',
    })

    return steps


def is_setup_complete(inventory_vars):
    """True when all non-optional steps are done."""
    for step in setup_steps(inventory_vars):
        if not step['optional'] and step['status'] != 'done':
            return False
    return True


def network_type_label(network_type):
    """Human-readable label for the stored network type."""
    return {
        'home': 'Home connection (behind router)',
        'root': 'Root server (own public IP)',
    }.get(network_type, '')
