import subprocess
import yaml
import os
from pathlib import Path
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .forms import NetworkConfigForm
from .utils.log_utils import logs_stream

CONFIG_PATH = os.environ.get('CONFIG_PATH', '/config/inventory.yml')
LDAP_URI = os.environ.get('LDAP_URI', 'ldap://host.docker.internal')


def _get_inventory_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def _save_inventory_config(config):
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)


def _ldap_search(base_dn, admin_pw, search_base, filter_expr, *attrs):
    cmd = [
        'ldapsearch', '-x', '-H', LDAP_URI,
        '-D', f'cn=admin,{base_dn}', '-w', admin_pw,
        '-b', search_base
    ] + list(attrs)
    if filter_expr:
        cmd.insert(-len(list(attrs)) if attrs else len(cmd), filter_expr)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.stdout, result.returncode
    except Exception:
        return '', 1


def _ldap_modify(ldif, base_dn, admin_pw):
    cmd = ['ldapmodify', '-x', '-H', LDAP_URI, '-D', f'cn=admin,{base_dn}', '-w', admin_pw]
    try:
        proc = subprocess.run(cmd, input=ldif, capture_output=True, text=True, timeout=30)
        return proc.returncode, proc.stderr
    except Exception as e:
        return 1, str(e)


def _ldap_add(ldif, base_dn, admin_pw):
    cmd = ['ldapadd', '-x', '-H', LDAP_URI, '-D', f'cn=admin,{base_dn}', '-w', admin_pw]
    try:
        proc = subprocess.run(cmd, input=ldif, capture_output=True, text=True, timeout=30)
        return proc.returncode, proc.stderr
    except Exception as e:
        return 1, str(e)


def _ldap_delete(dn, base_dn, admin_pw):
    cmd = ['ldapdelete', '-x', '-H', LDAP_URI, '-D', f'cn=admin,{base_dn}', '-w', admin_pw, dn]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return proc.returncode, proc.stderr
    except Exception as e:
        return 1, str(e)


def _get_ldap_vars():
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    return {
        'base_dn': vars_.get('ldap_basedn', 'dc=openldap,dc=local'),
        'admin_pw': vars_.get('ldap_admin_password', 'changeme'),
    }


def _get_ldap_groups():
    ldap = _get_ldap_vars()
    stdout, rc = _ldap_search(
        ldap['base_dn'], ldap['admin_pw'],
        f"ou=groups,{ldap['base_dn']}", "(objectClass=posixGroup)", "cn"
    )
    groups = []
    if rc == 0:
        for line in stdout.split('\n'):
            if line.startswith('cn:'):
                groups.append(line.split(':', 1)[1].strip())
    return groups if groups else ['users']


def _get_ldap_users():
    ldap = _get_ldap_vars()
    stdout, rc = _ldap_search(
        ldap['base_dn'], ldap['admin_pw'],
        f"ou=people,{ldap['base_dn']}", "(objectClass=posixAccount)", "uid", "cn", "memberOf"
    )
    users = []
    if rc == 0:
        current_user = {}
        for line in stdout.split('\n'):
            if line.startswith('uid:'):
                if current_user:
                    users.append(current_user)
                current_user = {'uid': line.split(':', 1)[1].strip(), 'cn': '', 'groups': []}
            elif line.startswith('cn:') and current_user:
                current_user['cn'] = line.split(':', 1)[1].strip()
            elif line.startswith('memberOf:') and current_user:
                dn = line.split(':', 1)[1].strip()
                for part in dn.split(','):
                    if part.startswith('cn='):
                        current_user['groups'].append(part[3:])
        if current_user:
            users.append(current_user)
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
                messages.success(request, 'Netzwerk-Konfiguration gespeichert.')
            except Exception as e:
                messages.error(request, f'Fehler: {e}')
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
            messages.success(request, 'Konfiguration gespeichert.')
        except Exception as e:
            messages.error(request, f'Fehler beim Speichern: {e}')
        return redirect('settings_inventory')

    return render(request, 'main/settings_inventory.html', {'config': config, 'vars': vars_})


@login_required
def settings_ddns(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            config['all']['vars']['ddns_apikey'] = request.POST.get('ddns_apikey', '')
            config['all']['vars']['ddns_host'] = request.POST.get('ddns_host', '')
            config['all']['vars']['ddns_ipv6'] = request.POST.get('ddns_ipv6', '')
            _save_inventory_config(config)
            messages.success(request, 'dDNS-Einstellungen gespeichert.')
        except Exception as e:
            messages.error(request, f'Fehler: {e}')
        return redirect('settings_ddns')

    return render(request, 'main/settings_ddns.html', {'vars': vars_})


@login_required
def settings_auth(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            config['all']['vars']['ldap_admin_password'] = request.POST.get('ldap_admin_password', '')
            config['all']['vars']['smtp_user'] = request.POST.get('smtp_user', '')
            config['all']['vars']['smtp_password'] = request.POST.get('smtp_password', '')
            _save_inventory_config(config)
            messages.success(request, 'Auth-Einstellungen gespeichert.')
        except Exception as e:
            messages.error(request, f'Fehler: {e}')
        return redirect('settings_auth')

    return render(request, 'main/settings_auth.html', {'vars': vars_})


@login_required
def logs(request):
    return render(request, 'main/logs.html', {'default_log_name': 'symbios'})


@login_required
def users_groups(request):
    users = _get_ldap_users()
    groups = _get_ldap_groups()
    return render(request, 'main/users_groups.html', {'users': users, 'groups': groups})


@login_required
def user_create(request):
    if request.method == 'POST':
        uid = request.POST.get('uid', '').strip()
        cn = request.POST.get('cn', '').strip()
        password = request.POST.get('password', '')
        group = request.POST.get('group', 'users')

        if not uid or not cn or not password:
            messages.error(request, 'Alle Felder sind erforderlich.')
            return redirect('users_groups')

        ldap = _get_ldap_vars()
        ldif = f"""dn: uid={uid},ou=people,{ldap['base_dn']}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: {uid}
sn: {cn.split()[-1] if cn.split() else cn}
givenName: {cn.split()[0] if cn.split() else cn}
cn: {cn}
displayName: {cn}
uidNumber: 10000
gidNumber: 10000
homeDirectory: /home/{uid}
userPassword: {password}
"""
        rc, err = _ldap_add(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Benutzer "{uid}" erstellt.')
            _add_user_to_group(uid, group)
        else:
            messages.error(request, f'Fehler: {err}')
        return redirect('users_groups')

    return redirect('users_groups')


@login_required
def user_delete(request, uid):
    if request.method == 'POST':
        ldap = _get_ldap_vars()
        rc, err = _ldap_delete(f"uid={uid},ou=people,{ldap['base_dn']}", ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Benutzer "{uid}" gelöscht.')
        else:
            messages.error(request, f'Fehler: {err}')
    return redirect('users_groups')


@login_required
def user_set_password(request, uid):
    if request.method == 'POST':
        password = request.POST.get('password', '')
        if not password:
            messages.error(request, 'Passwort ist erforderlich.')
            return redirect('users_groups')

        ldap = _get_ldap_vars()
        ldif = f"""dn: uid={uid},ou=people,{ldap['base_dn']}
changetype: modify
replace: userPassword
userPassword: {password}
"""
        rc, err = _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Passwort für "{uid}" geändert.')
        else:
            messages.error(request, f'Fehler: {err}')
    return redirect('users_groups')


@login_required
def group_create(request):
    if request.method == 'POST':
        name = request.POST.get('name', '').strip()
        if not name:
            messages.error(request, 'Name ist erforderlich.')
            return redirect('users_groups')

        ldap = _get_ldap_vars()
        gid = abs(hash(name)) % 10000 + 20000
        ldif = f"""dn: cn={name},ou=groups,{ldap['base_dn']}
objectClass: posixGroup
cn: {name}
gidNumber: {gid}
"""
        rc, err = _ldap_add(ldif, ldap['base_dn'], ldap['admin_pw'])
        if rc == 0:
            messages.success(request, f'Gruppe "{name}" erstellt.')
        else:
            messages.error(request, f'Fehler: {err}')
    return redirect('users_groups')


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
                messages.success(request, f'"{uid}" zu "{group}" hinzugefügt.')
            else:
                messages.error(request, f'Fehler: {err}')
    return redirect('users_groups')


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
                messages.success(request, f'"{uid}" aus "{group}" entfernt.')
            else:
                messages.error(request, f'Fehler: {err}')
    return redirect('users_groups')


def _add_user_to_group(uid, group):
    ldap = _get_ldap_vars()
    ldif = f"""dn: cn={group},ou=groups,{ldap['base_dn']}
changetype: modify
add: memberUid
memberUid: {uid}
"""
    _ldap_modify(ldif, ldap['base_dn'], ldap['admin_pw'])
