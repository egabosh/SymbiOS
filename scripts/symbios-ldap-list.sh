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

# List LDAP users and groups as JSON for the WebUI.
# Runs ldapsearch inside the webui container via docker exec,
# which has direct network access to the OpenLDAP service.
#
# Usage:
#   symbios-ldap-list.sh --users     # JSON array of users with groups
#   symbios-ldap-list.sh --groups    # JSON array of group names

source /etc/bash/gaboshlib.include 1>/dev/null 2>&1 || true
source symbios-lib.sh 1>/dev/null 2>&1 || true

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

List LDAP data as JSON for the WebUI.

Options:
  --users     List all users with uid, cn, email, groups
  --groups    List all group names
  --help      Show this help
EOF
}

# Parse arguments
f_action=""

while [[ $# -gt 0 ]]
do
  case "$1" in
    --users)
      f_action="users"
      shift
      ;;
    --groups)
      f_action="groups"
      shift
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

if [[ -z "${f_action}" ]]
then
  g_echo_error "Missing required option: --users or --groups"
  f_usage >&2
  exit 1
fi

# Read LDAP connection details from inventory
f_symbios_ldap_init

if [[ "${f_action}" == "groups" ]]
then
  # List all groups as JSON array
  f_groups="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "ou=groups,${f_base_dn}" "(objectClass=posixGroup)" cn 2>/dev/null \
    | grep '^cn:' | awk '{print $2}' || true)"

  f_json="["
  f_first=1
  for f_group in ${f_groups}
  do
    if [[ ${f_first} -eq 1 ]]
    then
      f_first=0
    else
      f_json="${f_json},"
    fi
    f_json="${f_json}\"${f_group}\""
  done
  f_json="${f_json}]"

  echo "${f_json}"

elif [[ "${f_action}" == "users" ]]
then
  # Get all groups with their members (for membership lookup)
  f_groups_raw="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "ou=groups,${f_base_dn}" "(objectClass=posixGroup)" cn memberUid 2>/dev/null || true)"

  # Get all users with basic attributes
  f_users_raw="$(f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "ou=users,${f_base_dn}" "(objectClass=posixAccount)" uid cn mail 2>/dev/null || true)"

  # Parse everything into JSON using Python
  python3 -c "
import sys, json

groups_data = sys.stdin.read().split('---LDAPSeparator---')
groups_raw = groups_data[0] if len(groups_data) > 0 else ''
users_raw = groups_data[1] if len(groups_data) > 1 else ''

# Parse groups and their members
group_members = {}
current_group = None
for line in groups_raw.split('\n'):
    line = line.strip()
    if line.startswith('cn:'):
        current_group = line.split(':', 1)[1].strip()
        if current_group:
            group_members[current_group] = []
    elif line.startswith('memberUid:') and current_group:
        uid = line.split(':', 1)[1].strip()
        if uid:
            group_members[current_group].append(uid)

all_groups = sorted(group_members.keys())

# Parse users
users = []
current = {}
for line in users_raw.split('\n'):
    line = line.strip()
    if line.startswith('uid:'):
        if current and current.get('uid'):
            users.append(current)
        current = {'uid': line.split(':', 1)[1].strip(), 'cn': '', 'email': '', 'groups': [], 'available_groups': []}
    elif line.startswith('cn:') and current:
        current['cn'] = line.split(':', 1)[1].strip()
    elif line.startswith('mail:') and current:
        current['email'] = line.split(':', 1)[1].strip()

if current and current.get('uid'):
    users.append(current)

# Find groups for each user
for user in users:
    uid = user['uid']
    user_groups = [g for g, members in group_members.items() if uid in members]
    user['groups'] = sorted(user_groups)
    user['available_groups'] = sorted(set(all_groups) - set(user_groups))

print(json.dumps(users))
" <<< "${f_groups_raw}---LDAPSeparator---${f_users_raw}"
fi
