import subprocess
import yaml
import os
from pathlib import Path
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.http import JsonResponse, HttpResponse
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


def _safe_write(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _save_inventory_config(config):
    import os, copy
    # Keep a backup of the last good version
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                bak = CONFIG_PATH + '.bak'
                with open(bak, 'w') as b:
                    b.write(f.read())
        except Exception:
            pass
    dumped = yaml.dump(config, default_flow_style=False, allow_unicode=True)
    _safe_write(CONFIG_PATH, dumped)


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


@login_required
def container_list(request):
    from .utils.log_utils import _get_container_list
    from django.http import JsonResponse
    containers = _get_container_list()
    return JsonResponse({"containers": containers})


from django.contrib.auth import logout as django_logout


def logout_view(request):
    config = _get_inventory_config()
    vars_ = config.get("all", {}).get("vars", {})
    default_domain = vars_.get("default_domain", "")
    django_logout(request)
    if default_domain:
        from django.shortcuts import redirect
        return redirect(f"https://auth.{default_domain}/logout")
    from django.shortcuts import redirect
    return redirect("/login/")


def authelia_logout(request):
    from django.shortcuts import render
    return render(request, "main/authelia_logout.html")
