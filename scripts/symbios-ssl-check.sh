#!/bin/bash
# SymbiOS - Check for a valid SSL certificate of the domain
# Let's Encrypt only issues a certificate via the HTTP-01 challenge when the
# server is reachable from the internet (the ACME server must reach it on port
# 80). A valid certificate therefore proves external reachability, which is why
# this check replaces the old external port probe. No third-party service is
# used; the certificate is fetched directly from the local Traefik instance.
#
# Usage: symbios-ssl-check.sh [-d|--domain <domain>]
#   -d, --domain <domain>   Domain to check (default: base_domain from inventory.yml)
#   -h, --help              Show this help
#
# Output: JSON on stdout, exit 0 only if all hosts have a valid certificate.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_domain=""
g_trae_ip=""

function f_usage {
  echo "Usage: $0 [-d|--domain <domain>]"
  echo "  -d, --domain <domain>   Domain to check (default: base_domain from inventory.yml)"
  echo "  -h, --help              Show this help"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]
do
  case "$1" in
    -d|--domain)
      g_domain="$2"
      shift 2
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      f_usage >&2
      exit 1
      ;;
  esac
done

# Read base_domain from inventory.yml if not given on the command line
function f_load_domain {
  if [[ -n "$g_domain" ]]
  then
    return 0
  fi

  if [[ ! -f "$g_inventory" ]]
  then
    f_json_error "Inventory not found: ${g_inventory}"
  fi

  g_domain=$(f_symbios_var base_domain "")
  if [[ -z "$g_domain" ]]
  then
    f_json_error "base_domain not found in ${g_inventory}"
  fi
}

# Determine the Traefik container address (loopback fallback)
function f_traefik_ip {
  g_trae_ip=$(docker inspect symbios-base-traefik --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
  if [[ -z "$g_trae_ip" ]]
  then
    g_trae_ip="127.0.0.1"
  fi
}

# Fetch and validate the certificate Traefik serves for one hostname.
# Sets g_cert_ok (true/false) and g_cert_detail (reason or expiry date).
function f_check_host {
  local f_host="$1"
  local f_pem f_end

  g_cert_ok=false
  g_cert_detail=""

  f_pem=$(echo | timeout 10 openssl s_client -connect "${g_trae_ip}:443" -servername "$f_host" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null)
  if [[ -z "$f_pem" ]]
  then
    g_cert_detail="no certificate served for ${f_host} (the service may not be configured for this hostname yet)"
    return 0
  fi

  # -checkend 0 exits non-zero when the certificate has expired
  if ! echo | timeout 10 openssl s_client -connect "${g_trae_ip}:443" -servername "$f_host" 2>/dev/null | openssl x509 -noout -checkend 0 >/dev/null 2>&1
  then
    g_cert_detail="certificate for ${f_host} is expired"
    return 0
  fi

  if ! echo "$f_pem" | grep -q "DNS:${f_host}"
  then
    g_cert_detail="certificate for ${f_host} is not valid for this hostname"
    return 0
  fi

  g_cert_ok=true
  f_end=$(echo "$f_pem" | grep 'notAfter=' | cut -d= -f2)
  g_cert_detail="valid until ${f_end}"
}

# --- Main ---

g_lockfile

f_load_domain
f_traefik_ip

g_hosts_json=""
g_first=true
g_all_ok=true

for f_host in "$g_domain" "auth.${g_domain}" "traefik.${g_domain}"
do
  f_check_host "$f_host"

  [[ "$g_cert_ok" == true ]] || g_all_ok=false

  if [[ "$g_first" == true ]]
  then
    g_first=false
    g_hosts_json="["
  else
    g_hosts_json+=","
  fi
  g_hosts_json+="{\"host\":$(echo "$f_host" | f_json_escape),\"ok\":${g_cert_ok},\"detail\":$(echo "$g_cert_detail" | f_json_escape)}"
done
g_hosts_json+="]"

# Build human-readable summary
if [[ "$g_all_ok" == true ]]
then
  g_summary="Valid SSL certificates exist for ${g_domain}. They are only issued by Let's Encrypt via the HTTP challenge when the server is reachable from the internet, so the server is reachable from outside."
else
  g_summary="No valid SSL certificate for ${g_domain}. Certificates are issued by Let's Encrypt only when the server is reachable from the internet (HTTP challenge on port 80). Check that DNS points to this server and that the router forwards ports 80 and 443 - note that ISPs with CGNAT may block inbound connections."
fi

printf '{"ok":%s,"domain":%s,"hosts":%s,"summary":%s}\n' \
  "$g_all_ok" \
  "$(echo "$g_domain" | f_json_escape)" \
  "$g_hosts_json" \
  "$(echo "$g_summary" | f_json_escape)"

if [[ "$g_all_ok" == true ]]
then
  exit 0
else
  exit 1
fi
