#!/bin/bash
# SymbiOS - Sync Nextcloud admin rights from LDAP group nextcloud-admins.
#
# ldapAdminGroup only promotes users logging in through the user_ldap
# backend; accounts provisioned via OIDC are never promoted. This script
# reconciles the internal Nextcloud "admin" group with the LDAP group
# membership instead. Local users (e.g. ncadmin) are never touched, only
# accounts that exist as posixAccount in LDAP.
#
# Runs from cron (/etc/cron.d/symbios-nextcloud-sync) and from
# services/nextcloud.yml (nextcloud.init.sh).

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_nextcloud_admin_sync {
  local f_pw f_desired f_current f_uid f_in_ldap f_db_user f_db_pass
  local f_nc_dir="${g_services_root}/nextcloud"

  # Skip silently when Nextcloud is not installed
  if [[ ! -f "${f_nc_dir}/docker-compose.yml" ]]
  then
    return 0
  fi

  # LDAP admin password is mandatory
  f_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "$f_pw" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Desired admins: members of LDAP group nextcloud-admins
  f_desired=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=nextcloud-admins,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  # Current admins: members of internal Nextcloud group "admin"
  f_db_user=$(grep ^MYSQL_USER= "${f_nc_dir}/env" | cut -d= -f2-)
  f_db_pass=$(grep ^MYSQL_PASSWORD= "${f_nc_dir}/env" | cut -d= -f2-)
  f_current=$(docker exec nextcloud-db mariadb -u"$f_db_user" -p"$f_db_pass" nextcloud-db -N -e 'SELECT uid FROM oc_group_user WHERE gid="admin";' 2>/dev/null | sort -u)

  if [[ -z "$f_desired" && -z "$f_current" ]]
  then
    g_echo_error "Could not read LDAP group members nor NC admin members"
    return 1
  fi

  # Promote missing members of nextcloud-admins
  for f_uid in $f_desired
  do
    if ! grep -qx "$f_uid" <<<"$f_current"
    then
      g_echo_note "Promoting $f_uid to Nextcloud admin"
      docker compose -f "${f_nc_dir}/docker-compose.yml" exec -T -u www-data nextcloud ./occ group:adduser admin "$f_uid"
    fi
  done

  # Demote LDAP users that left nextcloud-admins (never local users)
  for f_uid in $f_current
  do
    if grep -qx "$f_uid" <<<"$f_desired"
    then
      continue
    fi
    f_in_ldap=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
      -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
      -b "ou=users,${g_ldap_basedn}" "(uid=$f_uid)" dn 2>/dev/null \
      | grep -c "^dn: uid=")
    if [[ "${f_in_ldap:-0}" -gt 0 ]]
    then
      g_echo_note "Demoting $f_uid from Nextcloud admin"
      docker compose -f "${f_nc_dir}/docker-compose.yml" exec -T -u www-data nextcloud ./occ group:removeuser admin "$f_uid"
    fi
  done

  return 0
}

f_nextcloud_admin_sync
