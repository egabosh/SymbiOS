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

from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config, _save_inventory_config, _safe_write
from .constants import CONFIG_PATH
from .utils.ssh_exec import run_playbook, run_command
from .utils.http import is_ajax_request
from .setup_status import get_page_badge, PAGE_EXPLAIN

import urllib.request
import urllib.error
import json
import yaml
import os
import re
import shlex


def _start_reapply(playbooks=None):
    """Start symbios-reapply.sh as a tracked job and return the job id.

    The job streams live output to the browser via /exec/output/.
    Returns a (job_id, title, cmd) tuple.
    """
    from .utils.jobs import create_job
    if playbooks:
        args = ' '.join(playbooks)
        flag = f'--only {args}'
        title = 'Reapplying: ' + ', '.join(playbooks)
    else:
        flag = ''
        title = 'Reapplying all playbooks...'
    cmd = f'symbios-reapply.sh {flag}'
    job_id = create_job(cmd, timeout=3600)
    return job_id, title, cmd


@login_required
def settings_ddns(request):
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
        try:
            if action == 'remove':
                config['all']['vars']['ddns_apikey'] = ''
                config['all']['vars']['ddns_host'] = ''
                config['all']['vars']['ddns_ipv6'] = ''
                config['all']['vars']['dns_mode'] = ''
                # Reset domains to the local fallback (shared base_domain so the
                # Authelia session cookie can span all service subdomains)
                config['all']['vars']['base_domain'] = 'symbios.local'
                _save_inventory_config(config)
                if is_ajax:
                    from .utils.jobs import create_job
                    cmd = 'symbios-reapply.sh'
                    job_id = create_job(cmd, timeout=3600)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Removing DNS config and reapplying...',
                                         'message': 'DNS configuration removed.',
                                         'command': cmd})
                messages.success(request, 'DNS configuration removed.')
                messages.info(request, 'Reapplying all playbooks in the background...')
                _start_reapply()
            elif dns_mode == 'self-managed':
                self_domain = request.POST.get('self_domain', '').strip().lower().rstrip('.')
                if not self_domain:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'Please enter a domain.'}, status=400)
                    messages.error(request, 'Please enter a domain.')
                    return redirect('settings_ddns')
                config['all']['vars']['dns_mode'] = 'self-managed'
                config['all']['vars']['ddns_apikey'] = ''
                config['all']['vars']['ddns_host'] = ''
                config['all']['vars']['ddns_ipv6'] = ''
                config['all']['vars']['base_domain'] = self_domain
                _save_inventory_config(config)
                if is_ajax:
                    job_id, title, cmd = _start_reapply()
                    return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                         'message': f'DNS settings saved for {self_domain}.',
                                         'command': cmd})
                messages.success(request, f'DNS settings saved for {self_domain}.')
                messages.info(request, 'Reapplying all playbooks in the background...')
                _start_reapply()
            else:
                # deSEC mode (existing behavior)
                ddns_host = request.POST.get('ddns_host', '')
                ddns_host = ddns_host.lower().strip()
                if ddns_host.endswith('.dedyn.io'):
                    ddns_host = ddns_host[:-len('.dedyn.io')]
                ddns_host = ddns_host + '.dedyn.io'

                config['all']['vars']['dns_mode'] = 'desec'
                config['all']['vars']['ddns_apikey'] = request.POST.get('ddns_apikey', '')
                config['all']['vars']['ddns_host'] = ddns_host
                config['all']['vars']['ddns_ipv6'] = request.POST.get('ddns_ipv6', '')
                # The DDNS host becomes the shared parent domain (base_domain) so
                # the Authelia session cookie can span all service subdomains.
                config['all']['vars']['base_domain'] = ddns_host
                _save_inventory_config(config)
                if is_ajax:
                    from .utils.jobs import create_job
                    # Chain: run dedyn playbook, then full reapply
                    cmd = 'symbios-run-playbook.sh base-services/dedyn.yml && symbios-reapply.sh'
                    job_id = create_job(cmd, timeout=3600)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Configuring DNS and reapplying...',
                                         'message': 'DNS settings saved.',
                                         'command': cmd})
                messages.success(request, 'DNS settings saved.')
                try:
                    ok, out = run_playbook('base-services/dedyn.yml', timeout=120)
                    if ok:
                        messages.success(request, 'DDNS playbook completed successfully.')
                    else:
                        messages.warning(request, 'DDNS playbook completed with issues.')
                except Exception as e:
                    messages.warning(request, 'Could not run DDNS playbook: ' + str(e))
                # Reapply all playbooks with updated domain in the background
                messages.info(request, 'Reapplying all playbooks in the background...')
                _start_reapply()
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_ddns')

    badge = get_page_badge('ddns', vars_)
    return render(request, 'main/settings_ddns.html', {
        'vars': vars_,
        'dns_mode': current_dns_mode,
        'self_domain': vars_.get('base_domain', '') if current_dns_mode == 'self-managed' else '',
        'page_key': 'ddns',
        'page_icon': 'bi-globe',
        'page_title': 'DNS',
        'page_explain': PAGE_EXPLAIN['ddns'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_ddns_check_domain(request):
    """AJAX GET — check if a .dedyn.io hostname is still available (before registration)."""
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
def settings_ddns_host_status(request):
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
def settings_ddns_test_api(request):
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
def settings_ddns_check_ip(request):
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
def settings_ddns_register(request):
    """AJAX POST — Register a new deSEC account."""
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
def settings_ddns_finalize(request):
    """AJAX POST — Login, create API token, optionally create domain, save to inventory."""
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
            # Domain already exists — that's fine
            domain_created = True
        # If domain creation fails for other reasons, continue anyway (user can create manually)

    # Step 4: Save to inventory
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']
    vars_['dns_mode'] = 'desec'
    vars_['ddns_apikey'] = api_token
    if domain:
        vars_['ddns_host'] = domain
        vars_['base_domain'] = domain
    vars_['ddns_ipv6'] = request.POST.get('ipv6_mode', '')
    _save_inventory_config(config)

    return JsonResponse({
        'ok': True,
        'message': 'deSEC account configured successfully!',
        'api_token': api_token,
        'password': password,
        'domain': domain,
        'domain_created': domain_created,
    })


@login_required
def settings_ddns_captcha(request):
    """AJAX GET — Fetch a captcha from deSEC (for registration)."""
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


@login_required
def settings_localization(request):
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    # Get available options from host via symbios-exec.sh
    try:
        # Get timezone list from host using timedatectl
        timezones_cmd = 'timedatectl list-timezones'
        ok, stdout, stderr = run_command(timezones_cmd, timeout=10)
        if ok:
            timezones = [line.strip() for line in stdout.split('\n') if line.strip()]
            valid_timezones = [tz.replace('_', ' ') for tz in timezones]
            valid_timezones_display = sorted(valid_timezones)
        else:
            # Fallback to static list
            valid_timezones_display = sorted([
                'Africa/Abidjan', 'Africa/Cairo', 'Africa/Johannesburg', 'Africa/Lagos', 'Africa/Nairobi',
                'America/Anchorage', 'America/Argentina/Buenos_Aires', 'America/Bogota', 'America/Caracas',
                'America/Chicago', 'America/Denver', 'America/Halifax', 'America/Lima', 'America/Los_Angeles',
                'America/Mexico_City', 'America/New_York', 'America/Phoenix', 'America/Sao_Paulo',
                'America/Toronto', 'America/Vancouver',
                'Asia/Bangkok', 'Asia/Colombo', 'Asia/Dubai', 'Asia/Hong_Kong', 'Asia/Karachi',
                'Asia/Kolkata', 'Asia/Kuala_Lumpur', 'Asia/Manila', 'Asia/Seoul', 'Asia/Shanghai',
                'Asia/Singapore', 'Asia/Taipei', 'Asia/Tehran', 'Asia/Tokyo',
                'Atlantic/Reykjavik', 'Australia/Melbourne', 'Australia/Perth', 'Australia/Sydney',
                'Europe/Amsterdam', 'Europe/Berlin', 'Europe/Brussels', 'Europe/Bucharest',
                'Europe/Copenhagen', 'Europe/Dublin', 'Europe/Helsinki', 'Europe/Istanbul',
                'Europe/Lisbon', 'Europe/London', 'Europe/Madrid', 'Europe/Moscow', 'Europe/Oslo',
                'Europe/Paris', 'Europe/Prague', 'Europe/Rome', 'Europe/Stockholm', 'Europe/Vienna',
                'Europe/Warsaw', 'Europe/Zurich',
                'Pacific/Auckland', 'Pacific/Fiji', 'Pacific/Honolulu', 'Pacific/Samoa',
                'UTC',
            ])
    except Exception:
        # Fallback to static list
        valid_timezones_display = sorted([
            'UTC',
            'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
            'Europe/London', 'Europe/Berlin', 'Europe/Paris', 'Europe/Moscow',
            'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Kolkata', 'Asia/Dubai',
            'Australia/Sydney', 'Pacific/Auckland', 'Pacific/Honolulu',
        ])

    # Get keyboard layouts dynamically from host via shell script.
    keyboards = []
    try:
        ok, stdout, _ = run_command('symbios-list-keyboards.sh', timeout=10)
        if ok and stdout:
            keyboards = [line.strip() for line in stdout.split('\n') if line.strip()]
    except Exception:
        pass

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            vars_['timezone'] = request.POST.get('timezone', '').strip()
            vars_['keyboard'] = request.POST.get('keyboard', '').strip()
            vars_['locale'] = request.POST.get('locale', '').strip()
            _save_inventory_config(config)
            if is_ajax:
                job_id, title, cmd = _start_reapply(
                    playbooks=['base-services/localization.yml', 'base-services/raspberry.yml'])
                return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                     'message': 'Localization settings saved.',
                                     'command': cmd})
            messages.success(request, 'Localization settings saved.')
            messages.info(request, 'Reapplying localization playbooks in the background...')
            _start_reapply(playbooks=['base-services/localization.yml', 'base-services/raspberry.yml'])
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_localization')

    return render(request, 'main/settings_localization.html', {
        'vars': vars_,
        'all_timezones': valid_timezones_display,
        'all_keyboards': keyboards,
        'page_key': 'localization',
        'page_icon': 'bi-clock-history',
        'page_title': 'Sprache & Zeitzone',
        'page_explain': PAGE_EXPLAIN['localization'],
        'page_status': get_page_badge('localization', vars_)[0],
        'page_status_label': get_page_badge('localization', vars_)[1],
        'page_status_text': get_page_badge('localization', vars_)[2],
    })


@login_required
def settings_auth(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            twofa_wanted = request.POST.get('twofa_enabled', 'false') == 'true'
            if twofa_wanted:
                smtp_server = vars_.get('smtp_server', '')
                smtp_from = vars_.get('smtp_from', '')
                if not smtp_server or not smtp_from:
                    if is_ajax:
                        return JsonResponse({'ok': False,
                                             'error': 'Cannot enable 2FA: No SMTP server configured.'}, status=400)
                    messages.error(request, 'Cannot enable 2FA: No SMTP server configured. Configure a mailserver first under Settings \u2192 Mailserver (SMTP).')
                    return redirect('settings_auth')
            config['all']['vars']['twofa_enabled'] = twofa_wanted
            _save_inventory_config(config)
            if is_ajax:
                from .utils.jobs import create_job
                cmd = 'symbios-run-playbook.sh base-services/authelia.yml'
                job_id = create_job(cmd, timeout=3600)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Applying auth settings...',
                                     'message': 'Auth settings saved.',
                                     'command': cmd})
            messages.success(request, 'Auth settings saved.')
            try:
                ok, out = run_playbook('base-services/authelia.yml', timeout=180)
                if ok:
                    messages.success(request, 'Authelia playbook completed successfully.')
                else:
                    messages.warning(request, 'Authelia playbook completed with issues.')
            except Exception as e:
                messages.warning(request, 'Could not run Authelia playbook: ' + str(e))
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_auth')

    badge = get_page_badge('auth', vars_)
    return render(request, 'main/settings_auth.html', {
        'vars': vars_,
        'page_key': 'auth',
        'page_icon': 'bi-shield-lock',
        'page_title': 'Anmeldung & 2FA',
        'page_explain': PAGE_EXPLAIN['auth'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_acme(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        action = request.POST.get('action', 'save')
        try:
            if action == 'remove':
                config['all']['vars']['acme_server'] = ''
                _save_inventory_config(config)
            else:
                acme_server = request.POST.get('acme_server', '').strip()
                config['all']['vars']['acme_server'] = acme_server
                _save_inventory_config(config)
            if is_ajax:
                from .utils.jobs import create_job
                cmd = 'symbios-run-playbook.sh base-services/traefik.yml'
                job_id = create_job(cmd, timeout=3600)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Applying ACME settings...',
                                     'message': 'ACME settings saved.',
                                     'command': cmd})
            messages.success(request, 'ACME settings saved.')
            try:
                ok, out = run_playbook('base-services/traefik.yml', timeout=180)
                if ok:
                    messages.success(request, 'Traefik playbook completed successfully.')
                else:
                    messages.warning(request, 'Traefik playbook completed with issues.')
            except Exception as e:
                messages.warning(request, 'Could not run Traefik playbook: ' + str(e))
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_acme')

    badge = get_page_badge('acme', vars_)
    return render(request, 'main/settings_acme.html', {
        'vars': vars_,
        'page_key': 'acme',
        'page_icon': 'bi-patch-check',
        'page_title': 'Sicherheits-Zertifikate (TLS)',
        'page_explain': PAGE_EXPLAIN['acme'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_local_ip(request):
    try:
        ok, stdout, _ = run_command('symbios-get-local-ip.sh', timeout=10)
        local_ipv4 = stdout.strip() if ok and stdout else ""
        return JsonResponse({"local_ipv4": local_ipv4})
    except Exception as e:
        return JsonResponse({"local_ipv4": "", "error": str(e)})


def _is_valid_ssh_pubkey(key):
    parts = key.strip().split(None, 2)
    if len(parts) < 2:
        return False
    valid_types = {"ssh-rsa", "ssh-ed25519", "ssh-dss",
                   "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"}
    if parts[0] not in valid_types:
        return False
    try:
        import base64
        base64.b64decode(parts[1])
        return True
    except Exception:
        return False


def _read_host_authorized_keys():
    # Fetch live host authorized_keys via symbios-exec.sh (not a volume mount).
    try:
        ok, stdout, _ = run_command('cat /root/.ssh/authorized_keys', timeout=10)
        if ok and stdout:
            return [line.strip() for line in stdout.splitlines()
                    if line.strip()]
    except Exception:
        pass
    return []


def _is_system_ssh_key(line):
    # The WebUI's own exec-gateway key (comment "symbios-webui") is deployed
    # automatically and must never be edited or deleted via the UI.
    return "symbios-webui" in line


@login_required
def settings_ssh_keys(request):
    # Fetch host authorized_keys via symbios-exec.sh.
    host_keys = _read_host_authorized_keys()
    system_keys = [k for k in host_keys if _is_system_ssh_key(k)]
    user_keys = [k for k in host_keys if not _is_system_ssh_key(k)]

    if request.method == "POST":
        action = request.POST.get("action", "save")
        is_ajax = is_ajax_request(request)
        try:
            if action == "add":
                new_key = request.POST.get("new_key", "").strip()
                if new_key:
                    if not _is_valid_ssh_pubkey(new_key):
                        raise ValueError("Invalid SSH public key format")
                    user_keys.append(new_key)
            elif action == "remove":
                remove_idx = request.POST.get("index", "")
                if remove_idx.isdigit():
                    idx = int(remove_idx)
                    if 0 <= idx < len(user_keys):
                        user_keys.pop(idx)
            elif action == "save":
                keys_text = request.POST.get("keys", "").strip()
                new_keys = [k.strip() for k in keys_text.split("\n") if k.strip()]
                invalid = [k for k in new_keys
                           if not k.startswith("#")
                           and not _is_valid_ssh_pubkey(k)]
                if invalid:
                    raise ValueError(f"{len(invalid)} invalid SSH key(s) found")
                user_keys = new_keys

            # Build the complete authorized_keys content: system keys first,
            # then user keys.  Write via symbios-write-authorized-keys.sh
            # (reads from stdin, no shell-quoting issues).
            all_keys = system_keys + user_keys
            keys_content = "\n".join(all_keys) + "\n"
            cmd = 'symbios-write-authorized-keys.sh'

            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=60, stdin_data=keys_content)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Saving SSH keys...',
                                     'message': 'SSH keys saved.',
                                     'command': cmd})

            ok, stdout, stderr = run_command(
                cmd, timeout=15, stdin_data=keys_content)
            if not ok:
                raise RuntimeError(f"Failed to write authorized_keys: {stderr}")

            messages.success(request, "SSH keys saved.")
        except Exception as e:
            messages.error(request, f"Error: {e}")
        return redirect("settings_ssh_keys")

    # Enrich user keys with parsed type+comment
    key_info = []
    for k in user_keys:
        parts = k.split(None, 2)
        key_info.append({
            "line": k,
            "type": parts[0] if len(parts) > 0 else "",
            "data": parts[1] if len(parts) > 1 else "",
            "comment": parts[2] if len(parts) > 2 else "",
        })
    system_info = []
    for k in system_keys:
        parts = k.split(None, 2)
        system_info.append({
            "line": k,
            "type": parts[0] if len(parts) > 0 else "",
            "data": parts[1] if len(parts) > 1 else "",
            "comment": parts[2] if len(parts) > 2 else "",
        })
    return render(request, "main/settings_ssh_keys.html", {
        "keys": user_keys,
        "key_info": key_info,
        "system_keys": system_info,
    })


@login_required
def settings_config(request):
    raw_yaml = ''
    try:
        with open(CONFIG_PATH, 'r') as f:
            raw_yaml = f.read()
    except FileNotFoundError:
        raw_yaml = '# inventory.yml not found\n'
    except Exception as e:
        raw_yaml = f'# Error reading config: {e}\n'

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        content = request.POST.get('config_content', '')
        # Validate YAML before saving
        try:
            parsed = yaml.safe_load(content)
            if not isinstance(parsed, dict):
                if is_ajax:
                    return JsonResponse({'ok': False,
                                         'error': 'Config must be a YAML mapping (dictionary).'}, status=400)
                messages.error(request, 'Config must be a YAML mapping (dictionary).')
                return redirect('settings_config')
        except yaml.YAMLError as e:
            if is_ajax:
                return JsonResponse({'ok': False,
                                     'error': f'YAML syntax error: {e}'}, status=400)
            messages.error(request, f'YAML syntax error: {e}')
            return redirect('settings_config')
        try:
            # Backup + atomic write
            if os.path.exists(CONFIG_PATH):
                with open(CONFIG_PATH) as f:
                    bak = CONFIG_PATH + '.bak'
                    with open(bak, 'w') as b:
                        b.write(f.read())
            _safe_write(CONFIG_PATH, content)
            if is_ajax:
                job_id, title, cmd = _start_reapply()
                return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                     'message': 'Config saved.',
                                     'command': cmd})
            messages.success(request, 'Config saved.')
            messages.info(request, 'Reapplying all playbooks in the background...')
            _start_reapply()
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False,
                                     'error': f'Error saving config: {e}'}, status=500)
            messages.error(request, f'Error saving config: {e}')
        return redirect('settings_config')

    return render(request, 'main/settings_config.html', {
        'config_content': raw_yaml,
    })


@login_required
def settings_backup(request):
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            vars_['backup_server_host'] = request.POST.get('backup_server_host', '').strip()
            vars_['backup_server_port'] = request.POST.get('backup_server_port', '').strip() or '22'
            vars_['backup_server_user'] = request.POST.get('backup_server_user', '').strip() or 'root'
            vars_['backup_server_path'] = request.POST.get('backup_server_path', '').strip()
            _save_inventory_config(config)
            if is_ajax:
                job_id, title, cmd = _start_reapply(playbooks=['base-services/backup.yml'])
                return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                     'message': 'Backup settings saved.',
                                     'command': cmd})
            messages.success(request, 'Backup settings saved.')
            messages.info(request, 'Reapplying backup playbook in the background...')
            _start_reapply(playbooks=['base-services/backup.yml'])
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_backup')

    return render(request, 'main/settings_backup.html', {
        'vars': vars_,
    })


@login_required
def settings_backup_test(request):
    """AJAX POST — test SSH/SCP connectivity to the backup server."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    host = request.POST.get('host', '').strip()
    port = request.POST.get('port', '').strip() or '22'
    user = request.POST.get('user', '').strip() or 'root'
    path = request.POST.get('path', '').strip()

    if not host:
        return JsonResponse({'ok': False, 'error': 'Host is required'})

    try:
        port_int = int(port)
        if port_int < 1 or port_int > 65535:
            return JsonResponse({'ok': False, 'error': 'Invalid port number'})
    except ValueError:
        return JsonResponse({'ok': False, 'error': 'Port must be a number'})

    # Delegate to symbios-test-ssh.sh via the exec gateway
    cmd = f'symbios-test-ssh.sh {shlex.quote(host)} {shlex.quote(port)} {shlex.quote(user)}'
    if path:
        cmd += f' {shlex.quote(path)}'
    try:
        ok, stdout, stderr = run_command(cmd, timeout=20)
        if ok and stdout:
            return JsonResponse(json.loads(stdout))
        else:
            return JsonResponse({'ok': False, 'error': stderr or 'SSH test failed'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


# ---------------------------------------------------------------------------
# Data Disk — move /symbios data root to a separate disk
# ---------------------------------------------------------------------------

_DATA_PART_SCRIPT = '/usr/local/sbin/symbios-data-partition.sh'


@login_required
def settings_disk(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    badge = get_page_badge('disk', vars_)
    return render(request, 'main/settings_disk.html', {
        'vars': vars_,
        'page_key': 'disk',
        'page_icon': 'bi-device-hdd',
        'page_title': 'Daten-Platte',
        'page_explain': PAGE_EXPLAIN['disk'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_disk_list(request):
    """AJAX GET — list block devices via shell script."""
    ok, stdout, stderr = run_command(
        f'{_DATA_PART_SCRIPT} list', timeout=10)
    if not ok:
        return JsonResponse({'ok': False, 'error': stderr or 'lsblk failed'})
    try:
        data = json.loads(stdout)
        devices = data.get('blockdevices', [])
        filtered = [_describe_block(dev) for dev in devices]
        return JsonResponse({'ok': True, 'devices': filtered})
    except json.JSONDecodeError as e:
        return JsonResponse({'ok': False, 'error': f'Failed to parse lsblk: {e}'})


def _describe_block(dev):
    """Build a flat description dict for a block device (recursive for children)."""
    item = {
        'name': dev.get('name', ''),
        'path': '/dev/' + dev.get('name', ''),
        'size': dev.get('size', ''),
        'type': dev.get('type', ''),
        'fstype': dev.get('fstype') or '',
        'mountpoint': dev.get('mountpoint') or '',
        'model': (dev.get('model') or '').strip(),
        'uuid': dev.get('uuid') or '',
        'label': (dev.get('label') or '').strip(),
        'tran': dev.get('tran') or '',
        'rm': dev.get('rm', False),
        'children': [],
    }
    for child in dev.get('children', []) or []:
        item['children'].append(_describe_block(child))
    return item


@login_required
def settings_disk_status(request):
    """AJAX GET — check /symbios mount status and LUKS status."""
    ok, stdout, stderr = run_command(
        f'{_DATA_PART_SCRIPT} status', timeout=15)
    if not ok:
        return JsonResponse({
            'ok': False, 'error': stderr or 'status check failed',
            'data_device': '', 'data_fstype': '', 'data_size': '',
            'data_used': '', 'data_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({
            'ok': False, 'error': f'Invalid JSON from script: {stdout[:500]}',
            'data_device': '', 'data_fstype': '', 'data_size': '',
            'data_used': '', 'data_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })


@login_required
def settings_disk_setup(request):
    """AJAX POST — format, optionally encrypt, and mount a disk as /symbios.
    Returns a job_id for the exec modal (streams live output)."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    device = request.POST.get('device', '').strip()
    encrypt = 'yes' if request.POST.get('encrypt', 'no') == 'yes' else 'no'
    password = request.POST.get('password', '').strip()

    if not device:
        return JsonResponse({'ok': False, 'error': 'No device selected'})
    if not device.startswith('/dev/'):
        return JsonResponse({'ok': False, 'error': 'Invalid device path'})
    if encrypt == 'yes' and not password:
        return JsonResponse({'ok': False, 'error': 'Password required for LUKS encryption'})

    cmd_parts = [f'{_DATA_PART_SCRIPT} setup', device, encrypt]
    if encrypt == 'yes':
        cmd_parts.append(password)
    cmd = ' '.join(cmd_parts)

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=600)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Migrating /symbios to new disk...',
                             'message': f'Setting up {device} as /symbios.',
                             'command': cmd})

    # Fallback: synchronous execution
    ok, stdout, stderr = run_command(cmd, timeout=600)
    output = stdout
    if stderr:
        output = output + '\n' + stderr

    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'Disk setup complete.'})
        return JsonResponse({'ok': False, 'error': f'Setup failed:\n{output[-2000:]}'})


@login_required
def settings_disk_rollback(request):
    """AJAX POST — rollback last /symbios migration via exec modal."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    cmd = f'{_DATA_PART_SCRIPT} rollback'

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=300)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Rolling back /symbios migration...',
                             'message': 'Restoring original /symbios location.',
                             'command': cmd})

    ok, stdout, stderr = run_command(cmd, timeout=300)
    output = stdout
    if stderr:
        output = output + '\n' + stderr
    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'Rollback complete.'})
        return JsonResponse({'ok': False, 'error': f'Rollback failed:\n{output[-2000:]}'})


@login_required
def settings_disk_umount(request):
    """AJAX POST — unmount and close a LUKS /symbios volume."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    cmd = f'{_DATA_PART_SCRIPT} umount'
    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=300)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Unmounting /symbios...',
                             'message': '/symbios unmounted and LUKS volume closed.',
                             'command': cmd})

    ok, stdout, stderr = run_command(cmd, timeout=30)
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({'ok': True, 'message': '/symbios unmounted and LUKS volume closed.'})


@login_required
def settings_disk_change_password(request):
    """AJAX POST — change LUKS passphrase for an encrypted /symbios device."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    current_password = request.POST.get('current_password', '').strip()
    new_password = request.POST.get('new_password', '').strip()

    if not current_password:
        return JsonResponse({'ok': False, 'error': 'Current password is required'})
    if not new_password:
        return JsonResponse({'ok': False, 'error': 'New password is required'})
    if current_password == new_password:
        return JsonResponse({'ok': False, 'error': 'New password must differ from current password'})

    cmd_parts = [
        f'{_DATA_PART_SCRIPT} change-password',
        shlex.quote(current_password),
        shlex.quote(new_password),
    ]
    cmd = ' '.join(cmd_parts)

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=60)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Changing LUKS passphrase...',
                             'message': 'Updating encryption key.',
                             'command': f'{_DATA_PART_SCRIPT} change-password'})

    ok, stdout, stderr = run_command(cmd, timeout=60)
    output = stdout
    if stderr:
        output = output + '\n' + stderr
    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'LUKS passphrase changed.'})
        return JsonResponse({'ok': False, 'error': f'Password change failed:\n{output[-2000:]}'})


# ---------------------------------------------------------------------------
# Playbooks management
# ---------------------------------------------------------------------------

USER_PLAYBOOKS_DIR = "/config/user-playbooks"


def _ensure_user_playbooks_dir():
    os.makedirs(USER_PLAYBOOKS_DIR, exist_ok=True)


def _safe_playbook_name(name):
    """Sanitize a playbook filename: only allow [a-z0-9_-] and require .yml."""
    name = os.path.basename(name)
    name = re.sub(r'[^a-z0-9_\-\.]', '-', name.lower())
    if not name.endswith('.yml'):
        name = name.rsplit('.', 1)[0] + '.yml'
    return name


@login_required
def settings_playbooks(request):
    """Show list of user-uploaded playbooks with upload form."""
    from .playbook_catalog import parse_docs, get_catalog
    from .views_services import _sidebar_context, _order_catalog
    _ensure_user_playbooks_dir()
    files = sorted(f for f in os.listdir(USER_PLAYBOOKS_DIR)
                   if f.endswith('.yml') and f != 'inventory.yml')
    playbooks = []
    for fn in files:
        path = os.path.join(USER_PLAYBOOKS_DIR, fn)
        docs = parse_docs(path)
        playbooks.append({
            'filename': fn,
            'title': (docs or {}).get('short_description', fn[:-4]) if docs else fn[:-4],
            'has_docs': docs is not None,
        })
    playbooks_md = ''
    docs_path = os.path.join(os.path.dirname(__file__), 'docs', 'playbooks.md')
    try:
        with open(docs_path) as fh:
            playbooks_md = fh.read()
    except FileNotFoundError:
        pass
    all_catalog = get_catalog()
    return render(request, 'main/settings_playbooks.html', {
        'playbooks': playbooks,
        'playbooks_md': playbooks_md,
        'all_services': _order_catalog(all_catalog),
        **_sidebar_context(all_catalog),
    })


@login_required
def settings_playbooks_upload(request):
    """AJAX POST — upload one or more .yml playbook files."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})
    _ensure_user_playbooks_dir()
    uploaded = request.FILES.getlist('playbooks')
    if not uploaded:
        return JsonResponse({'ok': False, 'error': 'No files provided'})
    saved = []
    errors = []
    for f in uploaded:
        fn = _safe_playbook_name(f.name)
        if fn in ('inventory.yml', 'traefik-static.yml'):
            errors.append(f'{fn}: reserved filename')
            continue
        dest = os.path.join(USER_PLAYBOOKS_DIR, fn)
        try:
            with open(dest, 'wb') as out:
                for chunk in f.chunks():
                    out.write(chunk)
            saved.append(fn)
        except Exception as e:
            errors.append(f'{fn}: {e}')
    # Invalidate catalog cache so new playbooks appear immediately
    from .playbook_catalog import get_catalog
    get_catalog(force=True)
    return JsonResponse({'ok': True, 'saved': saved, 'errors': errors})


@login_required
def settings_playbooks_delete(request):
    """AJAX POST — delete a user-uploaded playbook."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})
    fn = _safe_playbook_name(request.POST.get('filename', ''))
    path = os.path.join(USER_PLAYBOOKS_DIR, fn)
    if not os.path.isfile(path):
        return JsonResponse({'ok': False, 'error': 'File not found'})
    os.remove(path)
    from .playbook_catalog import get_catalog
    get_catalog(force=True)
    return JsonResponse({'ok': True, 'message': f'Deleted {fn}'})

