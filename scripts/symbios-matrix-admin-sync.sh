#!/bin/bash
# SymbiOS - Sync Synapse admin rights from the LDAP group matrix-admins.
#
# Synapse keeps the admin flag per account in its own database and knows
# nothing about LDAP groups: matrix-admins only gates the WebUI/Authelia
# access to matrix-web and matrix-admin. This script reconciles users.admin
# with the group membership, so the LDAP group is the single source of truth:
#   - members with an existing Synapse account get the admin flag
#   - admins that left the group lose it
#   - accounts without an LDAP counterpart (mx-admin, the server notices
#     account) keep their rights: mx-admin is the break-glass login and the
#     token source of symbios-synapse-purge.sh and
#     symbios-matrix-recreate-room.sh, so it is never demoted - not even when
#     it exists as LDAP user and is missing in the group
#   - members without a Synapse account yet are skipped (the account is
#     created on the first OIDC login)
#
# The account name is derived the way Synapse maps it: the Authelia username
# (preferred_username = LDAP uid) becomes the localpart, so
# @<uid>:matrix.<base_domain>.
#
# Synapse caches the admin flag per user and per access token, and a direct
# SQL write does not invalidate those caches. A change therefore restarts
# matrix-synapse; no change means no restart.
#
# Runs from the ldap-groups.d hook deployed by services/matrix.yml
# (matrix-admin-sync.hook) and from services/matrix.yml on every apply, which
# heals drift the hook never saw. No arguments.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Sync Synapse admin rights from the LDAP group matrix-admins.
Members of the group with an existing Synapse account get the admin flag,
admins that left it lose it. Accounts without an LDAP counterpart (mx-admin,
server notices) are never touched. A changed flag restarts matrix-synapse,
because Synapse caches it. No arguments.

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
  local f_ldap_out f_ldap_rc f_desired f_current f_uid f_user f_local f_in_ldap
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

  # psql inside the database container; -t -A prints one bare value per line
  f_psql() {
    docker exec -e PGPASSWORD="${f_db_pass}" matrix-db \
      psql -h 127.0.0.1 -U "${f_db_user}" -d synapse -t -A -c "$1" 2>/dev/null
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

  # Current admins from the Synapse database (deactivated accounts carry no
  # rights; admin/deactivated are smallint columns in the Postgres schema)
  if ! f_current=$(f_psql "SELECT name FROM users WHERE admin = 1 AND deactivated = 0;")
  then
    g_echo_error "Could not read the Synapse admin list"
    return 1
  fi

  # Promote members of matrix-admins that exist as Synapse account
  for f_uid in ${f_desired}
  do
    [[ "${f_uid}" =~ ^[a-z0-9._-]+$ ]] || continue
    f_user="@${f_uid}:${f_domain}"
    if grep -qxF "${f_user}" <<<"${f_current}"
    then
      continue
    fi
    if [[ -z "$(f_psql "SELECT name FROM users WHERE name = '${f_user}';")" ]]
    then
      g_echo_note "Skipping ${f_uid}: no Synapse account yet (created on first OIDC login)"
      continue
    fi
    g_echo_note "Promoting ${f_user} to Synapse admin"
    if f_psql "UPDATE users SET admin = 1 WHERE name = '${f_user}';" >/dev/null
    then
      f_changed=1
    else
      g_echo_error "Could not promote ${f_user}"
      f_rc=1
    fi
  done

  # Demote admins that left the group - only accounts backed by an LDAP user,
  # so system accounts keep their rights. mx-admin is created by the playbook
  # itself and supplies the admin token of symbios-synapse-purge.sh and
  # symbios-matrix-recreate-room.sh, so it never depends on group membership.
  for f_user in ${f_current}
  do
    f_local="${f_user#@}"
    f_local="${f_local%%:*}"
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
      g_echo_note "Demoting ${f_user} from Synapse admin"
      if f_psql "UPDATE users SET admin = 0 WHERE name = '${f_user}';" >/dev/null
      then
        f_changed=1
      else
        g_echo_error "Could not demote ${f_user}"
        f_rc=1
      fi
    else
      g_echo_note "Keeping ${f_user}: no LDAP account (system account)"
    fi
  done

  # Synapse caches the flag until the next restart - publish it on real changes
  if [[ "${f_changed}" -eq 1 ]]
  then
    g_echo_note "Restarting matrix-synapse so the admin flag takes effect"
    if ! docker restart matrix-synapse >/dev/null
    then
      g_echo_error "Restart of matrix-synapse failed"
      f_rc=1
    fi
  else
    g_echo_note "Synapse admins already in sync"
  fi

  return $f_rc
}

f_matrix_admin_sync
