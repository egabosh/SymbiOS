#!/bin/bash

# SymbiOS - Sync Mastodon admin roles from LDAP group <instance>-admins.
#
# Mastodon has no group mapping for OIDC. The LDAP group-change hook deployed
# by services/mastodon.yml calls this script after membership changes; the
# playbook can also run it in reconcile mode after a deploy. Accounts that do
# not exist yet are skipped (Mastodon creates them on the first OIDC login).
#
# The username comes from the OIDC preferred_username claim, which Authelia
# fills from the LDAP uid attribute.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <instance> <add|remove|reconcile> [uid]

Sync Mastodon admin roles from the LDAP group mastodon-<instance>-admins.

Modes:
  add <uid>       grant the built-in Admin role to an existing account
  remove <uid>    remove the current role from an existing account
  reconcile       make the Mastodon Admin roles match the LDAP group exactly

Options:
  -h, --help      Show this help and exit

Examples:
  symbios-mastodon-admin-sync.sh social add alice
  symbios-mastodon-admin-sync.sh social remove alice
  symbios-mastodon-admin-sync.sh social reconcile

Output:
  One status line per changed account; no output when everything is in sync.

Exit codes:
  0   sync succeeded or the account does not exist yet
  1   technical error (LDAP/DB unreadable, container not running)
  2   usage error
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include
fi
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -r "$g_script_dir/symbios-lib.sh" ]]
then
  source "$g_script_dir/symbios-lib.sh"
fi

g_config_dir="${g_config_dir:-/symbios/base-services/symbios-ui/config}"

function f_run_tootctl {
  local f_instance="$1"
  local f_uid="$2"
  local f_mode="$3"
  local f_container="symbios-mastodon-${f_instance}-web"
  local f_args f_output

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$f_container"
  then
    g_echo_error "Mastodon web container is not running: $f_container"
    return 1
  fi

  if [[ "$f_mode" == "add" ]]
  then
    f_args=(accounts modify "$f_uid" --role Admin)
  else
    f_args=(accounts modify "$f_uid" --remove-role)
  fi

  if f_output=$(docker exec "$f_container" tootctl "${f_args[@]}" 2>&1)
  then
    g_echo_ok "$f_instance: $f_mode admin role for $f_uid"
    return 0
  fi

  # A user added to the LDAP group before the first OIDC login has no local
  # Mastodon account yet. That is expected and must not fail the group change.
  if grep -Eqi 'not found|does not exist|could not find|no user with such username' <<<"$f_output"
  then
    g_echo_note "$f_instance: no Mastodon account for $f_uid yet (created on first login)"
    return 0
  fi

  g_echo_error "$f_instance: tootctl failed for $f_uid: $f_output"
  return 1
}

function f_ldap_admins {
  local f_instance="$1"
  local f_output

  # LDAP admin bind via a transient password file (never in argv).
  f_symbios_ldap_init
  if [[ -z "${f_ldap_pw_file}" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Distinguish an empty group from an unreadable one: an LDAP failure must
  # never demote every Mastodon admin during reconcile.
  f_output=$(ldapsearch -x -H ldap://127.0.0.1:389 \
    -D "${f_bind_dn}" -y "${f_ldap_pw_file}" \
    -b "cn=mastodon-${f_instance}-admins,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null) || return 1
  printf '%s\n' "$f_output" | sed -n 's/^memberUid: //p' | sort -u
}

function f_current_admins {
  local f_instance="$1"
  local f_db="symbios-mastodon-${f_instance}-db"
  local f_sql="SELECT a.username FROM accounts a JOIN users u ON u.account_id = a.id JOIN user_roles r ON u.role_id = r.id WHERE r.name = 'Admin' AND a.domain IS NULL"
  local f_output

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$f_db"
  then
    g_echo_error "Mastodon database container is not running: $f_db"
    return 1
  fi

  # POSTGRES_PASSWORD is already present in the db container environment, so
  # the secret never appears in a host process argument. Capture the result
  # before filtering it: a failed query must not look like an empty group.
  f_output=$(docker exec "$f_db" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U mastodon -d mastodon -t -A -c "$1"' sh "$f_sql" 2>/dev/null) || return 1
  printf '%s\n' "$f_output" | sed '/^$/d' | sort -u
}

if [[ $# -lt 2 || $# -gt 3 ]]
then
  f_usage >&2
  exit 2
fi

f_instance="$1"
f_mode="$2"
f_uid="${3:-}"

if ! [[ "$f_instance" =~ ^[a-z0-9][a-z0-9-]*$ ]]
then
  g_echo_error "Invalid Mastodon instance name: $f_instance"
  exit 2
fi

case "$f_mode" in
  add|remove)
    if [[ -z "$f_uid" || ! "$f_uid" =~ ^[a-z0-9._-]+$ ]]
    then
      g_echo_error "Invalid LDAP uid: $f_uid"
      exit 2
    fi
    f_run_tootctl "$f_instance" "$f_uid" "$f_mode"
    exit $?
    ;;
  reconcile)
    if [[ -n "$f_uid" ]]
    then
      g_echo_error "reconcile does not take a uid"
      exit 2
    fi
    # Both sources must be readable before any role is changed.
    f_members=$(f_ldap_admins "$f_instance") || exit 1
    f_current=$(f_current_admins "$f_instance") || exit 1
    f_rc=0

    while IFS= read -r f_member
    do
      [[ -n "$f_member" && "$f_member" =~ ^[a-z0-9._-]+$ ]] || continue
      f_run_tootctl "$f_instance" "$f_member" add || f_rc=1
    done <<< "$f_members"

    # Demote local accounts that still have the Admin role but are no longer
    # in the LDAP group. This also repairs changes made while Mastodon was
    # down (the group hook could not reach tootctl back then).
    while IFS= read -r f_admin
    do
      [[ -n "$f_admin" && "$f_admin" =~ ^[a-z0-9._-]+$ ]] || continue
      if ! grep -qx "$f_admin" <<<"$f_members"
      then
        f_run_tootctl "$f_instance" "$f_admin" remove || f_rc=1
      fi
    done <<< "$f_current"

    exit $f_rc
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac
