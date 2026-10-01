#!/bin/bash
# SymbiOS - Ensure SFTP chroot home dirs for media group members.
#
# sshd chdirs to the LDAP homeDirectory after the chroot, so every member
# of the media group needs <media_root>/home/<uid> (mounted as
# /sftp-share/home/<uid> in the container) owned by its LDAP uidNumber.
# Runs after the sftp-share playbook and from the ldap-groups.d hook on
# member-added. Never removes anything: departed members keep their data
# for the admin to clean up, and an unreadable LDAP group changes nothing.
#
# Usage: symbios-sftp-share-homes.sh [uid]

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_ldap_members {
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=media,ou=groups,${f_base_dn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u
}

function f_ldap_uidnumber {
  local f_want="$1"
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "ou=users,${f_base_dn}" "(uid=${f_want})" uidNumber 2>/dev/null \
    | sed -n "s/^uidNumber: //p" | head -1
}

f_only="${1:-}"
f_ensured=0

f_members="$(f_ldap_members)"
if [[ -z "${f_members}" ]]
then
  f_symbios_ldap_init
  if ! f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=media,ou=groups,${f_base_dn}" dn >/dev/null 2>&1
  then
    g_echo_error "LDAP group media not found or not readable, keeping current home dirs"
    exit 1
  fi
  g_echo_note "Media group is empty, nothing to ensure"
  exit 0
fi

while read -r f_uid
do
  [[ -n "${f_uid}" ]] || continue
  if [[ -n "${f_only}" ]] && [[ "${f_uid}" != "${f_only}" ]]
  then
    continue
  fi
  f_number="$(f_ldap_uidnumber "${f_uid}")"
  if [[ -z "${f_number}" ]]
  then
    g_echo_warn "No uidNumber for ${f_uid}, skipping"
    continue
  fi
  f_home="${g_media_root}/home/${f_uid}"
  mkdir -p "${f_home}"
  chown "${f_number}:${g_media_gid}" "${f_home}"
  chmod 0750 "${f_home}"
  f_ensured=$((f_ensured + 1))
done <<<"${f_members}"

g_echo_note "SFTP home dirs ensured (${f_ensured})"
