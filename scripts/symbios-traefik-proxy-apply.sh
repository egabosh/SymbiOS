#!/bin/bash
# SymbiOS - Apply Reverse-Proxy forwards (Traefik file provider).
#
# The forward list lives in ${g_config_dir}/traefik/forwards.yml (written by
# the WebUI at /settings/reverse-proxy/). This script validates the file and
# renders one provider snippet per active forward via the playbook
# (hot-reload through Traefik file watching, no restart needed).
#
# Usage:
#   symbios-traefik-proxy-apply.sh
#   symbios-traefik-proxy-apply.sh --import <dir>   (one-time: convert
#       hand-written provider snippets like the migration leftovers into
#       forwards.yml entries; _default.yml and novnc.yml are skipped)

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--import <dir>]

Apply the Reverse-Proxy forwards from ${g_config_dir}/traefik/forwards.yml
via base-services/traefik-proxy.yml.

Options:
  --import <dir>   Convert hand-written Traefik provider snippets (*.yml)
                   into forwards.yml entries and exit
  -h, --help       Show this help and exit
EOF
}

function f_data_file {
  local f_dir="${g_config_dir}/traefik"
  if ! [[ -d "${f_dir}" ]]
  then
    mkdir -p "${f_dir}"
  fi
  echo "${f_dir}/forwards.yml"
}

function f_validate {
  local f_file="$1"
  python3 - "${f_file}" << 'PYEOF'
import re
import sys
import yaml

with open(sys.argv[1]) as f_handle:
    f_data = yaml.safe_load(f_handle) or []
if not isinstance(f_data, list):
    sys.exit('forwards.yml must contain a YAML list')
f_hosts = []
for f_entry in f_data:
    f_name = f_entry.get('name', '?')
    if not re.match(r'^[a-z0-9][a-z0-9-]*$', f_name or ''):
        sys.exit('invalid name: ' + str(f_name))
    f_host = (f_entry.get('host') or '').lower()
    if not re.match(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$', f_host):
        sys.exit('invalid host in ' + f_name + ': ' + str(f_entry.get('host')))
    if f_host in f_hosts:
        sys.exit('duplicate host: ' + f_host)
    f_hosts.append(f_host)
    if f_entry.get('scheme', 'http') not in ('http', 'https'):
        sys.exit('invalid scheme in ' + f_name)
    if not re.match(r'^[A-Za-z0-9.-]+$', f_entry.get('target') or ''):
        sys.exit('invalid target in ' + f_name)
    try:
        f_port = int(f_entry.get('port', 0))
    except (TypeError, ValueError):
        sys.exit('invalid port in ' + f_name)
    if f_port < 1 or f_port > 65535:
        sys.exit('invalid port in ' + f_name)
    if f_entry.get('access', 'open') not in ('open', 'local', 'authelia'):
        sys.exit('invalid access in ' + f_name)
print('forwards.yml valid: ' + str(len(f_data)) + ' entries')
PYEOF
}

function f_import {
  local f_dir="$1"
  local f_file
  f_file="$(f_data_file)"
  python3 - "$1" "${f_file}" << 'PYEOF'
import glob
import os
import re
import sys
import yaml

f_src = sys.argv[1]
f_dst = sys.argv[2]
if os.path.exists(f_dst):
    with open(f_dst) as f_handle:
        f_data = yaml.safe_load(f_handle) or []
else:
    f_data = []
f_known = {str(e.get('host', '')).lower() for e in f_data}
f_added = []
for f_path in sorted(glob.glob(os.path.join(f_src, '*.yml'))):
    f_base = os.path.basename(f_path)
    if f_base in ('_default.yml', 'novnc.yml'):
        continue
    with open(f_path) as f_handle:
        try:
            f_doc = yaml.safe_load(f_handle) or {}
        except yaml.YAMLError as f_err:
            print('skip ' + f_base + ': ' + str(f_err))
            continue
    f_routers = (f_doc.get('http') or {}).get('routers') or {}
    f_services = (f_doc.get('http') or {}).get('services') or {}
    for f_router, f_cfg in f_routers.items():
        f_match = re.search(r'Host\(`([^`]+)`\)', str(f_cfg.get('rule', '')))
        if not f_match:
            continue
        f_host = f_match.group(1).lower()
        if f_host in f_known:
            print('skip ' + f_host + ': already present')
            continue
        f_svc = f_services.get(f_cfg.get('service'), {}) or {}
        f_servers = ((f_svc.get('loadBalancer')) or {}).get('servers') or []
        if not f_servers:
            continue
        f_url = str(f_servers[0].get('url', ''))
        f_m = re.match(r'^(https?)://([^/:]+):(\d+).*$', f_url)
        if not f_m:
            continue
        f_middle = [str(m) for m in (f_cfg.get('middlewares') or [])]
        if any('allowlocalipsonly' in m for m in f_middle):
            f_access = 'local'
        else:
            f_access = 'open'
        f_name = re.sub(r'^openwrt-openwrt-', 'openwrt-', str(f_router))
        f_name = re.sub(r'\.defiant\.dedyn\.io$', '', f_name)
        f_name = re.sub(r'[^a-z0-9-]', '-', f_name.lower()).strip('-')
        f_data.append({'name': f_name, 'enabled': True, 'host': f_host,
                       'scheme': f_m.group(1), 'target': f_m.group(2),
                       'port': int(f_m.group(3)),
                       'insecure_skip_verify': True, 'access': f_access})
        f_known.add(f_host)
        f_added.append(f_name + ' -> ' + f_host)
os.makedirs(os.path.dirname(f_dst), exist_ok=True)
with open(f_dst, 'w') as f_handle:
    yaml.safe_dump(f_data, f_handle, default_flow_style=False, sort_keys=False)
print('imported ' + str(len(f_added)) + ' forwards:')
for f_line in f_added:
    print('  ' + f_line)
PYEOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

if [[ "${1:-}" == "--import" ]]
then
  if [[ -z "${2:-}" || ! -d "$2" ]]
  then
    g_echo_error "--import needs an existing directory"
    exit 1
  fi
  f_import "$2"
  exit 0
fi

g_file="$(f_data_file)"
if ! [[ -f "${g_file}" ]]
then
  g_echo_note "no forwards configured, writing empty list to ${g_file}"
  echo "[]" > "${g_file}"
fi

if f_validate "${g_file}"
then
  symbios-run-playbook.sh base-services/traefik-proxy.yml
fi
