#!/bin/bash
# SymbiOS - Sync the managed state from an external system.
#
# Every playbook below external-services/ records the resources it created in
# /etc/symbios/managed.json on the target. This script pulls that file and
# stores it as <config>/external-systems/states/<target_id>.json, where the
# WebUI shows it (External Systems -> Inventory) and checks docs.requires
# against it.
#
# The previous state file is only replaced by a complete, valid result: an
# unreachable target or a broken JSON never wipes the known inventory.
#
# Usage:
#   symbios-remote-sync.sh <target_id>

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <target_id>

Pull /etc/symbios/managed.json from an external system and store it as
${g_config_dir}/external-systems/states/<target_id>.json.

The state file is only rewritten when the target answered and the file
parsed: an unreachable host or invalid JSON keeps the previous state.

Options:
  -h, --help       Show this help and exit

Exit codes:
  0  ok (also when the target has no managed.json yet)
  1  technical error (SSH failed, invalid JSON, write failed)
  2  usage error
EOF
}

function f_fail {
  g_echo_error "$1"
  exit "${2:-1}"
}

# --- arguments --------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

g_target="${1:-}"
if [[ -z "${g_target}" ]]
then
  f_usage >&2
  exit 2
fi

if ! f_external_target "${g_target}"
then
  f_fail "Unknown external system: ${g_target} (see ${g_config_dir}/external-systems.yml)"
fi

# --- reachability -----------------------------------------------------------
# Check first: "no managed.json" must not be confused with "host down".
if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}" true 2> /dev/null
then
  f_fail "Cannot reach ${g_target} (${g_ext_user}@${g_ext_host}:${g_ext_port})"
fi

g_state_dir="${g_config_dir}/external-systems/states"
mkdir -p "${g_state_dir}" || f_fail "Cannot create ${g_state_dir}"
g_raw=$(mktemp) || f_fail "Cannot create a temporary file"
trap 'rm -f "${g_raw}"' EXIT

# A target without managed.json is valid: nothing was applied through SymbiOS.
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}" \
  'cat /etc/symbios/managed.json 2>/dev/null' > "${g_raw}" || true

# --- parse + write state (atomic) -------------------------------------------
python3 - "${g_raw}" "${g_state_dir}/${g_target}.json" "${g_target}" "${g_ext_type}" << 'PY'
import json
import os
import sys

raw_path, out_path, target_id, target_type = sys.argv[1:5]
entries = []
try:
    with open(raw_path) as fh:
        text = fh.read().strip()
except OSError:
    text = ''
if text:
    try:
        data = json.loads(text)
    except ValueError:
        sys.exit('Invalid managed.json on the target (not JSON)')
    if isinstance(data, dict):
        entries = data.get('entries') or []
    elif isinstance(data, list):
        entries = data
    if not isinstance(entries, list):
        sys.exit('Invalid managed.json on the target (entries is not a list)')

state = {'target_id': target_id, 'target_type': target_type, 'managed': entries}
tmp_path = out_path + '.tmp'
with open(tmp_path, 'w') as fh:
    json.dump(state, fh, indent=2)
    fh.write('\n')
    fh.flush()
    os.fsync(fh.fileno())
os.replace(tmp_path, out_path)
PY
g_rc=$?
rm -f "${g_state_dir}/${g_target}.json.tmp"
if (( g_rc != 0 ))
then
  f_fail "Sync failed, previous state kept"
fi

g_echo_note "Synced ${g_target}: ${g_state_dir}/${g_target}.json"
