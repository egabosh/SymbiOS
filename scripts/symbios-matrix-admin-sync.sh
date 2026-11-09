#!/bin/bash
# SymbiOS - Sync Matrix admin rights from the LDAP group matrix-admins.
#
# Synapse delegates authentication to the Matrix Authentication Service (MAS)
# and no longer decides admin rights itself: a token carries them as the scope
# urn:synapse:admin:*, which MAS only grants to users with the admin flag
# (users.can_request_admin in the MAS database). matrix-admins only gates the
# WebUI/Authelia access to matrix-web and matrix-admin, so this script
# reconciles the MAS admin flag with the group membership - the LDAP group is
# the single source of truth:
#   - members with an existing MAS account get the admin flag
#   - admins that left the group lose it
#   - accounts without an LDAP counterpart (mx-admin, the server notices
#     account) keep their rights: mx-admin is the break-glass login and the
#     token source of symbios-synapse-purge.sh and
#     symbios-matrix-recreate-room.sh, so it is never demoted - not even when
#     it exists as LDAP user and is missing in the group
#   - members without a MAS account yet are skipped (the account is created
#     on the first login through Authelia)
#
# The account name is derived the way MAS maps it: the Authelia username
# (preferred_username = LDAP uid) becomes the localpart, so
# @<uid>:matrix.<base_domain>.
#
# No service restarts: MAS evaluates the flag when a client requests its
# scopes, so a change reaches the next admin login (running sessions keep the
# scopes they were granted).
#
# Runs from the ldap-groups.d hook deployed by services/matrix.yml
# (matrix-admin-sync.hook) and from services/matrix.yml on every apply, which
# heals drift the hook never saw. No arguments.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Sync Matrix admin rights from the LDAP group matrix-admins.
Members of the group with an existing MAS account get the admin flag,
admins that left it lose it. Accounts without an LDAP counterpart (mx-admin,
server notices) are never touched. No arguments.

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

function f_matrix_admin_sync {
  local f_mx_dir="${g_services_root}/matrix"
  local f_env_db f_db_user f_db_pass f_pw f_domain
  local f_ldap_out f_ldap_rc f_desired f_current f_uid f_local f_in_ldap
  local f_changed=0 f_rc=0

  # Skip silently when Matrix is not installed
  if [[ ! -f "${f_mx_dir}/docker-compose.yml" ]]
  then
    return 0
  fi

  # A stopped stack has no database to reconcile
  if [[ "$(docker inspect -f '{{.State.Running}}' matrix-db 2>/dev/null)" != "true" ]]
  then
    return 0
  fi

  # The admin flag lives in the authentication service; without it there is
  # nothing to reconcile (and every mas-cli call would fail)
  if [[ "$(docker inspect -f '{{.State.Running}}' matrix-auth 2>/dev/null)" != "true" ]]
  then
    return 0
  fi

  # Database credentials of the Synapse stack (written by the playbook)
  f_env_db="${f_mx_dir}/env.db"
  f_db_user=$(grep -E '^POSTGRES_USER=' "${f_env_db}" 2>/dev/null | cut -d= -f2-)
  f_db_pass=$(grep -E '^POSTGRES_PASSWORD=' "${f_env_db}" 2>/dev/null | cut -d= -f2-)
  if [[ -z "${f_db_user}" || -z "${f_db_pass}" ]]
  then
    g_echo_error "No database credentials in ${f_env_db}"
    return 1
  fi

  # LDAP admin password is mandatory
  f_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "$f_pw" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  f_domain="matrix.${g_base_domain}"

  # psql inside the database container against the MAS database; -t -A prints
  # one bare value per line
  f_psql_mas() {
    docker exec -e PGPASSWORD="${f_db_pass}" matrix-db \
      psql -h 127.0.0.1 -U "${f_db_user}" -d mas -t -A -c "$1" 2>/dev/null
  }

  # mas-cli inside the MAS container (distroless image, so the CLI is the only
  # entry point)
  f_mas() {
    ( cd "${f_mx_dir}" && docker compose exec -T matrix-auth \
        mas-cli -c /config/mas-config.yaml "$@" )
  }

  # Desired admins: members of LDAP group matrix-admins. A missing group
  # (deleted event) means nobody is admin via LDAP; an unreachable LDAP is an
  # error - never demote anyone when the group could not be read.
  f_ldap_out=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
    -b "cn=matrix-admins,ou=groups,${g_ldap_basedn}" memberUid 2>&1)
  f_ldap_rc=$?
  case "${f_ldap_rc}" in
    0)
      f_desired=$(sed -n 's/^memberUid: //p' <<<"${f_ldap_out}" | sort -u)
      ;;
    32)
      f_desired=""
      ;;
    *)
      g_echo_error "LDAP query failed (rc ${f_ldap_rc}) - nothing changed"
      return 1
      ;;
  esac

  # Current admins from the MAS database (localparts, no server part)
  if ! f_current=$(f_psql_mas "SELECT username FROM users WHERE can_request_admin AND username IS NOT NULL;")
  then
    g_echo_error "Could not read the MAS admin list"
    return 1
  fi

  # Promote members of matrix-admins that exist as MAS account
  for f_uid in ${f_desired}
  do
    [[ "${f_uid}" =~ ^[a-z0-9._-]+$ ]] || continue
    if grep -qxF "${f_uid}" <<<"${f_current}"
    then
      continue
    fi
    if [[ -z "$(f_psql_mas "SELECT username FROM users WHERE username = '${f_uid}';")" ]]
    then
      g_echo_note "Skipping ${f_uid}: no MAS account yet (created on first login)"
      continue
    fi
    g_echo_note "Promoting @${f_uid}:${f_domain} to Synapse admin"
    if f_mas manage promote-admin "${f_uid}" >/dev/null 2>&1
    then
      f_changed=1
    else
      g_echo_error "Could not promote ${f_uid}"
      f_rc=1
    fi
  done

  # Demote admins that left the group - only accounts backed by an LDAP user,
  # so system accounts keep their rights. mx-admin is created by the playbook
  # itself and supplies the admin token of symbios-synapse-purge.sh and
  # symbios-matrix-recreate-room.sh, so it never depends on group membership.
  for f_local in ${f_current}
  do
    [[ "${f_local}" =~ ^[a-z0-9._-]+$ ]] || continue
    if [[ "${f_local}" == "mx-admin" ]]
    then
      continue
    fi
    if grep -qxF "${f_local}" <<<"${f_desired}"
    then
      continue
    fi
    f_in_ldap=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
      -D "cn=head-of-ldap,${g_ldap_basedn}" -w "$f_pw" \
      -b "ou=users,${g_ldap_basedn}" "(uid=${f_local})" dn 2>/dev/null \
      | grep -c "^dn: uid=")
    if [[ "${f_in_ldap:-0}" -gt 0 ]]
    then
      g_echo_note "Demoting @${f_local}:${f_domain} from Synapse admin"
      if f_mas manage demote-admin "${f_local}" >/dev/null 2>&1
      then
        f_changed=1
      else
        g_echo_error "Could not demote ${f_local}"
        f_rc=1
      fi
    else
      g_echo_note "Keeping @${f_local}:${f_domain}: no LDAP account (system account)"
    fi
  done

  # MAS applies the flag when a client requests its scopes, so no service has
  # to be restarted - running sessions keep the scopes they were granted.
  if [[ "${f_changed}" -eq 1 ]]
  then
    g_echo_note "Admin changes take effect on the next admin login (token scope)"
  else
    g_echo_note "Matrix admins already in sync"
  fi

  return $f_rc
}

f_matrix_admin_sync
