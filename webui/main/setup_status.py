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

# Plain-language explanations shown on each settings page ("Wozu dient diese Seite?").
PAGE_EXPLAIN = {
    'ddns': (
        'Der Server braucht einen Namen im Internet, z. B. '
        '<code>mein-server.dedyn.io</code>. Unter diesem Namen werden alle '
        'Dienste erreichbar sein und Let\u2019s Encrypt stellt daf\u00fcr '
        'Zertifikate aus.'
    ),
    'mailserver': (
        'F\u00fcr Benachrichtigungen und die 2-Faktor-Anmeldung (2FA) '
        'ben\u00f6tigt der Server die M\u00f6glichkeit, E-Mails zu versenden. '
        'Dazu wird ein SMTP-Konto eingerichtet.'
    ),
    'auth': (
        'Authelia sch\u00fctzt alle Web-Dienste mit einem Login. Mit 2FA '
        'wird beim Anmelden zus\u00e4tzlich ein Code oder ein TOTP-Token '
        'verlangt \u2014 das sch\u00fctzt auch bei gestohlenem Passwort.'
    ),
    'acme': (
        'Damit der Browser keine Sicherheitswarnung anzeigt, werden f\u00fcr '
        'alle Dienste g\u00fcltige TLS-Zertifikate von Let\u2019s Encrypt '
        'bezogen und automatisch erneuert.'
    ),
    'ssh-keys': (
        'Hier wird festgelegt, welche SSH-Schl\u00fcssel sich als root auf '
        'dem Server anmelden d\u00fcrfen. Das ist sicherer als ein Passwort.'
    ),
    'backup': (
        'Der Server kann seine Daten regelm\u00e4\u00dfig auf einen '
        'externen SFTP-Server sichern. So \u00fcberlebt ein Ausfall die Daten.'
    ),
    'port-forwarding': (
        'Damit der Server von au\u00dferhalb erreichbar ist, m\u00fcssen die '
        'Ports 80 (HTTP) und 443 (HTTPS) vom Router zum Server weitergeleitet '
        'werden. Mit UPnP geht das automatisch.'
    ),
    'disk': (
        'Standardm\u00e4\u00dfig liegen alle Daten auf der System-SD-Karte. '
        'Eine separate Festplatte gibt mehr Platz und \u2014 optional '
        'verschl\u00fcsselt \u2014 mehr Sicherheit.'
    ),
    'localization': (
        'Zeitzone, Tastatur und Sprache werden verwendet, damit Uhrzeiten '
        'und Eingaben auf dem Server und im Web-Interface stimmen.'
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
            return ('ok', 'Konfiguriert',
                    'Zeitzone und Tastatur sind eingerichtet.')
        return ('missing', 'Nicht eingerichtet',
                'Zeitzone und Tastatur sind noch nicht eingerichtet.')

    if page_key == 'port-forwarding':
        base_domain = inventory_vars.get('base_domain', '')
        if base_domain:
            return ('warn', 'Konfiguriert',
                    'DNS ist eingerichtet. Pr\u00fcfe die Erreichbarkeit '
                    'auf der Erreichbarkeits-Seite.')
        return ('missing', 'Ben\u00f6tigt DNS',
                'Richte zuerst unter DNS einen Namen ein.')

    check_name = PAGE_CHECK.get(page_key)
    status = checks.get(check_name) if check_name else None
    if status == 'ok':
        return ('ok', 'Alles in Ordnung', 'Der Dienst l\u00e4uft und ist konfiguriert.')
    if status == 'error':
        return ('error', 'Problem gefunden',
                'Der Dienst meldet ein Problem \u2014 Details siehe Health-Seite.')
    if status == 'warn':
        return ('warn', 'Warnung', 'Der Dienst meldet eine Warnung.')
    return ('none', 'Noch nicht eingerichtet', 'Dieser Dienst ist noch nicht eingerichtet.')


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
        'title': 'Sprache, Zeitzone & Tastatur',
        'subtitle': 'Grundlage f\u00fcr korrekte Zeiten und Eingaben.',
        'optional': False,
        'status': 'done' if loc_done else 'pending',
        'url': '/settings/localization/',
    })

    # Step: Separate disk (optional)
    disk_status = checks.get('disk')
    steps.append({
        'key': 'disk',
        'title': 'Separate Daten-Platte (optional)',
        'subtitle': 'Mehr Platz \u2014 optional verschl\u00fcsselt.',
        'optional': True,
        'status': 'done' if disk_status == 'ok' else 'optional',
        'url': '/settings/disk/',
    })

    # Step: Network type
    network_type = inventory_vars.get('network_type', '')
    steps.append({
        'key': 'network',
        'title': 'Standort des Servers',
        'subtitle': ('Heimanschluss hinter Router oder Root-Server mit '
                     'eigener \u00f6ffentlicher IP?'),
        'optional': False,
        'status': 'done' if network_type else 'pending',
        'url': '/setup/#step-network',
    })

    # Step: DNS
    dns_done = bool(inventory_vars.get('base_domain') and inventory_vars.get('dns_mode'))
    dns_status = checks.get('ddns')
    steps.append({
        'key': 'dns',
        'title': 'Name (DNS) einrichten',
        'subtitle': 'Z. B. <code>mein-server.dedyn.io</code> \u2014 Voraussetzung '
                    'f\u00fcr alles Weitere.',
        'optional': False,
        'status': 'done' if (dns_done and dns_status == 'ok') else 'pending',
        'url': '/settings/ddns/',
    })

    # Step: Port forwarding (only relevant for home)
    steps.append({
        'key': 'ports',
        'title': 'Ports freigeben',
        'subtitle': 'Ports 80/443 vom Router zum Server weiterleiten.',
        'optional': False,
        'status': 'pending' if (network_type and network_type != 'root') else 'optional',
        'url': '/settings/port-forwarding/',
    })

    # Step: Reachability
    reach_done = checks.get('reachability')
    steps.append({
        'key': 'reachability',
        'title': 'Erreichbarkeit pr\u00fcfen',
        'subtitle': 'Von au\u00dfen testen, ob der Server erreichbar ist.',
        'optional': False,
        'status': 'done' if reach_done == 'ok' else 'pending',
        'url': '/setup/#step-reachability',
    })

    # Step: TLS certificates
    cert_status = checks.get('certs')
    steps.append({
        'key': 'certs',
        'title': 'Sicherheits-Zertifikate (TLS)',
        'subtitle': 'G\u00fcltige Zertifikate gegen die Browser-Warnung.',
        'optional': False,
        'status': 'done' if cert_status == 'ok' else 'pending',
        'url': '/settings/acme/',
    })

    # Step: SMTP (optional)
    smtp_done = bool(inventory_vars.get('smtp_server') and inventory_vars.get('smtp_from'))
    steps.append({
        'key': 'smtp',
        'title': 'E-Mail-Versand (SMTP) \u2014 optional',
        'subtitle': 'F\u00fcr Benachrichtigungen und 2FA-Codes.',
        'optional': True,
        'status': 'done' if smtp_done else 'optional',
        'url': '/settings/mailserver/',
    })

    # Step: 2FA (optional)
    twofa_done = bool(inventory_vars.get('twofa_enabled'))
    steps.append({
        'key': 'twofa',
        'title': '2-Faktor-Anmeldung (2FA) \u2014 optional',
        'subtitle': 'Zus\u00e4tzlicher Schutz beim Anmelden.',
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
        'home': 'Heimanschluss (hinter Router)',
        'root': 'Root-Server (eigene \u00f6ffentliche IP)',
    }.get(network_type, '')
