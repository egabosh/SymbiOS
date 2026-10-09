#!/bin/bash
# SymbiOS - Persist the mailcow identity_provider (OIDC) configuration.
#
# Writes the generic-oidc identity provider rows into the mailcow MySQL
# database (INSERT ... ON DUPLICATE KEY UPDATE, always yields a working
# SSO setup). Secrets (DB credentials, OIDC client secret) are read from
# files inside the script and never travel as argv. The Ansible task uses
# no_log: true. Called from services/mailcow.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <mailcow_root> <base_domain> <service_domain>

Persist the mailcow identity_provider OIDC configuration for the given
domains. DB credentials come from <mailcow_root>/mailcow.conf, the OIDC
client secret from <mailcow_root>/oidc_password. Secrets never appear
in argv or logs.

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

function f_mailcow_idp {
  local f_root="${1}" f_base_domain="${2}" f_service_domain="${3}"
  local f_secret f_mysql f_row f_key f_val
  if [[ -z "${f_root}" || -z "${f_base_domain}" || -z "${f_service_domain}" ]]
  then
    g_echo_error "usage: $(basename "$0") <mailcow_root> <base_domain> <service_domain>"
    return 1
  fi
  set -e
  . "${f_root}/mailcow.conf"
  f_secret=$(cat "${f_root}/oidc_password")
  f_mysql="docker exec -i $(docker ps -qf name=mysql-mailcow) mysql -u${DBUSER} -p${DBPASS} ${DBNAME} -N -e"
  for f_row in \
    "authsource|generic-oidc" \
    "authorize_url|https://auth.${f_base_domain}/api/oidc/authorization" \
    "token_url|https://auth.${f_base_domain}/api/oidc/token" \
    "userinfo_url|https://auth.${f_base_domain}/api/oidc/userinfo" \
    "client_id|mailcow" \
    "client_secret|${f_secret}" \
    "redirect_url|https://${f_service_domain}" \
    "client_scopes|openid profile email" \
    "default_template|Default" \
    "templates|[\"Default\"]" \
    "mappers|[\"mailcow_template\"]" \
    "login_provisioning|1" \
    "ignore_ssl_error|0"
  do
    f_key="${f_row%%|*}"
    f_val="${f_row#*|}"
    ${f_mysql} "INSERT INTO identity_provider (\`key\`, \`value\`) VALUES ('${f_key}', '${f_val}') ON DUPLICATE KEY UPDATE \`value\`=VALUES(\`value\`);"
  done
}

f_mailcow_idp "${1:-}" "${2:-}" "${3:-}"
