#!/bin/bash
# SymbiOS - Sync rest-server (S3) users from LDAP.
#
# Keeps the rest-server htpasswd list in sync with the LDAP group
# `s3-users` and with WebUI/CLI password changes. rest-server cannot talk
# LDAP itself (htpasswd file only) and restic clients cannot do OIDC, so
# this hook bridge is the SymbiOS-standard way to manage S3 access.
#
# Called from two ldap-groups.d hooks deployed by services/s3.yml:
#   s3-user-sync.hook      member-added|member-removed on s3-users
#   s3-password-sync.hook  password-set (fired by symbios-ldap-user.sh
#                          after every successful password change)
# Args: $1=event (member-added|member-removed|password-set)
#       $2=uid
#       $3=pwfile (password-set only: 0600 file with the plaintext
#          password, shredded by the caller - never log its content)
#
# - member-added:    ensure htpasswd entry (random password when missing;
#                    the real password arrives via the next password-set).
#                    Repo data dir is created on first client write.
# - member-removed:  delete htpasswd entry (login blocked immediately).
#                    Repo data is KEPT for the admin to archive or hand over.
# - password-set:    set htpasswd password, but only when the uid is a
#                    member of s3-users (no-op otherwise).
# Group create/delete events are ignored (nothing to provision on an
# empty group; entries survive a group deletion for the admin to clean).
#
# rest-server reads the htpasswd file only once at startup, so every
# change below ends with a container restart (seconds of interruption,
# group/password changes are rare admin events).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <event> <uid> [pwfile]

Sync rest-server htpasswd users from LDAP (see header comment).

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

function f_s3_user_sync {
  local f_event="${1:-}"
  local f_uid="${2:-}"
  local f_pwfile="${3:-}"
  local f_htpasswd="${g_services_root}/s3/data/.htpasswd"
  local f_pw f_admin_pw f_members

  if [[ -z "${f_event}" ]] || [[ -z "${f_uid}" ]]
  then
    g_echo_error "Usage: symbios-s3-user-sync.sh <event> <uid> [pwfile]"
    return 1
  fi

  # Skip silently when S3 is not installed
  if [[ ! -f "${f_htpasswd}" ]]
  then
    return 0
  fi
  command -v htpasswd >/dev/null 2>&1 || return 0

  # LDAP admin password is needed for the membership check
  f_admin_pw=$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null)
  if [[ -z "${f_admin_pw}" ]]
  then
    g_echo_error "No LDAP admin password found in ${g_config_dir}/.ldap_admin_pw"
    return 1
  fi

  # Current members of s3-users (empty when the group does not exist yet)
  f_members=$(docker exec symbios-base-webui ldapsearch -x -H ldap://symbios-base-ldap \
    -D "cn=head-of-ldap,${g_ldap_basedn}" -w "${f_admin_pw}" \
    -b "cn=s3-users,ou=groups,${g_ldap_basedn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u)

  case "${f_event}" in
    member-added)
      if grep -q "^${f_uid}:" "${f_htpasswd}" 2>/dev/null
      then
        g_echo_note "S3 user '${f_uid}' already has an htpasswd entry"
        return 0
      fi
      # Random password until the real one arrives via password-set
      f_pw=$(pwgen -s 32 1)
      htpasswd -B -b "${f_htpasswd}" "${f_uid}" "${f_pw}" 2>/dev/null
      chmod 640 "${f_htpasswd}"
      chown root:docker "${f_htpasswd}"
      f_s3_restart
      g_echo_note "S3 user '${f_uid}' created with a random password (set the real one via Users and Groups)"
      ;;
    member-removed)
      if ! grep -q "^${f_uid}:" "${f_htpasswd}" 2>/dev/null
      then
        return 0
      fi
      sed -i "/^${f_uid}:/d" "${f_htpasswd}"
      f_s3_restart
      g_echo_note "S3 user '${f_uid}' removed (repo data kept)"
      ;;
    password-set)
      if [[ -z "${f_pwfile}" ]] || [[ ! -f "${f_pwfile}" ]]
      then
        g_echo_error "password-set for '${f_uid}' without readable password file"
        return 1
      fi
      # Only sync passwords of s3-users members, ignore everyone else
      if ! printf '%s\n' "${f_members}" | grep -qx "${f_uid}"
      then
        return 0
      fi
      # -i reads the password from stdin (never visible in ps)
      htpasswd -B -i "${f_htpasswd}" "${f_uid}" < "${f_pwfile}" 2>/dev/null
      chmod 640 "${f_htpasswd}"
      chown root:docker "${f_htpasswd}"
      f_s3_restart
      g_echo_note "S3 password for '${f_uid}' synced"
      ;;
    *)
      # group-created, group-deleted and anything unknown: nothing to do
      return 0
      ;;
  esac
  return 0
}

# Restart the rest-server so it picks up the changed htpasswd file
# (it reads the file only once at startup). Best-effort: never fail
# the caller when the stack is not there (yet).
function f_s3_restart {
  local f_compose="${g_services_root}/s3/docker-compose.yml"
  [[ -f "${f_compose}" ]] || return 0
  docker compose -f "${f_compose}" restart s3 >/dev/null 2>&1 || true
}

f_s3_user_sync "$@"
