#!/bin/bash

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

# LDAP management wrapper for SymbiOS.
# Provides subcommands for search, add, modify, delete, list-users,
# list-groups, add-user-to-group, remove-user-from-group, and next-uid.
#
# Usage: symbios-ldap.sh <command> [options]
#
# All commands read credentials from /config/inventory.yml and
# /config/.ldap_admin_pw automatically.

set -euo pipefail

# Read LDAP connection details from inventory and password file
function f_read_ldap_vars {
  g_config_path="${CONFIG_PATH:-/config/inventory.yml}"
  g_ldap_uri="${LDAP_URI:-ldap://openldap}"

  # Parse base_dn from inventory
  g_base_dn="$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('${g_config_path}')) or {}
    print(cfg.get('all',{}).get('vars',{}).get('ldap_basedn','dc=openldap,dc=local'))
except: print('dc=openldap,dc=local')
" 2>/dev/null)"

  # Read admin password from file
  g_admin_pw="$(cat /config/.ldap_admin_pw 2>/dev/null || echo 'changeme')"

  g_bind_dn="cn=head-of-ldap,${g_base_dn}"
}

# Search LDAP directory
function f_cmd_search {
  local f_filter="$1"
  local f_base="${2:-}"
  local f_attrs="${3:-}"

  f_read_ldap_vars

  local f_search_base="${f_base:-ou=users,${g_base_dn}}"

  local f_cmd=(ldapsearch -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" -b "${f_search_base}")
  if [[ -n "${f_filter}" ]]
  then
    f_cmd+=("${f_filter}")
  fi
  if [[ -n "${f_attrs}" ]]
  then
    f_cmd+=(${f_attrs})
  fi

  "${f_cmd[@]}" 2>/dev/null
}

# Add LDAP entry from LDIF on stdin
function f_cmd_add {
  f_read_ldap_vars
  ldapadd -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" 2>&1
}

# Modify LDAP entry from LDIF on stdin
function f_cmd_modify {
  f_read_ldap_vars
  ldapmodify -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" 2>&1
}

# Delete LDAP entry by DN
function f_cmd_delete {
  local f_dn="$1"
  f_read_ldap_vars
  ldapdelete -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" "${f_dn}" 2>&1
}

# List all user UIDs
function f_cmd_list_users {
  f_read_ldap_vars
  ldapsearch -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" \
    -b "ou=users,${g_base_dn}" "(objectClass=posixAccount)" uid cn mail 2>/dev/null \
  | grep -E '^(uid|cn|mail):' || true
}

# List all group names
function f_cmd_list_groups {
  f_read_ldap_vars
  ldapsearch -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" \
    -b "ou=groups,${g_base_dn}" "(objectClass=posixGroup)" cn 2>/dev/null \
  | grep '^cn:' | awk '{print $2}' || true
}

# Get next available UID number
function f_cmd_next_uid {
  f_read_ldap_vars
  f_max_uid=19999

  f_output="$(ldapsearch -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" \
    -b "ou=users,${g_base_dn}" "(objectClass=posixAccount)" uidNumber 2>/dev/null \
    | grep '^uidNumber:' | awk '{print $2}' || true)"

  for f_uid in ${f_output}
  do
    if [[ "${f_uid}" -gt "${f_max_uid}" ]] 2>/dev/null
    then
      f_max_uid="${f_uid}"
    fi
  done

  echo $(( f_max_uid + 1 ))
}

# Add user to group
function f_cmd_add_to_group {
  local f_uid="$1"
  local f_group="$2"
  f_read_ldap_vars

  local f_ldif="dn: cn=${f_group},ou=groups,${g_base_dn}
changetype: modify
add: memberUid
memberUid: ${f_uid}"

  echo "${f_ldif}" | ldapmodify -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" 2>&1
}

# Remove user from group
function f_cmd_remove_from_group {
  local f_uid="$1"
  local f_group="$2"
  f_read_ldap_vars

  local f_ldif="dn: cn=${f_group},ou=groups,${g_base_dn}
changetype: modify
delete: memberUid
memberUid: ${f_uid}"

  echo "${f_ldif}" | ldapmodify -x -H "${g_ldap_uri}" -D "${g_bind_dn}" -w "${g_admin_pw}" 2>&1
}

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

LDAP management for SymbiOS.

Commands:
  search <filter> [base] [attrs]   Search LDAP directory
  add                              Add entry (LDIF on stdin)
  modify                           Modify entry (LDIF on stdin)
  delete <dn>                      Delete entry by DN
  list-users                       List all users (uid, cn, mail)
  list-groups                      List all group names
  next-uid                         Get next available UID number
  add-to-group <uid> <group>       Add user to group
  remove-from-group <uid> <group>  Remove user from group

Environment:
  CONFIG_PATH    Path to inventory.yml (default: /config/inventory.yml)
  LDAP_URI       LDAP server URI (default: ldap://openldap)
EOF
}

# Main dispatch
case "${1:-}" in
  search)         f_cmd_search "${2:-}" "${3:-}" "${4:-}" ;;
  add)            f_cmd_add ;;
  modify)         f_cmd_modify ;;
  delete)         f_cmd_delete "${2:-}" ;;
  list-users)     f_cmd_list_users ;;
  list-groups)    f_cmd_list_groups ;;
  next-uid)       f_cmd_next_uid ;;
  add-to-group)   f_cmd_add_to_group "${2:-}" "${3:-}" ;;
  remove-from-group) f_cmd_remove_from_group "${2:-}" "${3:-}" ;;
  -h|--help|help) f_usage ;;
  *)
    g_echo_error "Unknown command: ${1:-}"
    f_usage >&2
    exit 1
    ;;
esac
