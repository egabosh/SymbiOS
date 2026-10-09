#!/bin/bash
# SymbiOS - LDAP offline ACL import for the sftp-reader bind account.
#
# cn=config has no live write access, so the sftp-reader rules are patched
# into slapd.d while openldap is stopped. Two subcommands, called from
# base-services/ldap.yml (stop/start/wait stay in the playbook):
#   rewrite    patch olcDatabase={1}mdb.ldif (prints CHANGED|UNCHANGED)
#   add-reader create the sftp-reader bind account (idempotent, ignores
#              "already exists" - the playbook gates on the ldapsearch
#              check anyway). Admin password via LDAP_ADMIN_PW env (never
#              argv); the task keeps no_log: true.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <rewrite|add-reader> [options]

  rewrite --ldif FILE --basedn DN
      Replace the old {3} catch-all with the sftp-reader {3}/{4}/{5} rules
      and renumber the old catch-all to {6}. Prints CHANGED or UNCHANGED.

  add-reader --basedn DN --pw-file FILE
      Create cn=sftp-reader (generates FILE with a 32-char password when
      missing, like the ansible password lookup). Admin password via
      LDAP_ADMIN_PW environment. Must run in the LDAP compose dir.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_ldap_rewrite {
  local f_ldif="" f_base=""
  while [[ $# -gt 0 ]]
  do
    case "${1}" in
      --ldif) f_ldif="${2}"; shift 2;;
      --basedn) f_base="${2}"; shift 2;;
      *) g_echo_error "unknown option: ${1}"; return 1;;
    esac
  done
  if [[ -z "${f_ldif}" || -z "${f_base}" ]]
  then
    g_echo_error "rewrite needs --ldif/--basedn"
    return 1
  fi
  LDIF_PATH="${f_ldif}" LDAP_BASEDN="${f_base}" python3 - <<'PYEOF'
import os, sys
path = os.environ["LDIF_PATH"]
base = os.environ["LDAP_BASEDN"]
q = chr(34)
with open(path) as fh:
    content = fh.read()
old = [l for l in content.split('\n') if l.startswith('olcAccess: {3}to *')]
if not old:
    print('UNCHANGED')
    sys.exit(0)
# Folded continuation lines (leading space) belong to the rule
lines = content.split('\n')
idx = lines.index(old[0])
end = idx + 1
while end < len(lines) and lines[end].startswith(' '):
    end += 1
oldblock = '\n'.join(lines[idx:end])
attrs = 'entry,uid,cn,objectClass,uidNumber,gidNumber,homeDirectory,loginShell,sshPublicKey,memberUid'
new3 = ('olcAccess: {3}to attrs=' + attrs
        + ' by self read by dn=' + q + 'cn=sftp-reader,' + base + q
        + ' read by dn=' + q + 'cn=readuser,' + base + q + ' read by * none')
ou4 = ('olcAccess: {4}to dn.base=' + q + 'ou=users,' + base + q
       + ' by self read by dn=' + q + 'cn=sftp-reader,' + base + q
       + ' read by dn=' + q + 'cn=readuser,' + base + q + ' read by * none')
ou5 = ('olcAccess: {5}to dn.base=' + q + 'ou=groups,' + base + q
       + ' by self read by dn=' + q + 'cn=sftp-reader,' + base + q
       + ' read by dn=' + q + 'cn=readuser,' + base + q + ' read by * none')
content = content.replace(oldblock, new3 + '\n' + ou4 + '\n' + ou5, 1)
content = content.replace('olcAccess: {4}to *', 'olcAccess: {6}to *', 1)
with open(path, 'w') as fh:
    fh.write(content)
print('CHANGED')
PYEOF
}

function f_ldap_add_reader {
  local f_base="" f_pwfile=""
  while [[ $# -gt 0 ]]
  do
    case "${1}" in
      --basedn) f_base="${2}"; shift 2;;
      --pw-file) f_pwfile="${2}"; shift 2;;
      *) g_echo_error "unknown option: ${1}"; return 1;;
    esac
  done
  if [[ -z "${f_base}" || -z "${f_pwfile}" ]]
  then
    g_echo_error "add-reader needs --basedn/--pw-file"
    return 1
  fi
  if [[ -z "${LDAP_ADMIN_PW:-}" ]]
  then
    g_echo_error "LDAP_ADMIN_PW environment missing"
    return 1
  fi
  if [[ ! -f "${f_pwfile}" ]]
  then
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32 > "${f_pwfile}"
    chmod 600 "${f_pwfile}"
  fi
  docker compose exec -T openldap ldapadd -x -H ldap://localhost \
    -D "cn=head-of-ldap,${f_base}" -w "${LDAP_ADMIN_PW}" << EOF
dn: cn=sftp-reader,${f_base}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: sftp-reader
description: Least-privilege bind account for the SFTP container. Do not remove!
userPassword: $(cat "${f_pwfile}")
EOF
}

# Main: dispatch subcommand
f_cmd="${1:-}"
shift || true
case "${f_cmd}" in
  rewrite)
    f_ldap_rewrite "$@"
    ;;
  add-reader)
    f_ldap_add_reader "$@"
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
