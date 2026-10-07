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
Usage: $(basename "$0") [--wake <target> | --check <target> | --status]

Apply the Power targets from ${g_config_dir}/power/targets.yml
via base-services/wol-suspend.yml.

Options:
  --wake <target>    Send a Wake-on-LAN magic packet to <target> now
  --check <target>   Dry-run the idle evaluation for <target> (never suspends)
  --status           Print JSON status (awake, units) of all targets
  -h, --help         Show this help and exit
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

if f_validate "${g_file}"
then
  symbios-run-playbook.sh base-services/wol-suspend.yml
fi
