import subprocess
import yaml
import os
from pathlib import Path
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import JsonResponse, HttpResponse
from .forms import NetworkConfigForm
from .utils.log_utils import logs_stream
from .health import run_all as health_run_all
import urllib.request
import urllib.error
import json

CONFIG_PATH = os.environ.get('CONFIG_PATH', '/config/inventory.yml')
LDAP_URI = os.environ.get('LDAP_URI', 'ldap://openldap')


def _get_inventory_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def _save_inventory_config(config):
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)


def _ldap_run(cmd, input=None):
    try:
        proc = subprocess.run(cmd, input=input, capture_output=True, text=True, timeout=30)
        return proc.stdout, proc.stderr, proc.returncode
    except Exception as e:
        return '', str(e), 1


def _ldap_search(base_dn, admin_pw, search_base, filter_expr, attrs=None):
    cmd = [
        'ldapsearch', '-x', '-H', LDAP_URI,
        '-D', f'cn=head-of-ldap,{base_dn}', '-w', admin_pw,
        '-b', search_base,
    ]
    if filter_expr:
        cmd.append(filter_expr)
    if attrs:
        cmd.extend(attrs)
    stdout, stderr, rc = _ldap_run(cmd)
    return stdout, rc


def _ldap_modify(ldif, base_dn, admin_pw):
    cmd = ['ldapmodify', '-x', '-H', LDAP_URI, '-D', f'cn=head-of-ldap,{base_dn}', '-w', admin_pw]
    stdout, stderr, rc = _ldap_run(cmd, input=ldif)
    return rc, stderr


def _ldap_add(ldif, base_dn, admin_pw):
    cmd = ['ldapadd', '-x', '-H', LDAP_URI, '-D', f'cn=head-of-ldap,{base_dn}', '-w', admin_pw]
    proc = subprocess.run(cmd, input=ldif, capture_output=True, text=True, timeout=30)
    return proc.returncode, proc.stderr


def _ldap_delete(dn, base_dn, admin_pw):
    cmd = ['ldapdelete', '-x', '-H', LDAP_URI, '-D', f'cn=head-of-ldap,{base_dn}', '-w', admin_pw, dn]
    stdout, stderr, rc = _ldap_run(cmd)
    return rc, stderr


def _get_ldap_vars():
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    base_dn = vars_.get('ldap_basedn', 'dc=openldap,dc=local')
    admin_pw = vars_.get('ldap_admin_password', 'changeme')
    try:
        with open('/config/.ldap_admin_pw') as f:
            pw = f.read().strip()
            if pw:
                admin_pw = pw
    except Exception:
        pass
    return {'base_dn': base_dn, 'admin_pw': admin_pw}


def _get_next_uid_number():
    ldap = _get_ldap_vars()
    stdout, rc = _ldap_search(
        ldap['base_dn'], ldap['admin_pw'],
        f"ou=users,{ldap['base_dn']}", "(objectClass=posixAccount)", ["uidNumber"]
    )
    max_uid = 19999
    if rc == 0:
        for line in stdout.split('\n'):
            if line.startswith('uidNumber:'):
                try:
                    uid = int(line.split(':', 1)[1].strip())
                    if uid > max_uid:
                        max_uid = uid
                except ValueError:
                    pass
    return max_uid + 1


def _get_ldap_groups():
    ldap = _get_ldap_vars()
    stdout, rc = _ldap_search(
        ldap['base_dn'], ldap['admin_pw'],
        f"ou=groups,{ldap['base_dn']}", "(objectClass=posixGroup)", ["cn"]
    )
    groups = []
    if rc == 0:
        for line in stdout.split('\n'):
            if line.startswith('cn:'):
                val = line.split(':', 1)[1].strip()
                if val:
                    groups.append(val)
    return groups if groups else ['users']


def _get_ldap_users():
    ldap = _get_ldap_vars()
    stdout, rc = _ldap_search(
        ldap['base_dn'], ldap['admin_pw'],
        f"ou=users,{ldap['base_dn']}", "(objectClass=posixAccount)", ["uid", "cn", "mail"]
    )
    users = []
    if rc == 0:
        current_user = {}
        for line in stdout.split('\n'):
            if line.startswith('uid:'):
                if current_user and current_user.get('uid'):
                    users.append(current_user)
                current_user = {'uid': line.split(':', 1)[1].strip(), 'cn': '', 'email': '', 'groups': []}
            elif line.startswith('cn:') and current_user:
                current_user['cn'] = line.split(':', 1)[1].strip()
            elif line.startswith('mail:') and current_user:
                current_user['email'] = line.split(':', 1)[1].strip()
        if current_user and current_user.get('uid'):
            users.append(current_user)

    all_groups = set(_get_ldap_groups())

    for user in users:
        stdout2, rc2 = _ldap_search(
            ldap['base_dn'], ldap['admin_pw'],
            f"ou=groups,{ldap['base_dn']}",
            f"(&(objectClass=posixGroup)(memberUid={user['uid']}))", ["cn"]
        )
        if rc2 == 0:
            for line in stdout2.split('\n'):
                if line.startswith('cn:'):
                    val = line.split(':', 1)[1].strip()
                    if val:
                        user['groups'].append(val)
        user['available_groups'] = sorted(all_groups - set(user['groups']))
    return users


@login_required
def settings(request):
    return render(request, 'main/settings.html')


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
    if current_ipv4 and not result.get('ipv4_check_skipped') and current_ipv4 in result['dns_ipv4']:
        result['ipv4_match'] = True
    if current_ipv6 and current_ipv6 in result['dns_ipv6']:
        result['ipv6_match'] = True

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
                    messages.error(request, 'Cannot enable 2FA: No SMTP server configured. Configure a mailserver first under Settings → Mailserver (SMTP).')
                    return redirect('settings_auth')
            config['all']['vars']['twofa_enabled'] = twofa_wanted
            _save_inventory_config(config)
            messages.success(request, 'Auth settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_auth')

    return render(request, 'main/settings_auth.html', {'vars': vars_})


@login_required
def settings_mailserver(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            vars_['smtp_server'] = request.POST.get('smtp_server', '')
            vars_['smtp_port'] = request.POST.get('smtp_port', '')
            vars_['smtp_user'] = request.POST.get('smtp_user', '')
            vars_['smtp_password'] = request.POST.get('smtp_password', '')
            vars_['smtp_from'] = request.POST.get('smtp_from', '')
            vars_['smtp_tls'] = request.POST.get('smtp_tls', '')
            _save_inventory_config(config)
            messages.success(request, 'Mailserver settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_mailserver')

    return render(request, 'main/settings_mailserver.html', {'vars': vars_})


@login_required
def settings_mailserver_discover(request):
    import urllib.request, urllib.error, xml.etree.ElementTree as ET

    server = request.GET.get('server', '').strip().lower()
    if not server:
        return JsonResponse({'error': 'No server provided'})

    result = {'server': server, 'port': '587', 'tls': 'starttls', 'user': ''}

    try:
        domain = server
        if server.startswith('smtp.'):
            domain = server[5:]

        url = f'https://autoconfig.thunderbird.net/v1.1/{domain}'
        req = urllib.request.Request(url, headers={'User-Agent': 'SymbiOS'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            xml = resp.read()
            root = ET.fromstring(xml)
            for server_elem in root.findall('.//outgoingServer'):
                if server_elem.find('hostname') is not None:
                    host = server_elem.find('hostname').text
                    if host == server:
                        if server_elem.find('port') is not None:
                            result['port'] = server_elem.find('port').text
                        for auth in server_elem.findall('authentication'):
                            if auth.text == 'password-cleartext':
                                result['tls'] = 'starttls'
                            elif auth.text == 'SSL/TLS':
                                result['tls'] = 'tls'
                        if server_elem.find('username') is not None:
                            result['user'] = '%EMAILADDRESS%'
                        break
    except Exception:
        port_guess = {'587': 'starttls', '465': 'tls', '25': ''}
        for p, t in port_guess.items():
            try:
                import socket
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(3)
                if s.connect_ex((server, int(p))) == 0:
                    result['port'] = p
                    result['tls'] = t
                    result['user'] = '%EMAILADDRESS%'
                    s.close()
                    break
                s.close()
            except Exception:
                pass

    return JsonResponse(result)


def autoconfig_xml(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    smtp_server = vars_.get('smtp_server', '')
    smtp_port = vars_.get('smtp_port', '587')
    smtp_tls = vars_.get('smtp_tls', 'starttls')
    smtp_user = vars_.get('smtp_user', '%EMAILADDRESS%')
    smtp_from = vars_.get('smtp_from', '')

    domain = smtp_from.split('@')[-1] if '@' in smtp_from else ''

    if not smtp_server or not domain:
        return HttpResponse('<clientConfig version="1.1"/>',
                            content_type='text/xml')

    socket_type = 'SSL' if smtp_tls == 'tls' else 'STARTTLS' if smtp_tls == 'starttls' else 'plain'

    xml = f'''<?xml version="1.0"?>
<clientConfig version="1.1">
  <emailProvider id="{smtp_server}">
    <domain>{domain}</domain>
    <displayName>{domain}</displayName>
    <displayShortName>{domain}</displayShortName>
    <incomingServer type="imap">
      <hostname>{smtp_server}</hostname>
      <port>{smtp_port}</port>
      <socketType>{socket_type}</socketType>
      <username>{smtp_user}</username>
      <authentication>password-cleartext</authentication>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>{smtp_server}</hostname>
      <port>{smtp_port}</port>
      <socketType>{socket_type}</socketType>
      <username>{smtp_user}</username>
      <authentication>password-cleartext</authentication>
    </outgoingServer>
  </emailProvider>
</clientConfig>'''
    return HttpResponse(xml, content_type='text/xml')


@login_required
def logs(request):
    return render(request, 'main/logs.html', {'default_log_name': 'messages'})


@login_required
def users(request):
    users = _get_ldap_users()
    groups = _get_ldap_groups()
    return render(request, 'main/users_groups.html', {'users': users, 'groups': groups})


@login_required
def groups(request):
    groups = _get_ldap_groups()
    users = _get_ldap_users()
    return render(request, 'main/groups.html', {'groups': groups, 'group_members': users})


@login_required
def user_create(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '').strip()
        email = request.POST.get('email', '').strip()
        password = request.POST.get('password', '')
        group = request.POST.get('group', 'users')

        if not uid or not password:
            messages.error(request, 'All fields are required.')
            return redirect('users')

        ldap = _get_ldap_vars()
        uid_number = _get_next_uid_number()
        ldif = f"""dn: uid={uid},ou=users,{ldap['base_dn']}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: {uid}
sn: {uid}
cn: {uid}
displayName: {uid}
uidNumber: {uid_number}
gidNumber: 10000
homeDirectory: /home/{uid}
userPassword: {password}
"""
        if email:
            ldif += f"mail: {email}\n"
        rc, err = _ldap_add(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'User "{uid}" created.')
            _add_user_to_group(uid, group)
        else:
            messages.error(request, f'Error: {err}')
    return redirect('users')


@login_required
def user_delete(request, uid):
    if request.method == 'POST':
        ldap = _get_ldap_vars()
        rc, err = _ldap_delete(f"uid={uid},ou=users,{ldap['base_dn']}", ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'User "{uid}" deleted.')
        else:
            messages.error(request, f'Error: {err}')
    return redirect('users')


@login_required
def user_set_password(request, uid):
    if request.method == 'POST':
        password = request.POST.get('password', '')
        if not password:
            messages.error(request, 'Password is required.')
            return redirect('users')

        ldap = _get_ldap_vars()
        ldif = f"""dn: uid={uid},ou=users,{ldap['base_dn']}
changetype: modify
replace: userPassword
userPassword: {password}
"""
        rc, err = _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Password for "{uid}" changed.')
        else:
            messages.error(request, f'Error: {err}')
    return redirect('users')


@login_required
def user_update_email(request, uid):
    if request.method == 'POST':
        email = request.POST.get('email', '').strip()
        ldap = _get_ldap_vars()
        user_dn = f"uid={uid},ou=users,{ldap['base_dn']}"

        # Remove existing mail attribute first
        _ldap_modify(f"""dn: {user_dn}
changetype: modify
delete: mail
""", ldap['base_dn'], ldap['admin_pw'])

        # Add new email if provided
        if email:
            rc, err = _ldap_modify(f"""dn: {user_dn}
changetype: modify
add: mail
mail: {email}
""", ldap['base_dn'], ldap['admin_pw'])
        else:
            rc = 0

        if rc == 0:
            messages.success(request, f'Email for "{uid}" updated.')
        else:
            messages.error(request, f'Error: {err}')
    return redirect('users')


@login_required
def group_create(request):
    if request.method == 'POST':
        name = request.POST.get('name', '').strip()
        if not name:
            messages.error(request, 'Name is required.')
            return redirect('groups')

        ldap = _get_ldap_vars()
        gid = abs(hash(name)) % 10000 + 20000
        ldif = f"""dn: cn={name},ou=groups,{ldap['base_dn']}
objectClass: posixGroup
cn: {name}
gidNumber: {gid}
"""
        rc, err = _ldap_add(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Group "{name}" created.')
        else:
            messages.error(request, f'Error: {err}')
    return redirect('groups')


@login_required
def group_delete(request, name):
    if request.method == 'POST':
        ldap = _get_ldap_vars()
        group_dn = f"cn={name},ou=groups,{ldap['base_dn']}"

        # Remove all members from group first
        stdout, rc = _ldap_search(
            ldap['base_dn'], ldap['admin_pw'],
            group_dn, "(objectClass=posixGroup)", ["memberUid"]
        )
        if rc == 0:
            for line in stdout.split('\n'):
                if line.startswith('memberUid:'):
                    member_uid = line.split(':', 1)[1].strip()
                    if member_uid:
                        ldif = f"""dn: {group_dn}
changetype: modify
delete: memberUid
memberUid: {member_uid}
"""
                        _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])

        # Delete the group
        rc, err = _ldap_delete(group_dn, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Group "{name}" deleted.')
        else:
            messages.error(request, f'Error: {err}')
    return redirect('groups')


@login_required
def group_add_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            ldap = _get_ldap_vars()
            ldif = f"""dn: cn={group},ou=groups,{ldap['base_dn']}
changetype: modify
add: memberUid
memberUid: {uid}
"""
            rc, err = _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])
            if rc == 0:
                messages.success(request, f'"{uid}" added to "{group}".')
            else:
                messages.error(request, f'Error: {err}')
    return redirect('users')


@login_required
def group_remove_user(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '')
        group = request.POST.get('group', '')
        if uid and group:
            ldap = _get_ldap_vars()
            ldif = f"""dn: cn={group},ou=groups,{ldap['base_dn']}
changetype: modify
delete: memberUid
memberUid: {uid}
"""
            rc, err = _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])
            if rc == 0:
                messages.success(request, f'"{uid}" removed from "{group}".')
            else:
                messages.error(request, f'Error: {err}')
    return redirect('users')


def _add_user_to_group(uid, group):
    ldap = _get_ldap_vars()
    ldif = f"""dn: cn={group},ou=groups,{ldap['base_dn']}
changetype: modify
add: memberUid
memberUid: {uid}
"""
    _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])


@login_required
def health(request):
    return render(request, 'main/health.html')

@login_required
def health_data(request):
    from .health import run_all
    from django.http import JsonResponse
    return JsonResponse(run_all())


def configd_status(request):
    status_file = "/log/configd-status"
    try:
        with open(status_file) as f:
            status = f.read().strip()
    except FileNotFoundError:
        status = "idle"
    return JsonResponse({"status": status})


@login_required
def container_list(request):
    from .utils.log_utils import _get_container_list
    from django.http import JsonResponse
    containers = _get_container_list()
    return JsonResponse({"containers": containers})

