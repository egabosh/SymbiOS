from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from .views import (
    _get_inventory_config, _save_inventory_config, _get_ldap_vars,
    _ldap_search, _ldap_modify, _ldap_add, _ldap_delete,
    _get_next_uid_number, _get_ldap_groups, _get_ldap_users,
    _add_user_to_group,
)


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
