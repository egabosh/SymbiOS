#!/bin/bash
# SymbiOS - Sync Paperless admin rights from LDAP group paperless-admins.
#
# Paperless (django-allauth) has no group-to-role mapping: OIDC logins never
# grant admin rights. This script reconciles the internal is_superuser /
# is_staff flags with the LDAP group membership instead. Paperless rows
# without an LDAP counterpart (e.g. admin, consumer, AnonymousUser) are
# never touched, only accounts that exist as posixAccount in LDAP.
# OIDC-linked rows keep their flags across logins (allauth does not reset
# is_superuser/is_staff on social login).
#
# Runs from the ldap-groups.d hook (member-added/member-removed on
# paperless-admins) deployed by services/paperless.yml. No arguments.
#
# SQLite note: paperless holds db.sqlite3 open in WAL mode, so the app
# container is stopped for the write and started afterwards. Group changes
# are rare events; seconds of downtime are acceptable and safer than a
# busy-locked write.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Sync Paperless admin rights from the LDAP group paperless-admins.
Paperless rows without LDAP counterpart are never touched. No arguments.

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

function f_paperless_admin_sync {
  local f_pw f_desired f_current f_uid f_in_ldap f_db
  local f_paperless_dir="${g_services_root}/paperless"

  # Skip silently when Paperless is not installed
  if [[ ! -f "${f_paperless_dir}/docker-compose.yml" ]]
  then
    return 0
  fi
  f_db="${f_paperless_dir}/data/db.sqlite3"
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

  # Desired admins: members of LDAP group paperless-admins
  f_desired=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=paperless-admins,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  # Current admins: paperless users with is_superuser set
  f_current=$(sqlite3 "$f_db" "SELECT username FROM auth_user WHERE is_superuser=1;" 2>/dev/null | sort -u)

  if [[ -z "$f_desired" && -z "$f_current" ]]
  then
    g_echo_error "Could not read LDAP group members nor Paperless admin members"
    return 1
  fi

  # Stop the app for a consistent SQLite write (WAL mode)
  local f_was_running=""
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx paperless
  then
    f_was_running=1
    (cd "$f_paperless_dir" && docker compose stop paperless >/dev/null 2>&1)
  fi

  local f_rc=0

  # Promote missing members of paperless-admins (only existing paperless rows)
  for f_uid in $f_desired
  do
    [[ "$f_uid" =~ ^[a-z0-9._-]+$ ]] || continue
    if grep -qx "$f_uid" <<<"$f_current"
    then
      continue
    fi
    if ! sqlite3 "$f_db" "SELECT 1 FROM auth_user WHERE username='$f_uid';" 2>/dev/null | grep -q 1
    then
      g_echo_note "Skipping $f_uid: no Paperless account yet (links on first OIDC login)"
      continue
    fi
    g_echo_note "Promoting $f_uid to Paperless admin"
    sqlite3 "$f_db" "UPDATE auth_user SET is_superuser=1, is_staff=1 WHERE username='$f_uid';" 2>/dev/null || f_rc=1
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
      g_echo_note "Demoting $f_uid from Paperless admin"
      sqlite3 "$f_db" "UPDATE auth_user SET is_superuser=0, is_staff=0 WHERE username='$f_uid';" 2>/dev/null || f_rc=1
    else
      g_echo_note "Keeping $f_uid: no LDAP account (system row)"
    fi
  done

  # Restart the app if it was running
  if [[ -n "$f_was_running" ]]
  then
    (cd "$f_paperless_dir" && docker compose up -d paperless >/dev/null 2>&1)
  fi

  return $f_rc
}

f_paperless_admin_sync
