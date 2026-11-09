#!/bin/bash
# SymbiOS - Sync Matrix (MAS) passwords from LDAP for technical accounts.
#
# Synapse delegates authentication to the Matrix Authentication Service (MAS),
# so a normal Matrix login runs through Authelia (single sign-on, 2FA). A
# technical account (bot, script, monitoring) cannot complete a browser login,
# so it keeps a local MAS password and uses m.login.password through the
# compatibility layer. This bridge keeps that local password equal to the LDAP
# password, so such an account has exactly one secret: changing it in the WebUI
# (Users and Groups) updates LDAP and Matrix together.
#
# Only members of the LDAP group matrix-bots are synced. Every other account
# has no password in MAS and must use the Authelia login - MAS has no per-user
# switch, only the global passwords.enabled, so "no password in the database"
# is what keeps a human account on the SSO path.
#
# Called from the ldap-groups.d hook deployed by services/matrix.yml:
#   matrix-password-sync.hook  password-set (fired by symbios-ldap-user.sh
#                              after every successful password change)
# Args: $1=event (always password-set)
#       $2=uid
#       $3=pwfile (0600 file with the plaintext password, shredded by the
#          caller - never log its content)
#
# Limitations:
# - mas-cli cannot read a password from stdin and the MAS image is distroless
#   (no shell), so the plaintext has to travel as an argument. It is visible in
#   the process list for the milliseconds the call runs (root only, exactly as
#   matrix.init.sh registers the machine accounts). The verification request
#   body goes through a 0600 file instead.
# - A new member of matrix-bots has no MAS account yet: the hook creates it on
#   the first password change (register-user provisions MAS and Synapse, same
#   as matrix.init.sh for mx-admin). LDAP stores only a hash, so adding the
#   user to the group alone cannot create anything - one password set is the
#   trigger. Troubleshooting tip - set the password again via Users and Groups,
#   that re-runs this hook.
# - No service restart: MAS reads the password on the next login.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <event> <uid> [pwfile]

Sync the local Matrix (MAS) password of a technical account from LDAP
(see header comment). Only members of the LDAP group matrix-bots are synced,
everyone else is left alone.

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

function f_matrix_password_sync {
  local f_event="${1:-}"
  local f_uid="${2:-}"
  local f_pwfile="${3:-}"
  local f_mx_dir="${g_services_root}/matrix"
  local f_admin_pw f_ldap_out f_ldap_rc f_members
  local f_pw f_out f_rc f_domain f_body f_resp f_token

  # Only password changes are interesting here
  if [[ "${f_event}" != "password-set" ]]
  then
    return 0
  fi
  if [[ -z "${f_uid}" ]] || [[ -z "${f_pwfile}" ]] || [[ ! -f "${f_pwfile}" ]]
  then
    g_echo_error "Usage: symbios-matrix-password-sync.sh password-set <uid> <pwfile>"
    return 1
  fi

  # Skip silently when Matrix is not installed
  if [[ ! -f "${f_mx_dir}/docker-compose.yml" ]]
  then
    return 0
  fi

  # Never start the stack from a hook
  if [[ "$(docker inspect -f '{{.State.Running}}' matrix-auth 2>/dev/null)" != "true" ]]
  then
    g_echo_note "Matrix authentication service not running, password for '${f_uid}' not synced"
    return 0
  fi

  # LDAP admin password is needed for the membership check
  f_admin_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "${f_admin_pw}" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Members of matrix-bots. A missing group (rc 32) means nobody is a technical
  # account; an unreachable LDAP is an error - never guess here.
  f_ldap_out=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "${f_admin_pw}" \
    -b "cn=matrix-bots,ou=groups,${g_ldap_basedn}" memberUid 2>&1)
  f_ldap_rc=$?
  case "${f_ldap_rc}" in
    0)
      f_members=$(sed -n 's/^memberUid: //p' <<<"${f_ldap_out}" | sort -u)
      ;;
    32)
      f_members=""
      ;;
    *)
      g_echo_error "LDAP query failed (rc ${f_ldap_rc}) - password for '${f_uid}' not synced"
      return 1
      ;;
  esac

  # Humans stay on the Authelia/2FA path and never get a Matrix password
  if ! grep -qxF "${f_uid}" <<<"${f_members}"
  then
    return 0
  fi

  # Set the password. --ignore-complexity: the LDAP password policy already
  # decided about strength; a second, different rule here would only make the
  # sync fail silently for legitimate passwords.
  f_pw=$(cat "${f_pwfile}")
  f_out=$(cd "${f_mx_dir}" && docker compose exec -T matrix-auth \
    mas-cli -c /config/mas-config.yaml manage set-password \
    "${f_uid}" "${f_pw}" --ignore-complexity 2>&1)
  f_rc=$?

  # A member of matrix-bots that never logged in has no MAS account yet:
  # create it now (register-user provisions MAS and Synapse, the same way
  # matrix.init.sh registers mx-admin). It needs Synapse for provisioning.
  if [[ "${f_rc}" -ne 0 ]] && grep -qi 'User not found' <<<"${f_out}"
  then
    g_echo_note "Creating Matrix account '@${f_uid}' (first password set)"
    f_out=$(cd "${f_mx_dir}" && docker compose exec -T matrix-auth \
      mas-cli -c /config/mas-config.yaml manage register-user --yes \
      "${f_uid}" --no-admin --password "${f_pw}" \
      --ignore-password-complexity 2>&1)
    f_rc=$?
    if [[ "${f_rc}" -ne 0 ]]
    then
      g_echo_error "Matrix account for '${f_uid}' could not be created: ${f_out}"
      return 1
    fi
  elif [[ "${f_rc}" -ne 0 ]]
  then
    g_echo_error "Matrix password for '${f_uid}' could not be set: ${f_out}"
    return 1
  fi

  # Verify through the real login path (MAS compat layer), so a broken hash
  # scheme or a deactivated account surfaces here and not in the client. The
  # body carries the plaintext, hence the file instead of the command line.
  f_domain="matrix.${g_base_domain}"
  f_body=$(mktemp)
  export MATRIX_SYNC_UID="${f_uid}"
  export MATRIX_SYNC_PWFILE="${f_pwfile}"
  python3 - "${f_body}" <<'PY'
import json, os, sys
with open(os.environ["MATRIX_SYNC_PWFILE"], encoding="utf-8") as fh:
    password = fh.read().rstrip("\n")
body = {
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": os.environ["MATRIX_SYNC_UID"]},
    "password": password,
    "initial_device_display_name": "symbios-password-sync",
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(body, fh)
PY
  unset MATRIX_SYNC_UID MATRIX_SYNC_PWFILE
  f_resp=$(curl -s --max-time 20 --resolve "${f_domain}:443:127.0.0.1" \
    -H 'Content-Type: application/json' --data "@${f_body}" \
    "https://${f_domain}/_matrix/client/v3/login")
  rm -f "${f_body}"

  if [[ "${f_resp}" != *'"access_token":"'* ]]
  then
    g_echo_error "Matrix password for '${f_uid}' set but login failed: ${f_resp:0:300}"
    return 1
  fi

  # Drop the verification session again so no device piles up per password change
  f_token="${f_resp#*\"access_token\":\"}"
  f_token="${f_token%%\"*}"
  curl -s -o /dev/null --max-time 20 --resolve "${f_domain}:443:127.0.0.1" \
    -X POST -H "Authorization: Bearer ${f_token}" \
    "https://${f_domain}/_matrix/client/v3/logout"

  g_echo_note "Matrix password for '@${f_uid}:${f_domain}' synced from LDAP"
  return 0
}

f_matrix_password_sync "$@"
