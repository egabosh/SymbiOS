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
    return {
        'base_dn': vars_.get('ldap_basedn', 'dc=openldap,dc=local'),
        'admin_pw': vars_.get('ldap_admin_password', 'changeme'),
    }


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
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            config['all']['vars']['ddns_apikey'] = request.POST.get('ddns_apikey', '')
            config['all']['vars']['ddns_host'] = request.POST.get('ddns_host', '')
            config['all']['vars']['ddns_ipv6'] = request.POST.get('ddns_ipv6', '')
            _save_inventory_config(config)
            messages.success(request, 'Dynamic DNS settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
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
            messages.success(request, 'Auth settings saved.')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_auth')

    return render(request, 'main/settings_auth.html', {'vars': vars_})


@login_required
def logs(request):
    return render(request, 'main/logs.html', {'default_log_name': 'symbios'})


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
