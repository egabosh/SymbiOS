#!/bin/bash
# SymbiOS - Sync Navidrome API passwords from LDAP.
#
# Subsonic clients (Supersonic, DSub, Feishin, ...) cannot do the browser
# SSO flow, so /rest/* bypasses Authelia (see services/navidrome.yml) and
# Navidrome checks its own local password there. This bridge keeps that
# local password equal to the LDAP password, so users need only one.
#
# Called from the ldap-groups.d hook deployed by services/navidrome.yml:
#   navidrome-password-sync.hook  password-set (fired by
#                                 symbios-ldap-user.sh after every
#                                 successful password change)
# Args: $1=event (always password-set)
#       $2=uid
#       $3=pwfile (0600 file with the plaintext password, shredded by the
#          caller - never log its content)
#
# - Only members of navidrome-users/navidrome-admins are synced, rest no-op.
# - The Navidrome row must exist (first browser login creates it via the
#   Remote-User header); missing rows are skipped with a note, the admin
#   sets the password once via navidrome-passwd.sh after first login.
# - The container must be running; the hook never starts it (a start
#   without the /music mount would purge the track index, see 7.8).
# - Browser SSO is unaffected (Remote-User header wins over passwords).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <event> <uid> [pwfile]

Sync Navidrome API passwords from LDAP (see header comment).

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

function f_navidrome_password_sync {
  local f_event="${1:-}"
  local f_uid="${2:-}"
  local f_pwfile="${3:-}"
  local f_admin_pw f_members f_pw f_domain

  if [[ "${f_event}" != "password-set" ]]
  then
    return 0
  fi
  if [[ -z "${f_uid}" ]]
  then
    g_echo_error "Usage: symbios-navidrome-password-sync.sh password-set <uid> <pwfile>"
    return 1
  fi
  if [[ -z "${f_pwfile}" ]] || [[ ! -f "${f_pwfile}" ]]
  then
    g_echo_error "password-set for '${f_uid}' without readable password file"
    return 1
  fi

  # Skip silently when Navidrome is not installed
  if [[ ! -f "${g_services_root}/navidrome/docker-compose.yml" ]]
  then
    return 0
  fi

  # Never start the container from a hook (see header comment)
  if [[ -z "$(docker ps -q --filter 'name=^navidrome$' 2>/dev/null)" ]]
  then
    g_echo_note "Navidrome not running, password for '${f_uid}' not synced"
    return 0
  fi

  # LDAP admin password is needed for the membership check
  f_admin_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "${f_admin_pw}" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Current members of both navidrome groups (empty when group missing)
  f_members=$(for f_group in navidrome-users navidrome-admins
  do
    docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
      -D "cn=head-of-ldap,${g_ldap_basedn}" -w "${f_admin_pw}" \
      -b "cn=${f_group},ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
      | sed -n "s/^memberUid: //p"
  done | sort -u)

  # Only sync passwords of navidrome members, ignore everyone else
  if ! printf '%s\n' "${f_members}" | grep -qx "${f_uid}"
  then
    return 0
  fi

  # The Navidrome row appears at first SSO login; without it there is
  # nothing to set the password on (admin uses navidrome-passwd.sh later)
  if ! docker exec navidrome /app/navidrome user list \
      --datafolder /data --nobanner 2>/dev/null \
      | awk -F, 'NR>1 {print $2}' | grep -qx "${f_uid}"
  then
    g_echo_note "Navidrome user '${f_uid}' has no row yet (first browser login creates it)"
    return 0
  fi

  # --set-password needs a TTY (term.ReadPassword): fake one with script(1).
  # The password travels via stdin only, never via argv or logs. Live write
  # is safe (SQLite WAL, server keeps running).
  f_pw=$(cat "${f_pwfile}")
  printf '%s\n%s\n' "${f_pw}" "${f_pw}" | script -qec \
    "docker exec -i -t navidrome /app/navidrome user edit -u '${f_uid}' --set-password --datafolder /data --nobanner" \
    /dev/null >/dev/null 2>&1 || {
    g_echo_error "Navidrome password for '${f_uid}' could not be set"
    return 1
  }

  # Verify through the real path (Traefik + /rest bypass). The Subsonic
  # protocol carries the password in the query string by design, same as
  # every client request; nothing extra is logged here.
  f_domain="navidrome.${g_base_domain}"
  if curl -sk --resolve "${f_domain}:443:127.0.0.1" \
      "https://${f_domain}/rest/ping.view?v=1.16.1&c=pw-sync&u=${f_uid}&p=${f_pw}" \
      2>/dev/null | grep -q 'status="ok"'
  then
    g_echo_note "Navidrome password for '${f_uid}' synced"
    return 0
  fi
  g_echo_error "Navidrome password for '${f_uid}' set but API verification failed"
  return 1
}

f_navidrome_password_sync "$@"
