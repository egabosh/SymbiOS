#!/bin/bash
# SymbiOS - Apply Power targets (Wake-on-LAN + idle suspend).
#
# The target list lives in ${g_config_dir}/power/targets.yml (written by the
# WebUI at /settings/suspend/ and /settings/wake-on-lan/). This script
# validates the file and renders live configs + systemd instances via the
# playbook base-services/wol-suspend.yml.
#
# Usage:
#   symbios-power-apply.sh
#   symbios-power-apply.sh --wake <target>    Send a magic packet now
#   symbios-power-apply.sh --check <target>   One idle-evaluation dry run
#   symbios-power-apply.sh --status           JSON status of all targets

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [action] [options]

Manage Power targets (same entries as the WebUI at /settings/suspend/ and
/settings/wake-on-lan/) and apply them via base-services/wol-suspend.yml.

Actions (default: --apply):
  --list                       List all targets as a table
  --dump                       Print all targets as JSON (for the WebUI)
  --add-wake --name <n> --mac <m> --host <h> --patterns <p1,p2>
      [--log-path <p>] [--disabled]
                               Add a wake block (fails when the name exists)
  --set-wake --name <n> [same fields as --add-wake]
                               Change fields of an existing wake block
  --add-suspend --name <n> --host <h> --iface <i>
      [--timeout <min>] [--grace <sec>] [--tcp-ports <re>]
      [--lan-subnet <s>] [--extra-local <cmd>] [--extra-remote <cmd>]
      [--disabled]             Add a suspend block
  --set-suspend --name <n> [same fields as --add-suspend]
                               Change fields of an existing suspend block
  --delete --name <n>          Delete a whole target (both blocks)
  --toggle-wake --name <n>     Flip wake enabled/disabled
  --toggle-suspend --name <n>  Flip suspend enabled/disabled
  --apply                      Validate and render all targets
  --wake <target>              Send a Wake-on-LAN magic packet now
  --check <target>             Dry-run the idle evaluation (never suspends)
  --status                     Print JSON status (awake, units) of all targets

Mutating actions validate the list and auto-apply afterwards.
EOF
}

function f_targets_file {
  local f_dir="${g_config_dir}/power"
  if ! [[ -d "${f_dir}" ]]
  then
    mkdir -p "${f_dir}"
  fi
  echo "${f_dir}/targets.yml"
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
    sys.exit('targets.yml must contain a YAML list')
f_names = []
for f_entry in f_data:
    f_name = f_entry.get('name', '?')
    if not re.match(r'^[a-z0-9][a-z0-9-]*$', f_name or ''):
        sys.exit('invalid name: ' + str(f_name))
    if f_name in f_names:
        sys.exit('duplicate name: ' + f_name)
    f_names.append(f_name)
    f_wake = f_entry.get('wake') or {}
    f_susp = f_entry.get('suspend') or {}
    if not f_wake and not f_susp:
        sys.exit('target ' + f_name + ' has neither wake nor suspend block')
    if f_wake.get('enabled'):
        if not re.match(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$', f_wake.get('mac') or ''):
            sys.exit('invalid mac in ' + f_name)
        if not f_wake.get('host'):
            sys.exit('missing wake host in ' + f_name)
        if not f_wake.get('patterns'):
            sys.exit('missing wake patterns in ' + f_name)
    if f_susp.get('enabled'):
        if not f_susp.get('host') or not f_susp.get('iface'):
            sys.exit('missing suspend host/iface in ' + f_name)
        try:
            f_min = int(f_susp.get('idle_timeout_min', 0))
        except (TypeError, ValueError):
            sys.exit('invalid idle_timeout_min in ' + f_name)
        if f_min < 5 or f_min > 600:
            sys.exit('invalid idle_timeout_min in ' + f_name)
print('targets.yml valid: ' + str(len(f_data)) + ' targets')
PYEOF
}

function f_wake {
  local f_name="$1"
  source "${g_script_dir}/symbios-wol-common.sh"
  WOL_NAME="${f_name}"
  if ! f_wol_load_conf "${f_name}"
  then
    g_echo_error "no live config for target ${f_name} (apply first)"
    exit 1
  fi
  if [[ -z "${WOL_WAKE_MAC}" ]]
  then
    g_echo_error "target ${f_name} has no wake MAC configured"
    exit 1
  fi
  if ping -c1 -W2 "${WOL_WAKE_HOST}" &>/dev/null
  then
    g_echo_note "${WOL_WAKE_HOST} already awake - sending magic packet anyway"
  fi
  f_wol_send
  g_echo "magic packet sent to ${WOL_WAKE_MAC} (${WOL_WAKE_HOST})"
}

function f_check {
  local f_name="$1"
  "${g_script_dir}/symbios-wol-watch-idle.sh" "${f_name}" --check
}

function f_status {
  python3 - << 'PYEOF'
import json
import os
import subprocess
import yaml

g_config = os.environ.get('SYMBIOS_CONFIG_DIR', '')
f_file = os.path.join(g_config, 'power', 'targets.yml')
try:
    with open(f_file) as f_handle:
        f_data = yaml.safe_load(f_handle) or []
except (OSError, yaml.YAMLError):
    f_data = []
f_out = []
for f_entry in f_data if isinstance(f_data, list) else []:
    if not isinstance(f_entry, dict):
        continue
    f_host = ((f_entry.get('suspend') or {}).get('host')
              or (f_entry.get('wake') or {}).get('host') or '')
    f_awake = False
    if f_host:
        f_awake = (subprocess.run(
            ['ping', '-c1', '-W2', f_host],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)
    f_units = {}
    for f_unit in ('wol-tail', 'wol-idle'):
        try:
            f_state = subprocess.run(
                ['systemctl', 'is-active', f_unit + '@' + f_entry.get('name', '')],
                capture_output=True, text=True).stdout.strip()
        except OSError:
            f_state = 'unknown'
        f_units[f_unit] = f_state
    f_out.append({'name': f_entry.get('name'), 'host': f_host,
                  'awake': f_awake, 'units': f_units,
                  'wake': bool((f_entry.get('wake') or {}).get('enabled')),
                  'suspend': bool((f_entry.get('suspend') or {}).get('enabled'))})
print(json.dumps(f_out))
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
    sys.exit('targets.yml must contain a YAML list')

def f_check(entry):
    f_name = entry.get('name', '?')
    if not re.match(r'^[a-z0-9][a-z0-9-]*$', f_name or ''):
        sys.exit('invalid name: ' + str(f_name))
    f_wake = entry.get('wake') or {}
    f_susp = entry.get('suspend') or {}
    if not f_wake and not f_susp:
        sys.exit('target ' + f_name + ' has neither wake nor suspend block')
    if f_wake.get('enabled'):
        if not re.match(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$', f_wake.get('mac') or ''):
            sys.exit('invalid mac in ' + f_name)
        if not re.match(r'^[A-Za-z0-9.-]+$', f_wake.get('host') or ''):
            sys.exit('invalid wake host in ' + f_name)
        if not f_wake.get('patterns'):
            sys.exit('missing wake patterns in ' + f_name)
    if f_susp.get('enabled'):
        if not re.match(r'^[A-Za-z0-9.-]+$', f_susp.get('host') or ''):
            sys.exit('invalid suspend host in ' + f_name)
        if not re.match(r'^[a-zA-Z0-9]+$', f_susp.get('iface') or ''):
            sys.exit('invalid iface in ' + f_name)
        try:
            f_min = int(f_susp.get('idle_timeout_min', 0))
        except (TypeError, ValueError):
            sys.exit('invalid idle_timeout_min in ' + f_name)
        if f_min < 5 or f_min > 600:
            sys.exit('invalid idle_timeout_min in ' + f_name)

def f_flag(block, opts, django_name, key, default=None):
    if django_name in opts and opts[django_name] is not True:
        block[key] = opts[django_name]
    elif default is not None and key not in block:
        block[key] = default

if f_action == 'list':
    print('%-12s %-8s %-16s %-8s %-16s' % ('NAME', 'WAKE', 'WAKE-HOST', 'SUSP', 'SUSP-HOST'))
    for f_e in sorted(f_data, key=lambda e: e.get('name', '')):
        f_w = f_e.get('wake') or {}
        f_s = f_e.get('suspend') or {}
        print('%-12s %-8s %-16s %-8s %-16s' % (
            f_e.get('name'),
            'on' if f_w.get('enabled') else ('off' if f_w else '-'),
            f_w.get('host', '') if f_w else '',
            'on' if f_s.get('enabled') else ('off' if f_s else '-'),
            f_s.get('host', '') if f_s else ''))
    sys.exit(0)

f_name = str(f_opts.get('name', '')).lower()
if not f_name:
    sys.exit('--name is required')
f_idx = next((i for i, e in enumerate(f_data) if e.get('name') == f_name), None)

if f_action == 'delete':
    if f_idx is None:
        sys.exit('no target named ' + f_name)
    del f_data[f_idx]
    print('deleted ' + f_name)
elif f_action in ('toggle-wake', 'toggle-suspend'):
    if f_idx is None:
        sys.exit('no target named ' + f_name)
    f_block_name = f_action.split('-', 1)[1]
    f_block = f_data[f_idx].get(f_block_name)
    if not isinstance(f_block, dict):
        sys.exit('target ' + f_name + ' has no ' + f_block_name + ' block')
    f_block['enabled'] = not f_block.get('enabled', True)
    print(f_name + ' ' + f_block_name + ' is now ' + ('enabled' if f_block['enabled'] else 'disabled'))
elif f_action in ('add-wake', 'set-wake', 'add-suspend', 'set-suspend'):
    f_block_name = 'wake' if 'wake' in f_action else 'suspend'
    f_is_add = f_action.startswith('add')
    if f_is_add and f_idx is not None and f_data[f_idx].get(f_block_name):
        sys.exit('target ' + f_name + ' already has a ' + f_block_name + ' block')
    if not f_is_add and (f_idx is None or not f_data[f_idx].get(f_block_name)):
        sys.exit('target ' + f_name + ' has no ' + f_block_name + ' block')
    if f_idx is None:
        f_data.append({'name': f_name})
        f_idx = len(f_data) - 1
    f_entry = f_data[f_idx]
    f_block = f_entry.get(f_block_name) or {}
    if f_block_name == 'wake':
        f_flag(f_block, f_opts, 'mac', 'mac')
        f_flag(f_block, f_opts, 'host', 'host')
        if 'patterns' in f_opts and f_opts['patterns'] is not True:
            f_block['patterns'] = [p.strip() for p in str(f_opts['patterns']).split(',') if p.strip()]
        f_flag(f_block, f_opts, 'log-path', 'log_path')
    else:
        f_flag(f_block, f_opts, 'host', 'host')
        f_flag(f_block, f_opts, 'iface', 'iface')
        f_flag(f_block, f_opts, 'timeout', 'idle_timeout_min', 15)
        f_flag(f_block, f_opts, 'grace', 'grace_after_wol_sec', 300)
        f_flag(f_block, f_opts, 'tcp-ports', 'tcp_ports')
        f_flag(f_block, f_opts, 'lan-subnet', 'lan_subnet')
        f_flag(f_block, f_opts, 'extra-local', 'extra_local_cmd')
        f_flag(f_block, f_opts, 'extra-remote', 'extra_remote_cmd')
    if 'disabled' in f_opts:
        f_block['enabled'] = False
    if 'enabled' in f_opts:
        f_block['enabled'] = True
    if f_is_add and 'enabled' not in f_block:
        f_block['enabled'] = True
    if f_block_name == 'suspend':
        f_block.setdefault('idle_timeout_min', 15)
        f_block.setdefault('grace_after_wol_sec', 300)
    f_entry[f_block_name] = f_block
    for f_e in f_data:
        f_check(f_e)
    f_data.sort(key=lambda e: e.get('name', ''))
    print(('added ' if f_is_add else 'updated ') + f_name + ' ' + f_block_name)
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
    symbios-run-playbook.sh base-services/wol-suspend.yml
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

if [[ "${1:-}" == "--wake" ]]
then
  if [[ -z "${2:-}" ]]
  then
    g_echo_error "--wake needs a target name"
    exit 1
  fi
  f_wake "$2"
  exit 0
fi

if [[ "${1:-}" == "--check" ]]
then
  if [[ -z "${2:-}" ]]
  then
    g_echo_error "--check needs a target name"
    exit 1
  fi
  f_check "$2"
  exit 0
fi

if [[ "${1:-}" == "--status" ]]
then
  SYMBIOS_CONFIG_DIR="${g_config_dir}" f_status
  exit 0
fi

g_file="$(f_targets_file)"
if ! [[ -f "${g_file}" ]]
then
  g_echo_note "no targets configured, writing empty list to ${g_file}"
  echo "[]" > "${g_file}"
fi

f_list="list dump add-wake set-wake add-suspend set-suspend delete toggle-wake toggle-suspend apply"
f_found="no"
if [[ $# -eq 0 ]]
then
  f_found="apply"
fi
for f_a in ${f_list}
do
  if [[ "${1:-}" == "--${f_a}" ]]
  then
    f_found="${f_a}"
  fi
done

if [[ "${f_found}" == "no" ]]
then
  g_echo_error "unknown action ${1:-} (see --help)"
  exit 1
fi

if [[ "${f_found}" == "list" ]]
then
  f_manage list "${g_file}"
  exit 0
fi

if [[ "${f_found}" == "dump" ]]
then
  f_dump "${g_file}"
  exit 0
fi

if [[ "${f_found}" == "apply" ]]
then
  f_apply "${g_file}"
  exit 0
fi

# Mutating actions validate first (inside f_manage), then auto-apply.
f_manage_action="${f_found}"
shift
if f_manage "${f_manage_action}" "${g_file}" "$@"
then
  f_apply "${g_file}"
fi
