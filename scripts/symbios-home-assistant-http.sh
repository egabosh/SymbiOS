#!/bin/bash
# SymbiOS - Configure Home Assistant reverse proxy settings in .storage/http.
#
# Sets use_x_forwarded_for and the Traefik IP in trusted_proxies via the
# home-assistant container. Prints "HTTP config updated" on change
# (Ansible changed_when). Called from services/home-assistant.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <traefik_ip>

Configure the Home Assistant .storage/http reverse proxy settings
(use_x_forwarded_for + trusted_proxies) for the given Traefik IP.
Skips silently when the container is not running.

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

function f_ha_http_config {
  local f_traefik_ip="${1}"
  if [[ -z "${f_traefik_ip}" ]]
  then
    g_echo_error "traefik_ip argument missing"
    return 1
  fi
  docker exec -e TRAEFIK_IP="${f_traefik_ip}" home-assistant python3 -c "
import json, os

path = '/config/.storage/http'
traefik_ip = os.environ['TRAEFIK_IP']

with open(path) as f:
    data = json.load(f)

stable = data['data'].get('stable') or {}
changed = False

if not stable.get('use_x_forwarded_for'):
    stable['use_x_forwarded_for'] = True
    changed = True

trusted = stable.get('trusted_proxies') or []
if traefik_ip not in trusted and traefik_ip + '/32' not in trusted:
    trusted.append(traefik_ip)
    stable['trusted_proxies'] = trusted
    changed = True

if changed:
    stable['error'] = None
    stable['error_message'] = None
    data['data']['stable'] = stable
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('HTTP config updated')
else:
    print('HTTP config already correct')
"
}

f_ha_http_config "${1:-}"
