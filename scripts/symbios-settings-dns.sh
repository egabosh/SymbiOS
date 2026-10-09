#!/bin/bash
# SymbiOS - Manage DNS settings (deSEC DynDNS or self-managed domain).
#
# Settings CLI-first architecture: the WebUI page /settings/dns/ is a thin
# wrapper around this script, which owns validation and the inventory.yml
# write. The inventory write goes through symbios-inventory.py (merge, one
# transaction, real booleans for dns_configured).
#
# Only the stored configuration lives here. Live deSEC API probes (domain
# availability, API-key test, registration, captcha, host status, public IP
# detection) stay Python in the WebUI container - they need no host access
# and Bash is worse at HTTP+JSON (explicit non-goal, see AGENTS.md).
#
# Secrets (ddns_apikey) MUST come via --json-stdin, never as argv (visible
# in ps). There is deliberately no --apikey flag.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS DNS settings (deSEC DynDNS or a self-managed domain).
The DDNS host (or self-managed domain) becomes base_domain, the shared
parent domain for Traefik Host rules and the Authelia session cookie.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json; the API
                                  key value is never printed, only whether
                                  one is set)
  set --mode desec --host HOST [--ipv6 MODE | --json-stdin] [--check]
                                  deSEC mode: HOST is normalized (lowercase,
                                  .dedyn.io suffix ensured) and becomes
                                  base_domain. --json-stdin reads
                                  {"ddns_host":.., "ddns_apikey":..,
                                  "ddns_ipv6":..} from stdin (REQUIRED for
                                  the API key). --check changes nothing.
  set --mode self-managed --domain DOMAIN [--check]
                                  Self-managed mode: DOMAIN becomes
                                  base_domain (must be a valid FQDN).
  remove [--check]                Clear the DNS configuration (API key,
                                  host, mode) and reset base_domain to the
                                  symbios.local fallback. --check changes
                                  nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (dns-changed / dns-unchanged).

Examples:
  $(basename "$0") get
  echo '{"ddns_host":"myhost","ddns_apikey":"token..","ddns_ipv6":""}' \\
    | $(basename "$0") set --mode desec --json-stdin
  $(basename "$0") set --mode self-managed --domain example.com
  $(basename "$0") remove

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

# Normalize a deSEC host: lowercase, strip, ensure the .dedyn.io suffix
# (same rules the WebUI applied before).
function f_normalize_desec_host {
  local f_h="$1"
  f_h="${f_h,,}"
  f_h="${f_h#"${f_h%%[![:space:]]*}"}"
  f_h="${f_h%"${f_h##*[![:space:]]}"}"
  f_h="${f_h%.}"
  if [[ "${f_h}" == *.dedyn.io ]]
  then
    f_h="${f_h%.dedyn.io}"
  fi
  if [[ -z "${f_h}" ]]
  then
    echo ""
    return 0
  fi
  echo "${f_h}.dedyn.io"
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|remove|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "dns_mode", "type": "select", "label": "DNS mode",
   "required": true, "default": "desec", "secret": false,
   "options": ["desec", "self-managed"]},
  {"name": "ddns_host", "type": "text", "label": "deSEC hostname",
   "required": false, "default": "", "secret": false,
   "placeholder": "myhost.dedyn.io", "needs_mode": "desec"},
  {"name": "ddns_apikey", "type": "password", "label": "deSEC API token",
   "required": false, "default": "", "secret": true, "needs_mode": "desec"},
  {"name": "ddns_ipv6", "type": "select", "label": "IPv6 mode",
   "required": false, "default": "", "secret": false, "needs_mode": "desec"},
  {"name": "self_domain", "type": "text", "label": "Domain",
   "required": false, "default": "", "secret": false,
   "placeholder": "example.com", "needs_mode": "self-managed"}
]
EOF
  exit 0
fi

f_cur_mode="$(f_symbios_var dns_mode "")"
if [[ -z "${f_cur_mode}" ]]
then
  # Backward compatibility (same as the WebUI): a set ddns_host implies
  # desec mode.
  if [[ -n "$(f_symbios_var ddns_host "")" ]]
  then
    f_cur_mode="desec"
  fi
fi
f_cur_host="$(f_symbios_var ddns_host "")"
f_cur_ipv6="$(f_symbios_var ddns_ipv6 "")"
f_cur_domain="$(f_symbios_var base_domain "")"
f_cur_configured="$(f_symbios_var dns_configured "")"
if [[ "${f_cur_configured}" == "True" || "${f_cur_configured}" == "true" ]]
then
  f_cur_configured="true"
else
  f_cur_configured="false"
fi
f_cur_key_set="no"
[[ -n "$(f_symbios_var ddns_apikey "")" ]] && f_cur_key_set="yes"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"dns_mode": %s, "ddns_host": %s, "ddns_apikey_set": %s, "ddns_ipv6": %s, "base_domain": %s, "dns_configured": %s}\n' \
      "$(printf '%s' "${f_cur_mode}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_host}" | f_json_escape)" \
      "$([[ "${f_cur_key_set}" == "yes" ]] && echo "true" || echo "false")" \
      "$(printf '%s' "${f_cur_ipv6}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_domain}" | f_json_escape)" \
      "${f_cur_configured}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "dns_mode=${f_cur_mode}"
  echo "ddns_host=${f_cur_host}"
  echo "ddns_apikey_set=${f_cur_key_set}"
  echo "ddns_ipv6=${f_cur_ipv6}"
  echo "base_domain=${f_cur_domain}"
  echo "dns_configured=${f_cur_configured}"
  exit 0
fi

# --- subcommands: set / remove ---------------------------------------------------

f_mode=""
f_host=""
f_given_host="no"
f_domain=""
f_ipv6=""
f_given_ipv6="no"
f_new_key=""
f_given_key="no"
f_json_stdin="no"
f_remove="no"
f_check="no"

[[ "${f_command}" == "remove" ]] && f_remove="yes"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_mode="$2"
      shift 2
      ;;
    --mode=*)
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_mode="${1#--mode=}"
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_host="$2"
      f_given_host="yes"
      shift 2
      ;;
    --domain)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_domain="$2"
      shift 2
      ;;
    --ipv6)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_ipv6="$2"
      f_given_ipv6="yes"
      shift 2
      ;;
    --ddns-apikey=*|--apikey|--apikey=*)
      f_ss_fail_validation "ddns_apikey is a secret and must be passed via --json-stdin, never as argv"
      ;;
    --json-stdin)
      [[ "${f_remove}" == "yes" ]] && f_ss_fail_usage
      f_json_stdin="yes"
      shift
      ;;
    --check)
      f_check="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      f_ss_fail_usage
      ;;
  esac
done

if [[ "${f_remove}" == "yes" ]]
then
  f_merge='{"ddns_apikey": "", "ddns_host": "", "ddns_ipv6": "", "dns_mode": "", "dns_configured": false, "base_domain": "symbios.local"}'
else
  [[ -z "${f_mode}" ]] && f_ss_fail_validation "Nothing to set - pass --mode desec|self-managed"

  if [[ "${f_json_stdin}" == "yes" ]]
  then
    f_json="$(cat)"
    if [[ "${f_json}" == *'"ddns_host"'* ]]
    then
      f_host="$(f_json_get "${f_json}" "ddns_host")" || f_host=""
      f_given_host="yes"
    fi
    if [[ "${f_json}" == *'"ddns_apikey"'* ]]
    then
      f_new_key="$(f_json_get "${f_json}" "ddns_apikey")" || f_new_key=""
      f_given_key="yes"
    fi
    if [[ "${f_json}" == *'"ddns_ipv6"'* ]]
    then
      f_ipv6="$(f_json_get "${f_json}" "ddns_ipv6")" || f_ipv6=""
      f_given_ipv6="yes"
    fi
    if [[ "${f_json}" == *'"self_domain"'* ]]
    then
      f_domain="$(f_json_get "${f_json}" "self_domain")" || f_domain=""
    fi
  fi

  case "${f_mode}" in
    desec)
      f_host="$(f_normalize_desec_host "${f_host}")"
      [[ -n "${f_host}" ]] \
        || f_ss_fail_validation "Please enter a deSEC hostname"
      # A dotted host must be a valid FQDN after normalization.
      f_label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
      if [[ ${#f_host} -gt 253 ]] || ! [[ "${f_host}" =~ ^${f_label}(\.${f_label})+$ ]]
      then
        f_ss_fail_validation "Invalid deSEC hostname: ${f_host}"
      fi
      f_merge="$(printf '{"dns_mode": "desec", "ddns_host": %s, "base_domain": %s, "dns_configured": true' \
        "$(printf '%s' "${f_host}" | f_json_escape)" \
        "$(printf '%s' "${f_host}" | f_json_escape)")"
      if [[ "${f_given_key}" == "yes" ]]
      then
        f_merge="${f_merge}, \"ddns_apikey\": $(printf '%s' "${f_new_key}" | f_json_escape)"
      fi
      if [[ "${f_given_ipv6}" == "yes" ]]
      then
        f_merge="${f_merge}, \"ddns_ipv6\": $(printf '%s' "${f_ipv6}" | f_json_escape)"
      fi
      f_merge="${f_merge}}"
      ;;
    self-managed)
      f_domain="${f_domain,,}"
      f_domain="${f_domain#"${f_domain%%[![:space:]]*}"}"
      f_domain="${f_domain%"${f_domain##*[![:space:]]}"}"
      f_domain="${f_domain%.}"
      [[ -n "${f_domain}" ]] || f_ss_fail_validation "Please enter a domain"
      f_label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
      if [[ ${#f_domain} -gt 253 ]] || ! [[ "${f_domain}" =~ ^${f_label}(\.${f_label})+$ ]]
      then
        f_ss_fail_validation "Invalid domain: ${f_domain} (expected a FQDN like example.com)"
      fi
      if [[ "${f_domain}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
      then
        f_ss_fail_validation "Domain must not be an IPv4 address: ${f_domain}"
      fi
      f_merge="$(printf '{"dns_mode": "self-managed", "ddns_apikey": "", "ddns_host": "", "ddns_ipv6": "", "base_domain": %s, "dns_configured": true}' \
        "$(printf '%s' "${f_domain}" | f_json_escape)")"
      ;;
    *)
      f_ss_fail_validation "Invalid --mode: ${f_mode} (expected desec|self-managed)"
      ;;
  esac
fi

# --- transactional write ---------------------------------------------------------

f_ss_merge "${f_merge}" "dns" "${f_check}"
exit 0
