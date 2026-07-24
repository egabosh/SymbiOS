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
from django.views.decorators.csrf import csrf_exempt
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config, _save_inventory_config, _safe_write
from .constants import CONFIG_PATH
from .utils.ssh_exec import run_playbook, run_command

import urllib.request
import urllib.error
import json
import yaml
import os
import re
import subprocess

REAPPLY_STATUS_FILE = '/tmp/symbios-reapply.status'


def _start_reapply(domain_only=False):
    """Start symbios-reapply.sh in the background (non-blocking).

    The script writes its status to /tmp/symbios-reapply.status so the
    WebUI can poll progress without blocking the HTTP response.
    """
    flag = '--domain-only' if domain_only else ''
    cmd = f'nohup /usr/local/sbin/symbios-reapply.sh {flag} > /dev/null 2>&1 &'
    try:
        run_command(cmd, timeout=5)
    except Exception:
        pass  # non-critical


def _reapply_status():
    """Read the current reapply status from the status file."""
    try:
        with open(REAPPLY_STATUS_FILE, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        return 'idle'



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
                config['all']['vars']['default_domain'] = 'local'
                config['all']['vars']['base_domain'] = 'symbios.local'
                _save_inventory_config(config)
                messages.success(request, 'DNS configuration removed.')
                if dns_mode == 'desec':
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
                _start_reapply(domain_only=False)
            elif dns_mode == 'self-managed':
                self_domain = request.POST.get('self_domain', '').strip().lower().rstrip('.')
                if not self_domain:
                    messages.error(request, 'Please enter a domain.')
                    return redirect('settings_ddns')
                config['all']['vars']['dns_mode'] = 'self-managed'
                config['all']['vars']['ddns_apikey'] = ''
                config['all']['vars']['ddns_host'] = ''
                config['all']['vars']['ddns_ipv6'] = ''
                config['all']['vars']['default_domain'] = self_domain
                config['all']['vars']['base_domain'] = self_domain
                _save_inventory_config(config)
                messages.success(request, f'DNS settings saved for {self_domain}.')
                # Reapply all playbooks with updated domain in the background
                messages.info(request, 'Reapplying all playbooks in the background...')
                _start_reapply(domain_only=False)
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
                config['all']['vars']['default_domain'] = ddns_host
                config['all']['vars']['base_domain'] = ddns_host
                _save_inventory_config(config)
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
                _start_reapply(domain_only=False)
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_ddns')

    return render(request, 'main/settings_ddns.html', {
        'vars': vars_,
        'dns_mode': current_dns_mode,
        'self_domain': vars_.get('base_domain', '') if current_dns_mode == 'self-managed' else '',
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

    # Get keyboard layouts from host
    keyboards = []
    try:
        # Try to get keyboard layouts from host's /etc/default/keyboard or via kbdlist
        keyboards_cmd = 'ls /usr/share/keymaps/ || kbdlist'
        ok, stdout, stderr = run_command(keyboards_cmd, timeout=10)
        if ok and stdout:
            keyboards = []
            for line in stdout.split('\n'):
                line = line.strip()
                if not line or line == 'locale':
                    continue
                # Extract keyboard name from various formats
                kb = line.split('/')[-1].replace('.map.gz', '').replace('.map', '').replace('.kbd', '').replace('.kbd.gh', '')
                if kb and kb not in keyboards:
                    keyboards.append(kb)
        else:
            # Try to get keyboard layouts from keyboard-configuration.debconf output
            keyboard_cmd = 'debconf-show keyboard-configuration 2>/dev/null | grep -i layoutcode || echo "us"'
            ok, stdout, stderr = run_command(keyboard_cmd, timeout=10)
            if ok and stdout:
                keyboards = []
                for line in stdout.split('\n'):
                    line = line.strip()
                    if line and not line.startswith('#'):
                        kb = line.strip('"\'')
                        if kb and kb not in keyboards:
                            keyboards.append(kb)
    except Exception:
        # Fallback to static list
        keyboards = ['us', 'gb', 'de', 'fr', 'it', 'es', 'pt', 'nl', 'pl', 'ru', 'ar', 'zh', 'jp', 'kr', 'in']

    # Ensure keyboards is always defined
    if not keyboards:
        keyboards = ['us', 'gb', 'de', 'fr', 'it', 'es', 'pt', 'nl', 'pl', 'ru', 'ar', 'zh', 'jp', 'kr', 'in']

    if request.method == 'POST':
        try:
            vars_['timezone'] = request.POST.get('timezone', '').strip()
            vars_['keyboard'] = request.POST.get('keyboard', '').strip()
            vars_['locale'] = request.POST.get('locale', '').strip()
            _save_inventory_config(config)
            messages.success(request, 'Localization settings saved.')
            messages.info(request, 'Reapplying all playbooks in the background...')
            _start_reapply(domain_only=False)
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_localization')

    return render(request, 'main/settings_localization.html', {
        'vars': vars_,
        'all_timezones': valid_timezones_display,
        'all_keyboards': keyboards,
    })


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
            try:
                ok, out = run_playbook('base-services/authelia.yml', timeout=180)
                if ok:
                    messages.success(request, 'Authelia playbook completed successfully.')
                else:
                    messages.warning(request, 'Authelia playbook completed with issues.')
            except Exception as e:
                messages.warning(request, 'Could not run Authelia playbook: ' + str(e))
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_auth')

    return render(request, 'main/settings_auth.html', {'vars': vars_})

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


def _read_host_authorized_keys():
    # Live host authorized_keys is bind-mounted read-only into the container.
    try:
        with open("/root-host-keys") as f:
            return [line.strip() for line in f
                    if line.strip() and not line.startswith("#")]
    except Exception:
        pass
    return []


def _is_system_ssh_key(line):
    # The WebUI's own exec-gateway key (comment "symbios-webui") is deployed
    # automatically and must never be edited or deleted via the UI.
    return "symbios-webui" in line


def settings_ssh_keys(request):
    # Read keys directly from the host's /root/.ssh/authorized_keys
    # (bind-mounted read-only into the container as /root-host-keys).
    host_keys = _read_host_authorized_keys()
    system_keys = [k for k in host_keys if _is_system_ssh_key(k)]
    user_keys = [k for k in host_keys if not _is_system_ssh_key(k)]

    if request.method == "POST":
        action = request.POST.get("action", "save")
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
                new_keys = [k.strip() for k in keys_text.split("\n") if k.strip() and not k.strip().startswith("#")]
                invalid = [k for k in new_keys if not _is_valid_ssh_pubkey(k)]
                if invalid:
                    raise ValueError(f"{len(invalid)} invalid SSH key(s) found")
                user_keys = new_keys

            # Build the complete authorized_keys content: system keys first,
            # then user keys.  Write directly to /root/.ssh/authorized_keys
            # on the host via the SSH exec gateway — no inventory intermediary.
            all_keys = system_keys + user_keys
            keys_content = "\\n".join(all_keys) + "\\n"
            cmd = f"printf '%s\\n' '{keys_content}' > /root/.ssh/authorized_keys"
            ok, stdout, stderr = run_command(cmd, timeout=15)
            if ok != 0:
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
        content = request.POST.get('config_content', '')
        # Validate YAML before saving
        try:
            parsed = yaml.safe_load(content)
            if not isinstance(parsed, dict):
                messages.error(request, 'Config must be a YAML mapping (dictionary).')
                return redirect('settings_config')
        except yaml.YAMLError as e:
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
            messages.success(request, 'Config saved.')
        except Exception as e:
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
        try:
            vars_['backup_server_host'] = request.POST.get('backup_server_host', '').strip()
            vars_['backup_server_port'] = request.POST.get('backup_server_port', '').strip() or '22'
            vars_['backup_server_user'] = request.POST.get('backup_server_user', '').strip() or 'root'
            vars_['backup_server_path'] = request.POST.get('backup_server_path', '').strip()
            _save_inventory_config(config)
            messages.success(request, 'Backup settings saved.')
        except Exception as e:
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

    # Use the WebUI's own SSH key for the test
    key_path = '/config/.ssh/id_symbios'
    known_hosts = '/config/.ssh/known_hosts'

    cmd = [
        'ssh',
        '-i', key_path,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'ConnectTimeout=10',
        '-o', 'BatchMode=yes',
        '-p', port,
        f'{user}@{host}',
        'echo ok',
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            # Also test the path if provided
            if path:
                cmd_path = [
                    'ssh',
                    '-i', key_path,
                    '-o', 'StrictHostKeyChecking=no',
                    '-o', 'ConnectTimeout=10',
                    '-o', 'BatchMode=yes',
                    '-p', port,
                    f'{user}@{host}',
                    f'test -d {path} && echo path_ok || echo path_missing',
                ]
                result_path = subprocess.run(cmd_path, capture_output=True, text=True, timeout=15)
                if 'path_ok' in result_path.stdout:
                    return JsonResponse({'ok': True, 'message': f'Connection successful. Directory {path} exists.'})
                elif 'path_missing' in result_path.stdout:
                    return JsonResponse({'ok': False, 'error': f'Connection successful, but directory {path} does not exist on the remote host.'})
                else:
                    return JsonResponse({'ok': False, 'error': f'Connection successful, but could not verify path: {result_path.stderr.strip()}'})
            return JsonResponse({'ok': True, 'message': 'Connection successful.'})
        else:
            stderr = result.stderr.strip()
            if 'Permission denied' in stderr:
                return JsonResponse({'ok': False, 'error': 'Connection failed: Permission denied. Check that the SSH key is authorized on the remote host.'})
            elif 'Connection refused' in stderr:
                return JsonResponse({'ok': False, 'error': f'Connection refused on port {port}. Is SSH running?'})
            elif 'timed out' in stderr.lower() or 'timeout' in stderr.lower():
                return JsonResponse({'ok': False, 'error': f'Connection timed out. Is {host} reachable?'})
            elif 'No route to host' in stderr:
                return JsonResponse({'ok': False, 'error': f'No route to host {host}. Is the host reachable?'})
            else:
                return JsonResponse({'ok': False, 'error': f'Connection failed: {stderr}'})
    except subprocess.TimeoutExpired:
        return JsonResponse({'ok': False, 'error': 'Connection timed out (15s). Is the host reachable?'})
    except FileNotFoundError:
        return JsonResponse({'ok': False, 'error': 'SSH client not found on the server.'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


# ---------------------------------------------------------------------------
# Disk / Home partition management
# ---------------------------------------------------------------------------

_HOME_PART_SCRIPT = '/usr/local/sbin/symbios-home-partition.sh'


@login_required
def settings_disk(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    return render(request, 'main/settings_disk.html', {'vars': vars_})


@login_required
def settings_disk_list(request):
    """AJAX GET — list block devices via shell script."""
    ok, stdout, stderr = run_command(
        f'{_HOME_PART_SCRIPT} list', timeout=10)
    if not ok:
        return JsonResponse({'ok': False, 'error': stderr or 'lsblk failed'})
    try:
        data = json.loads(stdout)
        devices = data.get('blockdevices', [])
        filtered = []
        for dev in devices:
            if dev.get('name', '').startswith(('loop', 'ram', 'sr', 'zram')):
                continue
            filtered.append(_describe_block(dev))
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
        'tran': dev.get('tran') or '',
        'rm': dev.get('rm', False),
        'children': [],
    }
    for child in dev.get('children', []) or []:
        item['children'].append(_describe_block(child))
    return item


@login_required
def settings_disk_status(request):
    """AJAX GET — check /home mount status and LUKS status."""
    ok, stdout, stderr = run_command(
        f'{_HOME_PART_SCRIPT} status', timeout=15)
    if not ok:
        return JsonResponse({
            'ok': False, 'error': stderr or 'status check failed',
            'home_device': '', 'home_fstype': '', 'home_size': '',
            'home_used': '', 'home_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({
            'ok': False, 'error': f'Invalid JSON from script: {stdout[:500]}',
            'home_device': '', 'home_fstype': '', 'home_size': '',
            'home_used': '', 'home_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })


@login_required
def settings_disk_setup(request):
    """AJAX POST — format, optionally encrypt, and mount a disk as /home."""
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

    cmd_parts = [f'{_HOME_PART_SCRIPT} setup', device, encrypt]
    if encrypt == 'yes':
        cmd_parts.append(f'password={password}')
    cmd = ' '.join(cmd_parts)

    # Long timeout for rsync of large /home directories
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
def settings_disk_umount(request):
    """AJAX POST — unmount and close a LUKS /home volume."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    ok, stdout, stderr = run_command(
        f'{_HOME_PART_SCRIPT} umount', timeout=30)
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({'ok': True, 'message': '/home unmounted and LUKS volume closed.'})


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
    _ensure_user_playbooks_dir()
    files = sorted(f for f in os.listdir(USER_PLAYBOOKS_DIR)
                   if f.endswith('.yml') and f != 'inventory.yml')
    playbooks = []
    for fn in files:
        from .playbook_catalog import parse_docs
        path = os.path.join(USER_PLAYBOOKS_DIR, fn)
        docs = parse_docs(path)
        playbooks.append({
            'filename': fn,
            'title': (docs or {}).get('short_description', fn[:-4]) if docs else fn[:-4],
            'has_docs': docs is not None,
        })
    return render(request, 'main/settings_playbooks.html', {
        'playbooks': playbooks,
    })


@csrf_exempt
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


@csrf_exempt
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


@login_required
def settings_reapply_status(request):
    """AJAX GET — return current reapply progress.

    Status file values:
      idle                     — not running
      running                  — in progress (no detail)
      running:<n>/<total> <pb> — in progress with detail
      done:<exit_code>         — finished (0 = success)
    """
    raw = _reapply_status()
    if raw.startswith('running:'):
        parts = raw.split(' ', 2)
        progress = parts[0].replace('running:', '')
        playbook = parts[1] if len(parts) > 1 else ''
        return JsonResponse({
            'status': 'running',
            'progress': progress,
            'playbook': playbook,
        })
    elif raw.startswith('done:'):
        code = raw.replace('done:', '')
        return JsonResponse({
            'status': 'done',
            'success': code == '0',
        })
    else:
        return JsonResponse({'status': 'idle'})
