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

import subprocess
import os
import socket
import struct
from django.shortcuts import redirect

from .auth_user import SymbiosUser, AnonymousUser
from .constants import LDAP_URI


def _trusted_proxy_addresses():
    # Only the reverse proxy (Traefik) may assert the Authelia forward-auth
    # Remote-User header. Any other source (e.g. a client on the docker network
    # hitting :8080 directly) must not be able to spoof "Remote-User: admin".
    # Traefik is resolved via Docker DNS so the allowlist tracks its (possibly
    # changing) container IP.
    addrs = set()
    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            for info in socket.getaddrinfo('traefik', None, family, 0, socket.SOCK_STREAM):
                addrs.add(info[4][0])
        except Exception:
            pass
    return addrs


def _host_source_addresses():
    # Addresses from which the operator may use the passwordless break-glass
    # admin on 127.0.0.1:8080.
    #  * 127.0.0.1/::1: reached when exec'ing into the container and hitting
    #    its own loopback.
    #  * host.docker.internal: the host as seen from the container.
    #  * the default-route gateway: when the host reaches the published port via
    #    the docker-proxy, the source IP is NAT'd to the bridge gateway address,
    #    so we must treat that gateway as "from the host".
    addrs = {'127.0.0.1', '::1'}
    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            for info in socket.getaddrinfo('host.docker.internal', None, family, 0, socket.SOCK_STREAM):
                addrs.add(info[4][0])
        except Exception:
            pass
    try:
        with open('/proc/net/route') as f:
            for line in f.readlines()[1:]:
                parts = line.split()
                if len(parts) >= 4 and parts[1] == '00000000' and parts[2] != '00000000':
                    gw = int(parts[2], 16)
                    addrs.add(socket.inet_ntoa(struct.pack('<I', gw)))
    except Exception:
        pass
    return addrs


def _admin_password_is_default():
    try:
        import yaml
        config_path = os.environ.get('CONFIG_PATH', '/config/inventory.yml')
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        base_dn = config.get('all', {}).get('vars', {}).get('ldap_basedn', 'dc=openldap,dc=local')
    except Exception:
        base_dn = 'dc=openldap,dc=local'
    admin_dn = f'uid=admin,ou=users,{base_dn}'
    proc = subprocess.run(
        ['ldapwhoami', '-x', '-H', LDAP_URI, '-D', admin_dn, '-w', 'admin'],
        capture_output=True, text=True, timeout=10,
    )
    return proc.returncode == 0


class AutheliaMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        # Resolve proxy/host allowlists once at startup; container IPs are stable
        # for the process lifetime and Docker DNS churn within a boot is rare.
        self._trusted = _trusted_proxy_addresses()
        self._host = _host_source_addresses()

    def __call__(self, request):
        remote_addr = request.META.get('REMOTE_ADDR', '')
        user = None

        # Host-local break-glass: 127.0.0.1:8080 is only reachable from the
        # host itself (loopback, or via SSH tunnel to the host). The docker-proxy
        # masks the source as the bridge gateway, which we also trust as "host".
        if remote_addr in self._host:
            user = SymbiosUser('admin', is_staff=True, is_superuser=True)
        else:
            remote_user = request.META.get('HTTP_REMOTE_USER')
            # Only honor the forward-auth header when it originates from the
            # proxy; drop it otherwise so it cannot be spoofed.
            if remote_user and remote_addr in self._trusted:
                user = SymbiosUser(
                    remote_user,
                    is_staff=remote_user in ('admin', 'root'),
                    is_superuser=remote_user in ('admin', 'root'),
                )
                if remote_user == 'admin' and 'force_password_change' not in request.session:
                    if _admin_password_is_default():
                        request.session['force_password_change'] = True

        request.user = user if user is not None else AnonymousUser()

        if (request.user.is_authenticated
                and request.session.get('force_password_change')
                and request.path not in ('/change-password/', '/logout/', '/authelia-logout/')):
            return redirect('/change-password/')

        return self.get_response(request)
