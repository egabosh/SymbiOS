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


from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config
from .views_settings import _start_reapply
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .setup_status import get_page_badge, PAGE_EXPLAIN

import json
import shlex
import socket
import urllib.request
import urllib.error


# Playbooks that configure all domain-dependent services. A DNS domain is the
# prerequisite for the reverse proxy (Traefik, which also handles the ACME
# certificates) and the Authelia SSO, so these are only applied once DNS is
# configured. They are run with --force because they may not be installed yet.
_DNS_CHAIN = [
    'base-services/traefik.yml',
    'base-services/authelia.yml',
]
_DNS_CHAIN_DESEC = ['base-services/dedyn.yml'] + _DNS_CHAIN

# The system hostname follows base_domain. It is applied first so the reapply
# runs under the new name, and its output appears in the same exec modal.
_HOSTNAME_CMD = 'symbios-set-hostname.sh'


@login_required
def settings_dns(request):
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    # Determine current DNS mode from inventory
    current_dns_mode = vars_.get('dns_mode', '')
    if not current_dns_mode:
        # Backward compatibility: if ddns_host is set, assume desec mode
        current_dns_mode = 'desec' if vars_.get('ddns_host') else ''

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        action = request.POST.get('action', 'save')
        dns_mode = request.POST.get('dns_mode', 'desec')
        # Validation and the inventory write live in the settings CLI
        # (single source of truth). Secrets travel via stdin JSON, never
        # as argv. Playbook chains abort on validation failure (&&).
        try:
            if action == 'remove':
                set_cmd = 'symbios-settings-dns.sh remove'
                stdin_data = None
                playbooks = None
                message = 'DNS configuration removed.'
                title = 'Removing DNS config and reapplying...'
            elif dns_mode == 'self-managed':
                self_domain = request.POST.get('self_domain', '').strip()
                set_cmd = ('symbios-settings-dns.sh set --mode self-managed'
                           f' --domain {shlex.quote(self_domain)}')
                stdin_data = None
                playbooks = _DNS_CHAIN
                message = f'DNS settings saved for {self_domain}.'
                title = None
            else:
                # deSEC mode: host/key/ipv6 as stdin JSON (secret-safe).
                # Host normalization (.dedyn.io suffix, lowercase) lives
                # in the script.
                payload = json.dumps({
                    'ddns_host': request.POST.get('ddns_host', ''),
                    'ddns_apikey': request.POST.get('ddns_apikey', ''),
                    'ddns_ipv6': request.POST.get('ddns_ipv6', ''),
                })
                set_cmd = 'symbios-settings-dns.sh set --mode desec --json-stdin'
                stdin_data = payload
                playbooks = _DNS_CHAIN_DESEC
                message = 'DNS settings saved.'
                title = None
            if is_ajax:
                if playbooks:
                    job_id, job_title, cmd = _start_reapply(
                        playbooks=playbooks, force=True,
                        prefix=f'{set_cmd} && {_HOSTNAME_CMD}',
                        stdin_data=stdin_data)
                else:
                    from .utils.jobs import create_job
                    cmd = f'{set_cmd} && {_HOSTNAME_CMD} && symbios-reapply.sh'
                    job_id = create_job(cmd, timeout=3600,
                                        stdin_data=stdin_data)
                    job_title = title
                resp = {'ok': True, 'job': job_id,
                        'title': job_title,
                        'message': message,
                        'command': cmd}
                if 'setup' in request.GET:
                    resp['redirect'] = '/setup/'
                return JsonResponse(resp)
            ok, stdout, stderr = run_command(set_cmd, timeout=30,
                                            stdin_data=stdin_data)
            if not ok:
                messages.error(request, f'Error: {stderr or stdout}')
                return redirect('settings_dns')
            messages.success(request, message)
            if playbooks:
                # Apply the domain-dependent playbooks (DDNS, Traefik,
                # ACME, Authelia) in the background, with the new domain.
                messages.info(request, 'Reapplying DNS playbooks in the background...')
                _start_reapply(playbooks=playbooks, force=True,
                               prefix=_HOSTNAME_CMD)
            else:
                messages.info(request, 'Reapplying all playbooks in the background...')
                _start_reapply(prefix=_HOSTNAME_CMD)
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        if 'setup' in request.GET:
            return redirect('setup')
        return redirect('settings_dns')

    badge = get_page_badge('dns', vars_)
    return render(request, 'main/settings_dns.html', {
        'vars': vars_,
        'dns_mode': current_dns_mode,
        'self_domain': vars_.get('base_domain', '') if current_dns_mode == 'self-managed' else '',
        'page_key': 'dns',
        'page_icon': 'bi-globe',
        'page_title': 'DNS',
        'page_explain': PAGE_EXPLAIN['dns'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_dns_check_domain(request):
    """AJAX GET - check if a .dedyn.io hostname is still available (before registration)."""
    hostname = request.GET.get('hostname', '').strip().lower()
    if not hostname:
        return JsonResponse({'ok': False, 'error': 'No hostname provided'})

    if hostname.endswith('.dedyn.io'):
        hostname = hostname[:-len('.dedyn.io')]

    try:
        # deSEC offers a public availability check on the dedyn.io page.
        # Use DNS resolution first (fast, no API key needed): a resolved
        # hostname is almost certainly taken.
        try:
            import socket
            socket.getaddrinfo(hostname + '.dedyn.io', None, socket.AF_UNSPEC)
            return JsonResponse({'available': False, 'hostname': hostname})
        except socket.gaierror:
            pass

        # Fallback: probe deSEC API without auth - a 404 means free, 200/409 means taken.
        req = urllib.request.Request(
            f'https://desec.io/api/v1/domains/{hostname}.dedyn.io/')
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return JsonResponse({'available': resp.status == 200 and False,
                                     'hostname': hostname})
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return JsonResponse({'available': True, 'hostname': hostname})
            return JsonResponse({'available': None, 'hostname': hostname,
                                 'note': f'Probe returned HTTP {e.code}'})
    except Exception as e:
        return JsonResponse({'available': None, 'hostname': hostname,
                             'error': str(e)})


@login_required
def settings_dns_host_status(request):
    hostname = request.GET.get('hostname', '')
    api_key = request.GET.get('api_key', '')
    current_ipv4 = request.GET.get('current_ipv4', '')
    current_ipv6 = request.GET.get('current_ipv6', '')
    ipv6_mode = request.GET.get('ipv6_mode', '')

    # Append .dedyn.io suffix if not present
    if hostname and not hostname.endswith('.dedyn.io'):
        hostname = hostname + '.dedyn.io'

    result = {
        'hostname': hostname,
        'domain_exists': False,
        'domain_exists_check': None,
        'dns_ipv4': [],
        'dns_ipv6': [],
        'ipv4_match': False,
        'ipv6_match': False,
        'ipv4_check_skipped': False,
        'error': None,
    }

    if not hostname:
        result['error'] = 'No hostname provided'
        return JsonResponse(result)

    # Check domain existence via desec API
    if api_key:
        try:
            req = urllib.request.Request(
                f'https://desec.io/api/v1/domains/{hostname}/',
                headers={'Authorization': f'Token {api_key}'}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result['domain_exists'] = resp.status == 200
                result['domain_exists_check'] = 'exists' if resp.status == 200 else 'error'
        except urllib.error.HTTPError as e:
            if e.code == 404:
                result['domain_exists'] = False
                result['domain_exists_check'] = 'not_found'
            elif e.code == 401:
                result['domain_exists_check'] = 'invalid_api_key'
            else:
                result['domain_exists_check'] = f'http_{e.code}'
        except Exception as e:
            result['domain_exists_check'] = str(e)
    else:
        result['domain_exists_check'] = 'no_api_key'

    # Mark whether IPv4 check should be skipped
    if ipv6_mode == 'only':
        result['ipv4_check_skipped'] = True

    # Fetch DNS records from authoritative deSEC API
    if api_key:
        try:
            req = urllib.request.Request(
                f'https://desec.io/api/v1/domains/{hostname}/rrsets/',
                headers={'Authorization': f'Token {api_key}'}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                rrsets = json.loads(resp.read().decode())
                for rr in rrsets:
                    if result['ipv4_check_skipped'] and rr['type'] == 'A':
                        continue
                    if rr['type'] == 'A':
                        for rec in rr['records']:
                            if rec not in result['dns_ipv4']:
                                result['dns_ipv4'].append(rec)
                    elif rr['type'] == 'AAAA':
                        for rec in rr['records']:
                            if rec not in result['dns_ipv6']:
                                result['dns_ipv6'].append(rec)
        except Exception:
            pass
    else:
        # Fallback: local DNS resolution when no API key is available
        try:
            import socket
            addrs = socket.getaddrinfo(hostname, None)
            for addr in addrs:
                ip = addr[4][0]
                if result['ipv4_check_skipped'] and ':' not in ip:
                    continue
                if ':' in ip:
                    if ip not in result['dns_ipv6']:
                        result['dns_ipv6'].append(ip)
                else:
                    if ip not in result['dns_ipv4']:
                        result['dns_ipv4'].append(ip)
        except Exception:
            pass

    # Compare with current IPs
    if not result.get('ipv4_check_skipped'):
        if current_ipv4 and current_ipv4 in result['dns_ipv4']:
            result['ipv4_match'] = True
        elif not current_ipv4 and not result['dns_ipv4']:
            result['ipv4_match'] = True
    else:
        result['ipv4_match'] = True
    if current_ipv6 and ':' not in current_ipv6:
        current_ipv6 = ''
    if current_ipv6 and current_ipv6 in result['dns_ipv6']:
        result['ipv6_match'] = True
    elif not current_ipv6 and not result['dns_ipv6']:
        result['ipv6_match'] = True
    elif not current_ipv6:
        result['ipv6_match'] = True
        result['ipv6_skip'] = True

    return JsonResponse(result)

@login_required
def settings_dns_test_api(request):
    if request.method != 'POST':
        return JsonResponse({'valid': False, 'error': 'POST required'})

    api_key = request.POST.get('api_key', '')
    hostname = request.POST.get('hostname', '')
    if not api_key:
        return JsonResponse({'valid': False, 'error': 'API key is required'})

    try:
        # Test token against desec.io - list domains
        req = urllib.request.Request(
            'https://desec.io/api/v1/domains/',
            headers={'Authorization': f'Token {api_key}'}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                domains = json.loads(resp.read().decode())
                # If hostname given, check if domain already exists
                domain_exists = False
                if hostname and hostname.endswith('.dedyn.io'):
                    domain_check = hostname.lower()
                    for d in domains:
                        if d.get('name', '').lower() == domain_check:
                            domain_exists = True
                            break

                msg = 'API key is valid'
                if domain_exists:
                    msg += f', domain {hostname} already exists'
                elif hostname:
                    msg += f', domain {hostname} can be created'

                return JsonResponse({
                    'valid': True,
                    'message': msg,
                    'domain_exists': domain_exists,
                    'domain_count': len(domains),
                })
            else:
                return JsonResponse({
                    'valid': False,
                    'error': f'Unexpected response: HTTP {resp.status}'
                })
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return JsonResponse({'valid': False, 'error': 'Invalid API key (HTTP 401)'})
        elif e.code == 403:
            return JsonResponse({'valid': False, 'error': 'Access denied (HTTP 403)'})
        else:
            return JsonResponse({'valid': False, 'error': f'API error: HTTP {e.code}'})
    except urllib.error.URLError as e:
        return JsonResponse({'valid': False, 'error': f'Connection error: {e.reason}'})
    except Exception as e:
        return JsonResponse({'valid': False, 'error': str(e)})


@login_required
def settings_dns_check_ip(request):
    result = {'ipv4': '', 'ipv6': '', 'ipv4_available': False, 'ipv6_available': False}

    try:
        req = urllib.request.Request('https://checkipv4.dedyn.io/')
        with urllib.request.urlopen(req, timeout=10) as resp:
            ipv4 = resp.read().decode().strip()
            # Basic validation
            parts = ipv4.split('.')
            if len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
                result['ipv4'] = ipv4
                result['ipv4_available'] = True
    except Exception:
        pass

    try:
        req = urllib.request.Request('https://checkipv6.dedyn.io/')
        with urllib.request.urlopen(req, timeout=10) as resp:
            ipv6 = resp.read().decode().strip()
            # Validate: must be a real IPv6 address
            if ':' in ipv6 and '<' not in ipv6 and '>' not in ipv6 and ' ' not in ipv6:
                result['ipv6'] = ipv6
                result['ipv6_available'] = True
    except Exception:
        pass

    return JsonResponse(result)

DESEC_API = 'https://desec.io/api/v1'


def _desec_request(method, path, data=None, token=None, timeout=15):
    url = f'{DESEC_API}/{path.lstrip("/")}'
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Token {token}'
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_body = resp.read().decode()
            return {'status': resp.status, 'body': json.loads(resp_body) if resp_body else {}}
    except urllib.error.HTTPError as e:
        resp_body = e.read().decode()
        try:
            err_data = json.loads(resp_body)
        except Exception:
            err_data = {'detail': resp_body}
        return {'status': e.code, 'body': err_data}
    except urllib.error.URLError as e:
        return {'status': 0, 'body': {'detail': f'Connection error: {e.reason}'}}


@login_required
def settings_dns_register(request):
    """AJAX POST - Register a new deSEC account."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    email = request.POST.get('email', '').strip()
    password = request.POST.get('password', '')
    captcha_id = request.POST.get('captcha_id', '').strip()
    captcha_solution = request.POST.get('captcha_solution', '').strip()

    if not email or not password:
        return JsonResponse({'ok': False, 'error': 'Email and password are required'})

    data = {'email': email, 'password': password}
    if captcha_id and captcha_solution:
        data['captcha'] = {'id': captcha_id, 'solution': captcha_solution}

    result = _desec_request('POST', '/auth/', data=data, timeout=20)
    if result['status'] == 202:
        return JsonResponse({'ok': True, 'message': 'Registration initiated. Check your email for the verification link.'})
    else:
        err = result['body']
        if isinstance(err, dict):
            msgs = []
            for k, v in err.items():
                if isinstance(v, list):
                    msgs.append(f'{k}: {", ".join(str(x) for x in v)}')
                else:
                    msgs.append(f'{k}: {v}')
            detail = '; '.join(msgs)
        else:
            detail = str(err)
        return JsonResponse({'ok': False, 'error': detail})


@login_required
def settings_dns_finalize(request):
    """AJAX POST - Login, create API token, optionally create domain, save to inventory."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    email = request.POST.get('email', '').strip()
    password = request.POST.get('password', '')
    domain = request.POST.get('domain', '').strip().lower()
    if domain.endswith('.dedyn.io'):
        domain = domain[:-len('.dedyn.io')]
    if domain:
        domain = domain + '.dedyn.io'

    if not email or not password:
        return JsonResponse({'ok': False, 'error': 'Email and password are required'})

    # Step 1: Login
    login_result = _desec_request('POST', '/auth/login/',
                                  data={'email': email, 'password': password}, timeout=15)
    if login_result['status'] != 200:
        if login_result['status'] == 403:
            return JsonResponse({'ok': False, 'error': 'Account not yet verified. Please check your email and click the verification link, then try again.',
                                 'not_verified': True})
        return JsonResponse({'ok': False, 'error': f'Login failed (HTTP {login_result["status"]})'})

    login_token = login_result['body'].get('token', '')
    if not login_token:
        return JsonResponse({'ok': False, 'error': 'No token in login response'})

    # Step 2: Create permanent API token
    token_data = {
        'name': 'symbios-ddns',
        'perm_create_domain': True,
        'perm_delete_domain': True,
        'perm_manage_tokens': False,
        'max_unused_period': '36500 00:00:00',
    }
    token_result = _desec_request('POST', '/auth/tokens/', data=token_data, token=login_token, timeout=15)
    if token_result['status'] != 201:
        return JsonResponse({'ok': False, 'error': f'Failed to create API token: {token_result["body"]}'})

    api_token = token_result['body'].get('token', '')
    if not api_token:
        return JsonResponse({'ok': False, 'error': 'No token in create-token response'})

    # Step 3: Create domain if requested
    domain_created = False
    if domain:
        domain_result = _desec_request('POST', '/domains/', data={'name': domain}, token=api_token, timeout=15)
        if domain_result['status'] == 201:
            domain_created = True
        elif domain_result['status'] == 409:
            # Domain already exists - that's fine
            domain_created = True
        # If domain creation fails for other reasons, continue anyway (user can create manually)

    # Step 4: Save to inventory via the settings CLI (secret via stdin,
    # domain normalization in the script). The API login/token flow above
    # stays Python (external HTTPS, no host access needed). Without a
    # domain in this request the previously stored host is kept (same as
    # before: only a given domain overwrote ddns_host/base_domain).
    if not domain:
        current = _get_inventory_config()
        domain = current.get('all', {}).get('vars', {}).get('ddns_host', '')
    payload = json.dumps({
        'ddns_host': domain,
        'ddns_apikey': api_token,
        'ddns_ipv6': request.POST.get('ipv6_mode', ''),
    })
    ok, stdout, stderr = run_command(
        'symbios-settings-dns.sh set --mode desec --json-stdin',
        timeout=30, stdin_data=payload)
    if not ok:
        return JsonResponse({'ok': False,
                             'error': f'Account created but saving failed: {stderr or stdout}'},
                            status=500)

    return JsonResponse({
        'ok': True,
        'message': 'deSEC account configured successfully!',
        'api_token': api_token,
        'password': password,
        'domain': domain,
        'domain_created': domain_created,
    })


@login_required
def settings_dns_captcha(request):
    """AJAX GET - Fetch a captcha from deSEC (for registration)."""
    result = _desec_request('POST', '/captcha/', timeout=15)
    if result['status'] == 201:
        captcha_id = result['body'].get('id', '')
        challenge_b64 = result['body'].get('challenge', '')
        return JsonResponse({
            'ok': True,
            'captcha_id': captcha_id,
            'challenge': challenge_b64,
            'image_data_uri': f'data:image/png;base64,{challenge_b64}',
        })
    else:
        return JsonResponse({'ok': False, 'error': f'Failed to get captcha: {result["body"]}'})

