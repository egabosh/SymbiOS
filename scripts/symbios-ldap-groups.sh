#!/bin/bash

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

# Manage LDAP groups: create, delete, add/remove users, list members.
# Runs LDAP commands inside the webui container via docker exec,
# which has direct network access to the OpenLDAP service.
#
# Usage:
#   symbios-ldap-groups.sh --create --name <group>
#   symbios-ldap-groups.sh --delete --name <group>
#   symbios-ldap-groups.sh --add-user --name <group> --uid <user>
#   symbios-ldap-groups.sh --remove-user --name <group> --uid <user>
#   symbios-ldap-groups.sh --list-members --name <group>

source /etc/bash/gaboshlib.include 1>/dev/null 2>&1 || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh" 1>/dev/null 2>&1 || true

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

Manage LDAP groups in SymbiOS.

Actions (exactly one required):
  --create --name <group>           Create a new group
  --delete --name <group>           Delete a group (removes all members first)
  --add-user --name <group> --uid <user>   Add user to group
  --remove-user --name <group> --uid <user>  Remove user from group
  --list-members --name <group>     List members of a group
  --help                            Show this help
EOF
}

# Parse arguments
f_action=""
f_name=""
f_uid=""

while [[ $# -gt 0 ]]
do
  case "$1" in
    --create)
      f_action="create"
      shift
      ;;
    --delete)
      f_action="delete"
      shift
      ;;
    --add-user)
      f_action="add-user"
      shift
      ;;
    --remove-user)
      f_action="remove-user"
      shift
      ;;
    --list-members)
      f_action="list-members"
      shift
      ;;
    --name)
      f_name="$2"
      shift 2
      ;;
    --uid)
      f_uid="$2"
      shift 2
      ;;
    --help|-h)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage >&2
      exit 1
      ;;
  esac
done

# Validate action
if [[ -z "${f_action}" ]]
then
  g_echo_error "Missing required action (--create, --delete, --add-user, --remove-user, --list-members)"
  f_usage >&2
  exit 1
fi

if [[ -z "${f_name}" ]]
then
  g_echo_error "Missing required argument: --name"
  f_usage >&2
  exit 1
fi

# Validate group name format
if ! [[ "${f_name}" =~ ^[a-zA-Z0-9._-]+$ ]]
then
  g_echo_error "Invalid group name: may only contain letters, digits, dots, hyphens, underscores"
  exit 1
fi

# Read LDAP connection details from inventory
f_symbios_ldap_init
f_group_dn="cn=${f_name},ou=groups,${f_base_dn}"

case "${f_action}" in

  create)
    g_echo_note "Creating group: ${f_name}"

    # Generate a GID from the group name hash
    f_gid="$(python3 -c "print(abs(hash('${f_name}')) % 10000 + 20000)" 2>/dev/null || echo 20001)"

    f_ldif="dn: ${f_group_dn}
objectClass: posixGroup
cn: ${f_name}
gidNumber: ${f_gid}
"

    echo "${f_ldif}" | f_ldap_ldif ldapadd -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "Group '${f_name}' created"
    else
      g_echo_error "Failed to create group '${f_name}'"
      exit 1
    fi
    ;;

  delete)
    g_echo_note "Deleting group: ${f_name}"

    # Remove all members first
    f_members="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
      -b "${f_group_dn}" "(objectClass=posixGroup)" memberUid 2>/dev/null \
      | grep '^memberUid:' | awk '{print $2}' || true)"

    for f_member in ${f_members}
    do
      f_member_ldif="dn: ${f_group_dn}
changetype: modify
delete: memberUid
memberUid: ${f_member}
"
      echo "${f_member_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" 2>/dev/null
      g_echo_note "Removed '${f_member}' from group"
    done

    # Delete the group
    f_ldap_exec ldapdelete -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" "${f_group_dn}" 2>&1
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "Group '${f_name}' deleted"
    else
      g_echo_error "Failed to delete group '${f_name}'"
      exit 1
    fi
    ;;

  add-user)
    if [[ -z "${f_uid}" ]]
    then
      g_echo_error "Missing required argument: --uid"
      exit 1
    fi

    g_echo_note "Adding '${f_uid}' to group '${f_name}'"

    f_ldif="dn: ${f_group_dn}
changetype: modify
add: memberUid
memberUid: ${f_uid}
"

    echo "${f_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "User '${f_uid}' added to group '${f_name}'"
    else
      g_echo_error "Failed to add '${f_uid}' to group '${f_name}'"
      exit 1
    fi
    ;;

  remove-user)
    if [[ -z "${f_uid}" ]]
    then
      g_echo_error "Missing required argument: --uid"
      exit 1
    fi

    g_echo_note "Removing '${f_uid}' from group '${f_name}'"

    f_ldif="dn: ${f_group_dn}
changetype: modify
delete: memberUid
memberUid: ${f_uid}
"

    echo "${f_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "User '${f_uid}' removed from group '${f_name}'"
    else
      g_echo_error "Failed to remove '${f_uid}' from group '${f_name}'"
      exit 1
    fi
    ;;

  list-members)
    g_echo_note "Members of group '${f_name}':"

    f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
      -b "${f_group_dn}" "(objectClass=posixGroup)" memberUid 2>/dev/null \
      | grep '^memberUid:' | awk '{print $2}' || true
    ;;

esac
