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
Usage: $(basename "$0") [action] [options]

Manage Reverse-Proxy forwards (same entries as the WebUI at
/settings/reverse-proxy/) and apply them via
base-services/traefik-proxy.yml.

Actions (default: --apply):
  --list                       List all forwards as a table
  --dump                       Print all forwards as JSON (for the WebUI)
  --add --name <n> --host <h> --target <t> --port <p>
      [--scheme http|https] [--access open|local|authelia]
      [--insecure true|false] [--disabled]
                               Add a forward (fails when the name exists)
  --set --name <n> [same fields as --add]
                               Change fields of an existing forward
  --delete --name <n>          Delete a forward
  --toggle --name <n>          Flip enabled/disabled
  --apply                      Validate and render all forwards
  --import <dir>               Convert hand-written Traefik provider snippets
                               (*.yml) into forwards.yml entries and exit

Mutating actions validate the list and auto-apply afterwards.
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

function f_manage {
  python3 - "$@" << 'PYEOF'
import re
import sys
import yaml

f_args = sys.argv[1:]
f_action = f_args[0]
f_file = f_args[1]
f_opts = {}
f_key = None
for f_tok in f_args[2:]:
    if f_tok.startswith('--'):
        f_key = f_tok[2:]
        f_opts[f_key] = True
    elif f_key:
        f_opts[f_key] = f_tok
        f_key = None

try:
    with open(f_file) as f_handle:
        f_data = yaml.safe_load(f_handle) or []
except OSError:
    f_data = []
if not isinstance(f_data, list):
    sys.exit('forwards.yml must contain a YAML list')

def f_check(entry):
    f_name = entry.get('name', '?')
    if not re.match(r'^[a-z0-9][a-z0-9-]*$', f_name or ''):
        sys.exit('invalid name: ' + str(f_name))
    if f_name in ('default', 'symbios-services', 'traefik', 'authelia'):
        sys.exit('name is reserved: ' + f_name)
    if not re.match(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$',
                    (entry.get('host') or '').lower()):
        sys.exit('invalid host in ' + f_name)
    if entry.get('scheme', 'http') not in ('http', 'https'):
        sys.exit('invalid scheme in ' + f_name)
    if not re.match(r'^[A-Za-z0-9.-]+$', entry.get('target') or ''):
        sys.exit('invalid target in ' + f_name)
    try:
        f_port = int(entry.get('port', 0))
    except (TypeError, ValueError):
        sys.exit('invalid port in ' + f_name)
    if f_port < 1 or f_port > 65535:
        sys.exit('invalid port in ' + f_name)
    if entry.get('access', 'open') not in ('open', 'local', 'authelia'):
        sys.exit('invalid access in ' + f_name)

if f_action == 'list':
    print('%-16s %-5s %-32s %-28s %s' % ('NAME', 'ON', 'HOST', 'TARGET', 'ACCESS'))
    for f_e in sorted(f_data, key=lambda e: e.get('name', '')):
        print('%-16s %-5s %-32s %-28s %s' % (
            f_e.get('name'), 'yes' if f_e.get('enabled', True) else 'no',
            f_e.get('host'),
            '%s://%s:%s' % (f_e.get('scheme', 'http'), f_e.get('target'), f_e.get('port')),
            f_e.get('access', 'open')))
    sys.exit(0)

f_name = str(f_opts.get('name', '')).lower()
if not f_name:
    sys.exit('--name is required')
f_idx = next((i for i, e in enumerate(f_data) if e.get('name') == f_name), None)

if f_action == 'delete':
    if f_idx is None:
        sys.exit('no forward named ' + f_name)
    del f_data[f_idx]
    print('deleted ' + f_name)
elif f_action == 'toggle':
    if f_idx is None:
        sys.exit('no forward named ' + f_name)
    f_data[f_idx]['enabled'] = not f_data[f_idx].get('enabled', True)
    print(f_name + ' is now ' + ('enabled' if f_data[f_idx]['enabled'] else 'disabled'))
elif f_action in ('add', 'set'):
    if f_action == 'add':
        if f_idx is not None:
            sys.exit('forward ' + f_name + ' already exists')
        f_entry = {'name': f_name, 'enabled': True}
        f_data.append(f_entry)
    else:
        if f_idx is None:
            sys.exit('no forward named ' + f_name)
        f_entry = f_data[f_idx]
    if 'host' in f_opts:
        f_entry['host'] = str(f_opts['host']).lower()
    if 'scheme' in f_opts:
        f_entry['scheme'] = f_opts['scheme']
    if 'target' in f_opts:
        f_entry['target'] = f_opts['target']
    if 'port' in f_opts:
        f_entry['port'] = int(f_opts['port'])
    if 'access' in f_opts:
        f_entry['access'] = f_opts['access']
    if 'insecure' in f_opts:
        f_entry['insecure_skip_verify'] = str(f_opts['insecure']).lower() in ('1', 'true', 'yes', 'on')
    if 'disabled' in f_opts:
        f_entry['enabled'] = False
    if 'enabled' in f_opts:
        f_entry['enabled'] = True
    for f_e in f_data:
        f_check(f_e)
    if len({str(e.get('host', '')).lower() for e in f_data}) != len(f_data):
        sys.exit('duplicate host')
    f_data.sort(key=lambda e: e.get('name', ''))
    print(('added ' if f_action == 'add' else 'updated ') + f_name)
else:
    sys.exit('unknown action: ' + f_action)

with open(f_file, 'w') as f_handle:
    yaml.safe_dump(f_data, f_handle, default_flow_style=False, sort_keys=False)
PYEOF
}

function f_apply {
  local f_file="$1"
  if f_validate "${f_file}"
  then
    symbios-run-playbook.sh base-services/traefik-proxy.yml
  fi
}

function f_dump {
  python3 - "$1" << 'PYEOF'
import json
import sys
import yaml

try:
    with open(sys.argv[1]) as f_handle:
        f_data = yaml.safe_load(f_handle) or []
except (OSError, yaml.YAMLError):
    f_data = []
if not isinstance(f_data, list):
    f_data = []
print(json.dumps([e for e in f_data if isinstance(e, dict)]))
PYEOF
}

f_action="apply"
f_import_dir=""
f_rest=()
while [[ $# -gt 0 ]]
do
  case "$1" in
    -h|--help)
      f_usage
      exit 0
      ;;
    --list|--add|--set|--delete|--toggle|--apply|--dump)
      f_action="${1#--}"
      shift
      ;;
    --import)
      f_action="import"
      f_import_dir="${2:-}"
      shift 2
      ;;
    *)
      f_rest+=("$1")
      shift
      ;;
  esac
done

if [[ "${f_action}" == "import" ]]
then
  if [[ -z "${f_import_dir}" || ! -d "${f_import_dir}" ]]
  then
    g_echo_error "--import needs an existing directory"
    exit 1
  fi
  f_import "${f_import_dir}"
  exit 0
fi

g_file="$(f_data_file)"
if ! [[ -f "${g_file}" ]]
then
  g_echo_note "no forwards configured, writing empty list to ${g_file}"
  echo "[]" > "${g_file}"
fi

if [[ "${f_action}" == "list" ]]
then
  f_manage list "${g_file}"
  exit 0
fi

if [[ "${f_action}" == "dump" ]]
then
  f_dump "${g_file}"
  exit 0
fi

if [[ "${f_action}" == "apply" ]]
then
  f_apply "${g_file}"
  exit 0
fi

# Mutating actions validate first (inside f_manage), then auto-apply.
if f_manage "${f_action}" "${g_file}" "${f_rest[@]}"
then
  f_apply "${g_file}"
fi
