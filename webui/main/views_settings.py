import os
import json
import urllib.request
import urllib.error
from pathlib import Path
TRIGGER_DIR = Path('/config/triggers')
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config, _save_inventory_config, CONFIG_PATH
from .utils.log_utils import logs_stream



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


import subprocess

_HOST_IP_FILE = "/config/.host-ip"

@login_required
def settings_local_ip(request):
    try:
        local_ipv4 = ""
        # Primary: read from file written by host cron
        try:
            with open(_HOST_IP_FILE) as f:
                ip = f.read().strip()
                if ip:
                    local_ipv4 = ip
        except Exception:
            pass

        if not local_ipv4:
            # Fallback: hostname -I inside container
            out = subprocess.check_output(["hostname", "-I"], timeout=5, text=True)
            ips = out.strip().split()
            for ip in ips:
                if ip.startswith(("192.168.", "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31.")):
                    local_ipv4 = ip
                    break

        return JsonResponse({"local_ipv4": local_ipv4})
    except Exception as e:
        return JsonResponse({"local_ipv4": "", "error": str(e)})


@login_required
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


def settings_ssh_keys(request):
    SSH_KEYS_FILE = "/config/ssh-authorized-keys"
    config = _get_inventory_config()
    if "all" not in config:
        config["all"] = {}
    if "vars" not in config["all"]:
        config["all"]["vars"] = {}
    vars_ = config["all"]["vars"]

    if "ssh_authorized_keys" not in vars_ or not isinstance(vars_["ssh_authorized_keys"], list):
        keys = []
        for src in ("/root-host-keys", SSH_KEYS_FILE):
            try:
                with open(src) as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            keys.append(line)
                if keys:
                    break
            except Exception:
                pass
        vars_["ssh_authorized_keys"] = keys
        _save_inventory_config(config)
    elif len(vars_["ssh_authorized_keys"]) == 0:
        keys = []
        try:
            with open("/root-host-keys") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        keys.append(line)
        except Exception:
            pass
        if keys:
            vars_["ssh_authorized_keys"] = keys
            _save_inventory_config(config)

    if request.method == "POST":
        action = request.POST.get("action", "save")
        try:
            if action == "add":
                new_key = request.POST.get("new_key", "").strip()
                if new_key:
                    if not _is_valid_ssh_pubkey(new_key):
                        raise ValueError("Invalid SSH public key format")
                    vars_["ssh_authorized_keys"].append(new_key)
            elif action == "remove":
                remove_idx = request.POST.get("index", "")
                if remove_idx.isdigit():
                    idx = int(remove_idx)
                    if 0 <= idx < len(vars_["ssh_authorized_keys"]):
                        vars_["ssh_authorized_keys"].pop(idx)
            elif action == "save":
                keys_text = request.POST.get("keys", "").strip()
                new_keys = [k.strip() for k in keys_text.split("\n") if k.strip() and not k.strip().startswith("#")]
                invalid = [k for k in new_keys if not _is_valid_ssh_pubkey(k)]
                if invalid:
                    raise ValueError(f"{len(invalid)} invalid SSH key(s) found")
                vars_["ssh_authorized_keys"] = new_keys

            _save_inventory_config(config)

            with open(SSH_KEYS_FILE, "w") as f:
                for k in vars_["ssh_authorized_keys"]:
                    f.write(k + "\n")

            messages.success(request, "SSH keys saved. Config daemon will deploy them.")
        except Exception as e:
            messages.error(request, f"Error: {e}")
        return redirect("settings_ssh_keys")

    # Enrich keys with parsed type+comment
    raw_keys = vars_.get("ssh_authorized_keys", [])
    key_info = []
    for k in raw_keys:
        parts = k.split(None, 2)
        ktype = parts[0] if len(parts) > 0 else ""
        kdata = parts[1] if len(parts) > 1 else ""
        kcomment = parts[2] if len(parts) > 2 else ""
        key_info.append({
            "line": k,
            "type": ktype,
            "data": kdata,
            "comment": kcomment,
        })
    return render(request, "main/settings_ssh_keys.html", {
        "keys": raw_keys,
        "key_info": key_info,
    })
