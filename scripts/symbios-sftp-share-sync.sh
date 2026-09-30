#!/bin/bash
# SymbiOS - Reconcile the sftp-share user list from the LDAP group.
#
# The LDAP group sftp-share-users is the single source of truth for who may
# use the SFTP share. This script makes the SFTPUSERS list in the service env
# file match that group: members are added (with a generated password), and
# entries that are no longer a group member are removed.
#
# There is deliberately no second, independent user list. Adding a user in the
# SymbiOS WebUI (Users & Groups) or on the CLI therefore immediately grants or
# revokes SFTP access, via the group-change hook in ldap-groups.d/.
#
# The sshd config of this service sets PasswordAuthentication no, so the
# generated password only serves to create a valid account. Access is granted
# with an SSH public key that has to be placed in the home directory inside the
# container.

# Source shared libraries (absolute paths so cron and hooks work without PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

# The LDAP group that defines the SFTP user list
g_sftp_group="sftp-share-users"
# Service directory holding the env file
g_sftp_dir="${g_services_root}/sftp-share"
g_sftp_env="${g_sftp_dir}/env"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--dry-run] [--adopt] [--no-restart]

Reconcile the SFTPUSERS list of the sftp-share service with the LDAP group
${g_sftp_group}. Members of the group are provisioned as SFTP users, users that
left the group are removed. Passwords of existing users are never regenerated.

Options:
  --dry-run     Only show what would change
  --adopt       Import the current SFTPUSERS into the LDAP group instead of
                removing users that are not a member yet (for migrations)
  --no-restart  Do not recreate the container afterwards
  -h, --help    Show this help and exit
EOF
}

# Parse options into the f_ prefixed variables used by the sync function
f_dry_run=0
f_adopt=0
f_restart=1

while [[ $# -gt 0 ]]
do
  case "$1" in
    --dry-run)
      f_dry_run=1
      shift
      ;;
    --adopt)
      f_adopt=1
      shift
      ;;
    --no-restart)
      f_restart=0
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage >&2
      exit 1
      ;;
  esac
done

function f_ldap_members {
  local f_uid

  f_symbios_ldap_init

  # Read memberUid of the group; empty when the group does not exist yet
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=${g_sftp_group},ou=groups,${f_base_dn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u
}

function f_ldap_add_member {
  local f_uid="$1"

  f_symbios_ldap_init
  f_ldap_exec ldapmodify -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    <<EOF
dn: cn=${g_sftp_group},ou=groups,${f_base_dn}
changetype: modify
add: memberUid
memberUid: ${f_uid}
EOF
}

# Read the current SFTPUSERS value as "user:password" lines
function f_current_users {
  [[ -f "${g_sftp_env}" ]] || return 0
  sed -n "s/^SFTPUSERS=//p" "${g_sftp_env}" | tr " " "\n" | grep -v "^$"
}

# Write "user:password" lines back as a single SFTPUSERS variable
function f_write_users {
  local f_lines="$1"
  local f_list

  f_list=$(tr "\n" " " <<<"${f_lines}" | sed "s/ *$//")

  # Make sure the line exists before rewriting it
  grep -q "^SFTPUSERS=" "${g_sftp_env}" || echo "SFTPUSERS=" >>"${g_sftp_env}"
  sed -i "s|^SFTPUSERS=.*|SFTPUSERS=${f_list}|" "${g_sftp_env}"

  # The file holds plaintext passwords, keep it readable by root only
  chmod 600 "${g_sftp_env}"
}

# Return the stored password of a user, empty when not present
function f_stored_password {
  local f_user="$1"

  f_current_users | grep "^${f_user}:" | head -1 | cut -d ":" -f2-
}

function f_sftp_share_sync {
  local f_members f_current f_uid f_pass f_line f_lines f_changed f_added f_removed
  local f_known f_new_members f_rc

  f_changed=0
  f_added=0
  f_removed=0
  f_lines=""

  # Nothing to do when the service is not deployed
  if [[ ! -f "${g_sftp_env}" ]]
  then
    g_echo_debug "sftp-share is not installed, nothing to sync"
    return 0
  fi

  f_members=$(f_ldap_members)
  if [[ -z "${f_members}" ]]
  then
    # An empty group and a failed search are indistinguishable here. Only accept
    # the empty result when the group entry itself can be read, otherwise a
    # broken LDAP connection would wipe every SFTP user.
    f_symbios_ldap_init
    if ! f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
      -b "cn=${g_sftp_group},ou=groups,${f_base_dn}" dn >/dev/null 2>&1
    then
      g_echo_error "LDAP group ${g_sftp_group} not found or not readable, keeping current users"
      return 1
    fi
  fi

  f_current=$(f_current_users)

  # Migration path: import the existing local list into the LDAP group so the
  # accounts are not removed by the reconcile below
  if [[ "${f_adopt}" -eq 1 ]]
  then
    while read -r f_line
    do
      [[ -n "${f_line}" ]] || continue
      f_uid="${f_line%%:*}"
      if ! grep -qx "${f_uid}" <<<"${f_members}"
      then
        g_echo_note "Adopting existing SFTP user ${f_uid} into LDAP group ${g_sftp_group}"
        if [[ "${f_dry_run}" -eq 0 ]]
        then
          f_ldap_add_member "${f_uid}" || g_echo_error "Could not add ${f_uid} to ${g_sftp_group}"
        fi
        f_members="${f_uid}"$'\n'"${f_members}"
      fi
    done <<<"${f_current}"
  fi

  # Build the new list: every LDAP member, keeping a known password
  while read -r f_uid
  do
    [[ -n "${f_uid}" ]] || continue
    f_known=0
    if grep -q "^${f_uid}:" <<<"${f_current}"
    then
      f_pass=$(f_stored_password "${f_uid}")
      f_known=1
    else
      g_echo_note "Granting SFTP access to ${f_uid} (member of ${g_sftp_group})"
      f_added=$((f_added + 1))
      f_changed=1
      f_pass=""
    fi

    if [[ -z "${f_pass}" ]]
    then
      f_pass=$(pwgen -s 24 1)
    fi

    if [[ "${f_known}" -eq 0 ]]
    then
      # Show the password once so the admin can hand it to the user
      g_echo_note "Generated password for ${f_uid}: ${f_pass}"
    fi
    f_lines="${f_lines}${f_uid}:${f_pass}"$'\n'
  done <<<"${f_members}"

  # Report users that lost access
  while read -r f_line
  do
    [[ -n "${f_line}" ]] || continue
    f_uid="${f_line%%:*}"
    if ! grep -qx "${f_uid}" <<<"${f_members}"
    then
      g_echo_note "Revoking SFTP access from ${f_uid} (no longer in ${g_sftp_group})"
      f_removed=$((f_removed + 1))
      f_changed=1
    fi
  done <<<"${f_current}"

  if [[ "${f_changed}" -eq 0 ]]
  then
    g_echo_note "SFTP user list is already in sync with ${g_sftp_group}"
    return 0
  fi

  if [[ "${f_dry_run}" -eq 1 ]]
  then
    g_echo_note "Dry run: would write ${f_added} new and remove ${f_removed} user(s)"
    return 0
  fi

  f_write_users "${f_lines}"
  g_echo_note "SFTP user list updated (${f_added} added, ${f_removed} removed)"

  # Recreate the container so the new accounts exist inside it
  if [[ "${f_restart}" -eq 1 ]]
  then
    g_echo_note "Recreating sftp-share container"
    docker compose -f "${g_sftp_dir}/docker-compose.yml" up -d --force-recreate
    f_rc=$?
    if [[ ${f_rc} -ne 0 ]]
    then
      g_echo_error "Failed to recreate the sftp-share container"
      return 1
    fi
  fi

  return 0
}

f_sftp_share_sync
