#!/bin/bash
# SymbiOS - Sync OpenWebUI admin rights from LDAP group openwebui-admins.
#
# OpenWebUI maps OIDC groups to roles, but the mapping does not demote
# accounts whose admin flag predates the LDAP groups (e.g. migrated rows
# that were admin on the old system). This script reconciles the internal
# role column with the LDAP group membership instead. OpenWebUI rows
# without an LDAP counterpart (e.g. the local admin@localhost fallback)
# are never touched, only accounts that exist as posixAccount in LDAP.
#
# Runs from the ldap-groups.d hook (member-added/member-removed on
# openwebui-admins) deployed by services/openwebui.yml. No arguments.
#
# No container restart: OpenWebUI loads the user incl. role from the
# database on every request (get_current_user -> Users.get_user_by_id),
# so a role change takes effect on the very next request. The single-row
# UPDATE runs with a busy timeout, which is safe against the app's
# short-lived SQLite sessions even in WAL mode.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Sync OpenWebUI admin rights from the LDAP group openwebui-admins.
OpenWebUI rows without LDAP counterpart are never touched. No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so hooks work without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_openwebui_admin_sync {
  local f_pw f_desired f_current f_uid f_in_ldap f_db
  local f_openwebui_dir="${g_services_root}/openwebui"

  # Skip silently when OpenWebUI is not installed
  if [[ ! -f "${f_openwebui_dir}/docker-compose.yml" ]]
  then
    return 0
  fi
  f_db="${f_openwebui_dir}/openwebui-data/webui.db"
  if [[ ! -f "${f_db}" ]]
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

  # Desired admins: members of LDAP group openwebui-admins.
  # OpenWebUI matches the OIDC account by username (preferred_username),
  # which equals the LDAP uid, so memberUid maps 1:1 to user.name.
  f_desired=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=openwebui-admins,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  # Current admins: OpenWebUI users with role admin
  f_current=$(sqlite3 "$f_db" "SELECT name FROM \"user\" WHERE role='admin';" 2>/dev/null | sort -u)

  if [[ -z "$f_desired" && -z "$f_current" ]]
  then
    g_echo_error "Could not read LDAP group members nor OpenWebUI admin members"
    return 1
  fi

  local f_rc=0

  # Single-row writes with a busy timeout: safe against the app's
  # short-lived SQLite sessions, no container restart needed.
  f_sqlite() {
    sqlite3 -cmd ".timeout 15000" "$f_db" "$1" 2>/dev/null
  }

  # Promote missing members of openwebui-admins (only existing OpenWebUI rows)
  for f_uid in $f_desired
  do
    [[ "$f_uid" =~ ^[a-z0-9._-]+$ ]] || continue
    if grep -qx "$f_uid" <<<"$f_current"
    then
      continue
    fi
    if ! sqlite3 "$f_db" "SELECT 1 FROM \"user\" WHERE name='$f_uid';" 2>/dev/null | grep -q 1
    then
      g_echo_note "Skipping $f_uid: no OpenWebUI account yet (created on first OIDC login)"
      continue
    fi
    g_echo_note "Promoting $f_uid to OpenWebUI admin"
    f_sqlite "UPDATE \"user\" SET role='admin' WHERE name='$f_uid';" || f_rc=1
  done

  # Demote ex-members (never touch rows without LDAP counterpart)
  for f_uid in $f_current
  do
    [[ "$f_uid" =~ ^[a-z0-9._-]+$ ]] || continue
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
      g_echo_note "Demoting $f_uid from OpenWebUI admin"
      f_sqlite "UPDATE \"user\" SET role='user' WHERE name='$f_uid';" || f_rc=1
    else
      g_echo_note "Keeping $f_uid: no LDAP account (system row)"
    fi
  done

  return $f_rc
}

f_openwebui_admin_sync
