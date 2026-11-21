#!/bin/bash
# SymbiOS - Manage per-system LDAP backup users for external Linux Mint hosts.
#
# Every registered system of type linux-mint gets one dedicated LDAP user
# (backup-<id>) in its own group (shared-backup-<id>). The user has a private
# SFTP home below media_root, so a Mint client can only reach its own restic
# repository on port 28. Passwords and public keys are provisioned once and
# kept below the config dir; this script only adds what is missing.
#
# Usage: symbios-sftp-backup-users.sh

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Create the LDAP users, groups, private SFTP homes and password files for all
systems registered as type "linux-mint" in ${g_config_dir}/external-systems.yml.

Input files (both below ${g_config_dir}/services/sftp-share/):
  backup-clients.yml       Mapping <id> -> SSH public key of the Mint client
  backup-passwords/<id>    Restic repository password (created when missing)

The script is idempotent: existing users, groups, keys and passwords are never
overwritten. It prints one status line per system ending in "created" or
"unchanged" so Ansible can detect real changes.

Options:
  -h, --help               Show this help and exit

Exit codes: 0 = ok, 1 = runtime or configuration error, 2 = usage error.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi
f_no_args "$@"

# --- LDAP helpers ------------------------------------------------------------
function f_ldap_attr {
  local f_filter="$1"
  local f_attr="$2"
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -o ldif-wrap=no -H "${f_ldap_uri}" \
    -D "${f_bind_dn}" -y "${f_ldap_pw_file}" \
    -b "ou=users,${f_base_dn}" "${f_filter}" "${f_attr}" 2>/dev/null \
    | sed -n "s/^${f_attr}: //p" | head -1
}

function f_ldap_group_exists {
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -o ldif-wrap=no -H "${f_ldap_uri}" \
    -D "${f_bind_dn}" -y "${f_ldap_pw_file}" \
    -b "ou=groups,${f_base_dn}" "(cn=${1})" cn 2>/dev/null | grep -q '^cn:'
}

function f_ldap_group_has_user {
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -o ldif-wrap=no -H "${f_ldap_uri}" \
    -D "${f_bind_dn}" -y "${f_ldap_pw_file}" \
    -b "cn=${1},ou=groups,${f_base_dn}" "(objectClass=posixGroup)" memberUid 2>/dev/null \
    | sed -n 's/^memberUid: //p' | grep -qx "${2}"
}

function f_fail {
  g_echo_error "$1"
  exit "${2:-1}"
}

# --- configuration -----------------------------------------------------------
g_sftp_config="${g_config_dir}/services/sftp-share"
g_clients_file="${g_sftp_config}/backup-clients.yml"
g_password_dir="${g_sftp_config}/backup-passwords"
g_registry="${g_config_dir}/external-systems.yml"

# Hosts without registered external systems have no registry file yet. That
# is the same as an empty list, not a failed playbook.
if [[ ! -r "${g_registry}" ]]
then
  g_echo_note "No external systems registry at ${g_registry} - nothing to do"
  exit 0
fi
command -v yq > /dev/null || f_fail "yq is required to read ${g_registry}"

g_ids="$(yq -r '.external_systems[] | select(.type == "linux-mint") | .id' \
  "${g_registry}" 2>/dev/null | sort -u)"
if [[ -z "${g_ids}" ]]
then
  g_echo_note "No Linux Mint systems registered - nothing to do"
  exit 0
fi

# --- provision one user per system -------------------------------------------
for f_id in ${g_ids}
do
  [[ "${f_id}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || f_fail "Invalid system id in ${g_registry}: ${f_id}"

  f_uid="backup-${f_id}"
  f_group="shared-backup-${f_id}"
  f_password_file="${g_password_dir}/${f_id}"
  f_changed=0

  if ! f_ldap_group_exists "${f_group}"
  then
    "${g_script_dir}/symbios-ldap-groups.sh" --create --name "${f_group}" > /dev/null \
      || f_fail "Could not create LDAP group ${f_group}"
    f_changed=1
  fi

  # The password is a fixed prefix plus random hex: it always satisfies the
  # global medium policy (length, letter, digit, special character).
  if [[ ! -s "${f_password_file}" ]]
  then
    mkdir -p "${g_password_dir}" || f_fail "Could not create ${g_password_dir}"
    umask 077
    printf 'Bk%s!' "$(openssl rand -hex 16)" > "${f_password_file}"
    chmod 600 "${f_password_file}"
    f_changed=1
  fi

  if [[ -z "$(f_ldap_attr "(uid=${f_uid})" uid)" ]]
  then
    # symbios-ldap-user.sh consumes the password file passed to it, so give it
    # a throwaway copy and keep the persistent one for the next setup.
    f_tmp_password="$(mktemp)" || f_fail "Could not create a temporary password file"
    cp "${f_password_file}" "${f_tmp_password}" || f_fail "Could not copy the password file"
    chmod 600 "${f_tmp_password}"
    if ! "${g_script_dir}/symbios-ldap-user.sh" --create --uid "${f_uid}" \
        --displayname "Backup ${f_id}" --group "${f_group}" \
        --password-file "${f_tmp_password}" > /dev/null
    then
      rm -f "${f_tmp_password}"
      f_fail "Could not create LDAP user ${f_uid}"
    fi
    f_changed=1
  fi

  if ! f_ldap_group_has_user "${f_group}" "${f_uid}"
  then
    "${g_script_dir}/symbios-ldap-groups.sh" --add-user \
      --name "${f_group}" --uid "${f_uid}" > /dev/null \
      || f_fail "Could not add ${f_uid} to ${f_group}"
    f_changed=1
  fi

  # The entrypoint and the group hook create homes for members; call the helper
  # explicitly as well so the private directory exists even when the hook was
  # missed (e.g. the user was created with --group).
  "${g_script_dir}/symbios-sftp-share-homes.sh" "${f_uid}" > /dev/null \
    || f_fail "Could not ensure the SFTP home for ${f_uid}"

  if [[ -r "${g_clients_file}" ]]
  then
    # yq v4 has no --arg; the id was validated above and is safe to inline.
    f_key="$(yq -r ".[\"${f_id}\"] // \"\"" "${g_clients_file}" 2>/dev/null)"
    if [[ -n "${f_key}" ]]
    then
      if [[ "$(f_ldap_attr "(uid=${f_uid})" sshPublicKey)" != "${f_key}" ]]
      then
        "${g_script_dir}/symbios-ldap-user.sh" --modify --uid "${f_uid}" \
          --ssh-key "${f_key}" > /dev/null \
          || f_fail "Could not set the SSH key for ${f_uid}"
        f_changed=1
      fi
    else
      g_echo_warn "No SSH public key for ${f_id} in ${g_clients_file}"
    fi
  else
    g_echo_warn "Public key file not found: ${g_clients_file}"
  fi

  if (( f_changed ))
  then
    g_echo "${f_id}: created"
  else
    g_echo "${f_id}: unchanged"
  fi
done

f_audit_event cli sftp-backup-users-provision "systems=$(printf '%s\n' "${g_ids}" | wc -l)"
