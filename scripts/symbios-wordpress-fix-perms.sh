#!/bin/bash
# SymbiOS - Repair WordPress instance file ownership and SFTP ACLs.
#
# WordPress runs as www-data (33:33) and needs ownership of its docroot
# (files 660, dirs 2770) for direct updates. SFTP-side writers reach the
# docroot through the instance LDAP group (wordpress-<name>) granted via
# access + default ACL; ownership is never transferred to them. When edits
# drifted (e.g. core touched via SFTP), this script restores the target
# state and re-applies the SFTP ACLs. Also refreshes the playbook marker
# so wordpress.yml does not repeat its one-time recursive pass.
#
# Usage: symbios-wordpress-fix-perms.sh <name>...
# Runs on the SymbiOS host as root (chown + setfacl need it).

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_group_gid {
  local f_group="$1"
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=${f_group},ou=groups,${f_base_dn}" gidNumber 2>/dev/null \
    | sed -n "s/^gidNumber: //p" | head -1
}

if [[ $# -lt 1 ]]
then
  g_echo_error "Usage: $(basename "$0") <name>..."
  exit 1
fi

# www-data inside the WordPress containers (numeric: host NSS may not
# resolve container-local names, LDAP names need no resolution at all).
f_www_uid=33
f_www_gid=33

f_rc=0
for f_name in "$@"
do
  f_dir="${g_services_root}/wordpress/${f_name}-data"
  f_group="wordpress-${f_name}"
  if [[ ! -d "${f_dir}" ]]
  then
    g_echo_error "No such instance dir ${f_dir}, skipping ${f_name}"
    f_rc=1
    continue
  fi
  # Ownership back to www-data (group 33 keeps WordPress group access
  # exactly as the container entrypoint leaves it).
  chown -R "${f_www_uid}:${f_www_gid}" "${f_dir}"
  find "${f_dir}" -type d -exec chmod 2770 {} +
  find "${f_dir}" -type f -exec chmod 660 {} +
  # SFTP gate: instance LDAP group via numeric GID (setfacl cannot rely
  # on host NSS for LDAP names).
  f_gid="$(f_group_gid "${f_group}")"
  if [[ -z "${f_gid}" ]]
  then
    g_echo_warn "LDAP group ${f_group} not found, ownership fixed but no SFTP ACL applied"
    continue
  fi
  setfacl -R -m "g:${f_gid}:rwx" "${f_dir}"
  setfacl -R -d -m "g:${f_gid}:rwx" "${f_dir}"
  touch "${g_services_root}/wordpress/.sftp-acl-${f_name}"
  g_echo_note "Permissions fixed for ${f_name} (group ${f_group})"
done
exit "${f_rc}"
