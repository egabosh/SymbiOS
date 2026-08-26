#!/bin/bash
# SymbiOS - Sync Home Assistant admin rights from LDAP group home-assistant-admins.
#
# Home Assistant's hass-oidc-auth component only evaluates role on user creation
# (async_user_meta_for_credentials is called only in async_create_user). So once
# a user is created with system-users, LDAP group changes are never reflected.
# This script reconciles the HA auth storage with LDAP group membership directly.
#
# Runs from the LDAP group-change hook system (/symbios/ldap-groups.d/).

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_ha_admin_sync {
  local f_pw f_desired f_desired_users f_current_groups
  local f_ha_storage="${g_services_root}/home-assistant/config/.storage/auth"
  local f_container="home-assistant"
  local f_ha_dir="${g_services_root}/home-assistant"

  # Skip silently when Home Assistant is not installed
  if [[ ! -f "${f_ha_dir}/docker-compose.yml" ]]
  then
    return 0
  fi

  # Skip if auth storage does not exist
  if [[ ! -f "${f_ha_storage}" ]]
  then
    g_echo_warn "HA auth storage not found at ${f_ha_storage}"
    return 0
  fi

  # LDAP admin password is mandatory
  f_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "$f_pw" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Desired admins: members of LDAP group home-assistant-admins
  f_desired=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=home-assistant-admins,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  # Desired regular users: members of LDAP group home-assistant-users
  f_desired_users=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=home-assistant-users,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  if [[ -z "$f_desired" && -z "$f_desired_users" ]]
  then
    g_echo_error "Could not read LDAP group members for home-assistant-admins or home-assistant-users"
    return 1
  fi

  g_echo_note "LDAP home-assistant-admins: ${f_desired:-<none>}"
  g_echo_note "LDAP home-assistant-users: ${f_desired_users:-<none>}"

  # Read current HA auth storage
  local f_storage
  f_storage=$(cat "${f_ha_storage}" 2>/dev/null)
  if [[ -z "$f_storage" ]]
  then
    g_echo_error "Could not read HA auth storage"
    return 1
  fi

  # Process each non-system-generated user in HA storage
  local f_changed=0
  local f_user_ids
  f_user_ids=$(echo "$f_storage" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data['data']['users']:
    if not u.get('system_generated', False) and u.get('name'):
        print(u['id'] + '|' + u['name'])
" 2>/dev/null)

  while IFS='|' read -r f_user_id f_user_name
  do
    [[ -z "$f_user_id" ]] && continue

    # Determine what the LDAP username would be
    # HA OIDC uses preferred_username which equals the LDAP uid
    local f_uid="$f_user_name"

    # Check current group_ids for this user
    f_current_groups=$(echo "$f_storage" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data['data']['users']:
    if u['id'] == '${f_user_id}':
        print(' '.join(u.get('group_ids', [])))
        break
" 2>/dev/null)

    # Determine desired groups based on LDAP membership
    local f_is_admin=0
    local f_is_user=0

    if grep -qx "$f_uid" <<<"$f_desired"
    then
      f_is_admin=1
    fi
    if grep -qx "$f_uid" <<<"$f_desired_users"
    then
      f_is_user=1
    fi

    # Determine target group (demote to system-users if not in any HA group)
    local f_target_group="system-users"
    if [[ "$f_is_admin" -eq 1 ]]
    then
      f_target_group="system-admin"
    fi

    # Check if change is needed
    if echo "$f_current_groups" | grep -qx "$f_target_group"
    then
      g_echo_debug "User ${f_uid} already has ${f_target_group}, no change"
      continue
    fi

    # Apply change via Python (atomic JSON update)
    g_echo_note "Updating ${f_uid}: ${f_current_groups} -> ${f_target_group}"
    f_storage=$(echo "$f_storage" | python3 -c "
import sys, json

data = json.load(sys.stdin)
for u in data['data']['users']:
    if u['id'] == '${f_user_id}':
        u['group_ids'] = ['${f_target_group}']
        break
json.dump(data, sys.stdout, indent=2)
" 2>/dev/null)
    f_changed=1
  done <<<"$f_user_ids"

  # Write back and restart HA if changes were made
  if [[ "$f_changed" -eq 1 ]]
  then
    echo "$f_storage" > "${f_ha_storage}"
    g_echo_note "Auth storage updated, restarting Home Assistant"
    docker compose -f "${f_ha_dir}/docker-compose.yml" restart "$f_container"
  else
    g_echo_debug "No changes needed"
  fi

  return 0
}

f_ha_admin_sync
