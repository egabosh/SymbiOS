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

# Manage LDAP users: create, delete, modify.
# Runs LDAP commands inside the webui container via docker exec,
# which has direct network access to the OpenLDAP service.
# Passwords are passed via a secret file (chmod 600) for security.
#
# Usage:
#   symbios-ldap-user.sh --create --uid <name> --password-file <path> [options]
#   symbios-ldap-user.sh --delete --uid <name>
#   symbios-ldap-user.sh --modify --uid <name> [--password-file <path>] [--email <addr>]

source /etc/bash/gaboshlib.include 1>/dev/null 2>&1 || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh" 1>/dev/null 2>&1 || true

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

Manage LDAP users in SymbiOS.

Actions (exactly one required):
  --create --uid <name> --password-file <path> [options]   Create a new user
  --delete --uid <name>                                    Delete a user
  --modify --uid <name> [--password-file <path>] [--email <addr>]  Modify user

Create options:
  --email <addr>        Email address
  --displayname <name>  Display name (defaults to uid)
  --group <group>       Initial group (default: users)

Modify options:
  --password-file <path> New password file (optional)
  --email <addr>        New email (optional, at least one required)

General options:
  --help                Show this help
EOF
}

# Parse arguments
f_action=""
f_uid=""
f_password_file=""
f_password=""
f_email=""
f_displayname=""
f_group="users"
f_cleanup_files=""

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
    --modify)
      f_action="modify"
      shift
      ;;
    --uid)
      f_uid="$2"
      shift 2
      ;;
    --password-file)
      f_password_file="$2"
      shift 2
      ;;
    --email)
      f_email="$2"
      shift 2
      ;;
    --displayname)
      f_displayname="$2"
      shift 2
      ;;
    --group)
      f_group="$2"
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

# Read password from file if provided
if [[ -n "${f_password_file}" ]]
then
  if [[ -f "${f_password_file}" ]]
  then
    f_password="$(cat "${f_password_file}")"
    f_cleanup_files="${f_cleanup_files} ${f_password_file}"
  fi
  trap 'rm -f ${f_cleanup_files} 2>/dev/null' EXIT HINT INT TERM
fi

# Validate action
if [[ -z "${f_action}" ]]
then
  g_echo_error "Missing required action (--create, --delete, --modify)"
  f_usage >&2
  exit 1
fi

# Validate uid
if [[ -z "${f_uid}" ]]
then
  g_echo_error "Missing required argument: --uid"
  f_usage >&2
  exit 1
fi

if ! [[ "${f_uid}" =~ ^[a-z0-9._-]+$ ]]
then
  g_echo_error "Invalid uid: may only contain lowercase letters, digits, dots, hyphens, underscores"
  exit 1
fi

# Validate email format (if provided)
if [[ -n "${f_email}" ]] && ! [[ "${f_email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
then
  g_echo_error "Invalid email address format"
  exit 1
fi

# Validate group name format (if provided)
if [[ -n "${f_group}" ]] && ! [[ "${f_group}" =~ ^[a-zA-Z0-9._-]+$ ]]
then
  g_echo_error "Invalid group name: may only contain letters, digits, dots, hyphens, underscores"
  exit 1
fi

# Validate action-specific requirements
if [[ "${f_action}" == "create" ]] && [[ -z "${f_password_file}" ]]
then
  g_echo_error "Missing required argument: --password-file"
  f_usage >&2
  exit 1
fi

if [[ "${f_action}" == "modify" ]] && [[ -z "${f_password_file}" ]] && [[ -z "${f_email}" ]]
then
  g_echo_error "Modify requires at least --password-file or --email"
  f_usage >&2
  exit 1
fi

# Set displayname default
if [[ -z "${f_displayname}" ]]
then
  f_displayname="${f_uid}"
fi

# Validate displayname - reject newlines and LDIF-special characters
if [[ "${f_displayname}" =~ $'\n' ]] || [[ "${f_displayname}" =~ $'\r' ]]
then
  g_echo_error "Invalid displayname: contains illegal characters"
  exit 1
fi

# Read LDAP connection details from inventory
f_symbios_ldap_init
f_user_dn="uid=${f_uid},ou=users,${f_base_dn}"

case "${f_action}" in

  create)
    g_echo_note "Creating user: ${f_uid}"

    # Get next available UID number
    f_next_uid="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
      -b "ou=users,${f_base_dn}" "(objectClass=posixAccount)" uidNumber 2>/dev/null \
      | grep '^uidNumber:' | awk '{print $2}' | sort -n | tail -1)"

    f_uid_number=20000
    if [[ -n "${f_next_uid}" ]] && [[ "${f_next_uid}" -gt 19999 ]] 2>/dev/null
    then
      f_uid_number=$(( f_next_uid + 1 ))
    fi

    f_ldif="dn: ${f_user_dn}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: ${f_uid}
sn: ${f_uid}
cn: ${f_displayname}
displayName: ${f_displayname}
uidNumber: ${f_uid_number}
gidNumber: 10000
homeDirectory: /home/${f_uid}
userPassword: ${f_password}"

    if [[ -n "${f_email}" ]]
    then
      f_ldif="${f_ldif}
mail: ${f_email}"
    fi

    f_ldif="${f_ldif}
"

    echo "${f_ldif}" | f_ldap_ldif ldapadd -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
    f_rc=$?

    if [[ ${f_rc} -ne 0 ]]
    then
      g_echo_error "Failed to create user '${f_uid}'"
      exit 1
    fi

    g_echo_note "User '${f_uid}' created (uid=${f_uid_number})"

    # Add to group
    if [[ -n "${f_group}" ]]
    then
      f_group_ldif="dn: cn=${f_group},ou=groups,${f_base_dn}
changetype: modify
add: memberUid
memberUid: ${f_uid}
"

      echo "${f_group_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
      if [[ $? -eq 0 ]]
      then
        g_echo_note "User '${f_uid}' added to group '${f_group}'"
      else
        g_echo_warn "User created but failed to add to group '${f_group}'"
      fi
    fi
    ;;

  delete)
    g_echo_note "Deleting user: ${f_uid}"

    # Remove user from all groups first
    f_groups_output="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
      -b "ou=groups,${f_base_dn}" "(memberUid=${f_uid})" cn 2>/dev/null \
      | grep '^cn:' | awk '{print $2}' || true)"

    for f_group in ${f_groups_output}
    do
      f_group_ldif="dn: cn=${f_group},ou=groups,${f_base_dn}
changetype: modify
delete: memberUid
memberUid: ${f_uid}
"
      echo "${f_group_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" 2>/dev/null
      g_echo_note "Removed from group '${f_group}'"
    done

    # Delete the user entry
    f_ldap_exec ldapdelete -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" "${f_user_dn}" 2>&1
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "User '${f_uid}' deleted successfully"
    else
      g_echo_error "Failed to delete user '${f_uid}'"
      exit 1
    fi
    ;;

  modify)
    g_echo_note "Modifying user: ${f_uid}"

    f_ldif="dn: ${f_user_dn}
changetype: modify"

    f_need_sep=0

    if [[ -n "${f_email}" ]]
    then
      f_ldif="${f_ldif}
replace: mail
mail: ${f_email}"
      f_need_sep=1
    fi

    if [[ -n "${f_password}" ]]
    then
      if [[ ${f_need_sep} -eq 1 ]]
      then
        f_ldif="${f_ldif}
-"
      fi
      f_ldif="${f_ldif}
replace: userPassword
userPassword: ${f_password}"
    fi

    f_ldif="${f_ldif}
"

    echo "${f_ldif}" | f_ldap_ldif ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}"
    f_rc=$?

    if [[ ${f_rc} -eq 0 ]]
    then
      g_echo_note "User '${f_uid}' modified successfully"
    else
      g_echo_error "Failed to modify user '${f_uid}'"
      exit 1
    fi
    ;;

esac
