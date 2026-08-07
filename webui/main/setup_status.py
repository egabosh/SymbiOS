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
    'ddns': (
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
    'ddns': 'ddns',
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
        if inventory_vars.get('timezone') and inventory_vars.get('keyboard'):
            return ('ok', 'Configured',
                    'Timezone and keyboard are set up.')
        return ('missing', 'Not configured',
                'Timezone and keyboard are not set up yet.')

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

    Each step is a dict: key, title, subtitle, optional, status
    ('done' / 'pending' / 'optional') and url.
    """
    checks = _load_runchecks()
    steps = []

    # Step: Localization
    loc_done = bool(inventory_vars.get('timezone') and inventory_vars.get('keyboard'))
    steps.append({
        'key': 'localization',
        'title': 'Language, Timezone & Keyboard',
        'subtitle': 'Foundation for correct times and input.',
        'optional': False,
        'status': 'done' if loc_done else 'pending',
        'url': '/settings/localization/',
    })

    # Step: Separate disk (optional)
    disk_status = checks.get('disk')
    steps.append({
        'key': 'disk',
        'title': 'Separate Data Disk (optional)',
        'subtitle': 'More space \u2014 optionally encrypted.',
        'optional': True,
        'status': 'done' if disk_status == 'ok' else 'optional',
        'url': '/settings/disk/',
    })

    # Step: Connection type
    network_type = inventory_vars.get('network_type', '')
    steps.append({
        'key': 'network',
        'title': 'Server connection type',
        'subtitle': ('Home connection behind a router or root server with '
                     'its own public IP?'),
        'optional': False,
        'status': 'done' if network_type else 'pending',
        'url': '/setup/#step-network',
    })

    # Step: DNS
    dns_done = bool(inventory_vars.get('base_domain') and inventory_vars.get('dns_mode'))
    dns_status = checks.get('ddns')
    steps.append({
        'key': 'dns',
        'title': 'Set up a Name (DNS)',
        'subtitle': 'E.g. <code>my-server.dedyn.io</code> \u2014 prerequisite '
                    'for everything else.',
        'optional': False,
        'status': 'done' if (dns_done and dns_status == 'ok') else 'pending',
        'url': '/settings/ddns/',
    })

    # Step: Port forwarding (only relevant for home)
    ports_relevant = bool(network_type and network_type != 'root')
    ports_configured = bool(inventory_vars.get('port_forwarding_configured'))
    if not ports_relevant:
        ports_status = 'optional'
    elif ports_configured:
        ports_status = 'done'
    else:
        ports_status = 'pending'
    steps.append({
        'key': 'ports',
        'title': 'Open Ports',
        'subtitle': 'Forward ports 80/443 from the router to the server.',
        'optional': not ports_relevant,
        'status': ports_status,
        'url': '/settings/port-forwarding/',
    })

    # Step: Reachability
    reach_done = checks.get('reachability')
    steps.append({
        'key': 'reachability',
        'title': 'Check Reachability',
        'subtitle': 'Test from outside whether the server is reachable.',
        'optional': False,
        'status': 'done' if reach_done == 'ok' else 'pending',
        'url': '/setup/#step-reachability',
    })

    # Step: TLS certificates
    cert_status = checks.get('certs')
    steps.append({
        'key': 'certs',
        'title': 'Security Certificates (TLS)',
        'subtitle': 'Valid certificates against the browser warning.',
        'optional': False,
        'status': 'done' if cert_status == 'ok' else 'pending',
        'url': '/settings/acme/',
    })

    # Step: SMTP (optional)
    smtp_done = bool(inventory_vars.get('smtp_server') and inventory_vars.get('smtp_from'))
    steps.append({
        'key': 'smtp',
        'title': 'Email Sending (SMTP) \u2014 optional',
        'subtitle': 'For notifications and 2FA codes.',
        'optional': True,
        'status': 'done' if smtp_done else 'optional',
        'url': '/settings/mailserver/',
    })

    # Step: 2FA (optional)
    twofa_done = bool(inventory_vars.get('twofa_enabled'))
    steps.append({
        'key': 'twofa',
        'title': '2-Factor Authentication (2FA) \u2014 optional',
        'subtitle': 'Additional protection when logging in.',
        'optional': True,
        'status': 'done' if twofa_done else 'optional',
        'url': '/settings/auth/',
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
