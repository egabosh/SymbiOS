import os
import json
import urllib.request
import urllib.error
from pathlib import Path
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .forms import NetworkConfigForm
from .views import _get_inventory_config, _save_inventory_config, CONFIG_PATH
from .utils.log_utils import logs_stream


@login_required
def settings_network(request):
    if request.method == 'POST':
        form = NetworkConfigForm(request.POST)
        if form.is_valid():
            try:
                form.save()
                messages.success(request, 'Network configuration saved.')
            except Exception as e:
                messages.error(request, f'Error: {e}')
    else:
        form = NetworkConfigForm()
    return render(request, 'main/settings_network.html', {'form': form})


@login_required
def settings_inventory(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            vars_['default_domain'] = request.POST.get('default_domain', vars_.get('default_domain', 'local'))
            vars_['ddns_apikey'] = request.POST.get('ddns_apikey', vars_.get('ddns_apikey', ''))
            vars_['ddns_host'] = request.POST.get('ddns_host', vars_.get('ddns_host', ''))
            vars_['smtp_server'] = request.POST.get('smtp_server', vars_.get('smtp_server', ''))
            vars_['smtp_user'] = request.POST.get('smtp_user', vars_.get('smtp_user', ''))
            vars_['smtp_from'] = request.POST.get('smtp_from', vars_.get('smtp_from', ''))
            vars_['ldap_admin_password'] = request.POST.get('ldap_admin_password', vars_.get('ldap_admin_password', ''))
            _save_inventory_config(config)
            messages.success(request, 'Configuration saved.')
        except Exception as e:
            messages.error(request, f'Error saving configuration: {e}')
        return redirect('settings_inventory')

    return render(request, 'main/settings_inventory.html', {'config': config, 'vars': vars_})


@login_required
def settings_ddns(request):
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    if request.method == 'POST':
        action = request.POST.get('action', 'save')
        try:
            if action == 'remove':
                config['all']['vars']['ddns_apikey'] = ''
                config['all']['vars']['ddns_host'] = ''
                config['all']['vars']['ddns_ipv6'] = ''
                # Reset default_domain to local
                config['all']['vars']['default_domain'] = 'local'
                config['all']['vars']['symbios_domain'] = 'symbios.local'
                _save_inventory_config(config)
                messages.success(request, 'Dynamic DNS configuration removed.')
            else:
                ddns_host = request.POST.get('ddns_host', '')
                ddns_host = ddns_host.lower().strip()
                if ddns_host.endswith('.dedyn.io'):
                    ddns_host = ddns_host[:-len('.dedyn.io')]
                ddns_host = ddns_host + '.dedyn.io'

                config['all']['vars']['ddns_apikey'] = request.POST.get('ddns_apikey', '')
                config['all']['vars']['ddns_host'] = ddns_host
                config['all']['vars']['ddns_ipv6'] = request.POST.get('ddns_ipv6', '')
                # Set default_domain to the public DDNS host
                config['all']['vars']['default_domain'] = ddns_host
                config['all']['vars']['symbios_domain'] = 'symbios.' + ddns_host
                _save_inventory_config(config)
                messages.success(request, 'Dynamic DNS settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_ddns')

    # Check config daemon status
    daemon_running = False
    daemon_pending = False
    try:
        with open('/log/symbios-services.tsv') as f:
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) >= 2 and parts[0] == 'symbios-configd':
                    daemon_running = parts[1] == 'active'
                    break
    except Exception:
        pass

    # Check if inventory.yml was modified recently (pending changes)
    try:
        stat = os.stat(CONFIG_PATH)
        now = __import__('time').time()
        daemon_pending = (now - stat.st_mtime) < 15
    except Exception:
        pass

    return render(request, 'main/settings_ddns.html', {
        'vars': vars_,
        'daemon_running': daemon_running,
        'daemon_pending': daemon_pending,
    })


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
            # Basic IPv6 validation (has colons)
            if ':' in ipv6:
                result['ipv6'] = ipv6
                result['ipv6_available'] = True
    except Exception:
        pass

    return JsonResponse(result)

@login_required
def settings_auth(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            twofa_wanted = request.POST.get('twofa_enabled', 'false') == 'true'
            if twofa_wanted:
                smtp_server = vars_.get('smtp_server', '')
                smtp_from = vars_.get('smtp_from', '')
                if not smtp_server or not smtp_from:
                    messages.error(request, 'Cannot enable 2FA: No SMTP server configured. Configure a mailserver first under Settings \u2192 Mailserver (SMTP).')
                    return redirect('settings_auth')
            config['all']['vars']['twofa_enabled'] = twofa_wanted
            _save_inventory_config(config)
            messages.success(request, 'Auth settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_auth')

    return render(request, 'main/settings_auth.html', {'vars': vars_})
