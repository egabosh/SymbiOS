#!/bin/bash
# SymbiOS - Manage Linux bridge assignments (interface -> bridge).
#
# Settings CLI-first architecture: the WebUI page
# /settings/network-bridges/ is a thin wrapper around this script for the
# stored assignments (bridge_assignments dict in inventory.yml). Host
# discovery (bridges/interfaces) stays with symbios-bridge-list.sh, and
# applying stays with symbios-bridge-assign.sh (stdin JSON) plus the
# network-bridges playbook - the view chains those behind the save.
#
# The form sends one select per visible interface; an empty value means
# "no assignment", so a save always replaces the whole dict.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage Linux bridge assignments (physical interface -> bridge).

Commands:
  get [--json]                    Print the assignments (iface=bridge
                                  lines, or a JSON object with --json)
  set --json-stdin [--check]      Validate and replace bridge_assignments
                                  from a {"iface": "bridge", ...} object on
                                  stdin (empty values are dropped, same as
                                  the WebUI form). --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (network-bridges-changed / network-bridges-unchanged).

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

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema)
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
{
  "backend": "dict",
  "key": "bridge_assignments",
  "fields": [
    {"name": "assignments", "type": "map", "label": "Interface assignments",
     "required": false, "default": {}, "secret": false,
     "note": "One select per interface; empty means unassigned"}
  ]
}
EOF
  exit 0
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
      get --json bridge_assignments 2>/dev/null || echo "{}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-show bridge_assignments 2>/dev/null
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --json-stdin)
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

[[ "${f_json_stdin}" == "yes" ]] \
  || f_ss_fail_validation "Nothing to set - pass --json-stdin"

f_json="$(cat)"
# NOTE: this python3 snippet only parses and cleans the stdin JSON object
# (bash cannot parse JSON); inventory access stays in symbios-inventory.py.
if ! f_assignments="$(printf '%s' "${f_json}" | python3 -c "
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    sys.exit('invalid JSON on stdin: {}'.format(e))
if not isinstance(data, dict):
    sys.exit('stdin must hold a JSON object')
cleaned = {}
# Same charset as symbios-bridge-assign.sh: only these names ever reach
# `ip link set ... master ...`, so anything else is rejected here and can
# never be stored (command injection is impossible).
name_re = re.compile(r'^[A-Za-z0-9_.@-]+$')
for k, v in data.items():
    if not isinstance(k, str) or not name_re.match(k.strip()):
        sys.exit('invalid interface name: {!r}'.format(k))
    if v is None:
        continue
    if not isinstance(v, str):
        sys.exit('invalid bridge for {}: {!r}'.format(k, v))
    # Empty means unassigned (same as the WebUI form) - dropped.
    if not v.strip():
        continue
    if not name_re.match(v.strip()):
        sys.exit('invalid bridge name: {!r}'.format(v))
    cleaned[k.strip()] = v.strip()
print(json.dumps(cleaned))
" 2>&1)"
then
  f_ss_fail_validation "${f_assignments}"
fi

# --- transactional write (whole-dict replace, same as the WebUI form) ------------

f_merge="$(printf '{"bridge_assignments": %s}' "${f_assignments}")"

f_ss_merge "${f_merge}" "network-bridges" "${f_check}"
exit 0
