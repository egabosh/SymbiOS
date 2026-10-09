#!/bin/bash
# SymbiOS - Manage file manager custom scripts (inventory list var).
#
# Companion CLI for the /filemanager/api/ save-scripts endpoint: the view
# is a thin wrapper, validation and the inventory.yml write live here. The
# write goes through symbios-inventory.py (merge, one transaction - lists
# of dicts are supported). An empty list deletes the key (same as before).
#
# NOTE: this companion also parses its stdin JSON with python3 (bash cannot
# parse JSON); inventory access stays in symbios-inventory.py. JSON strings
# inside the python3 -c double-quoted block must use single quotes only -
# a lone double quote silently truncates the program (see AGENTS.md).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage file manager custom scripts (name + command pairs).

Commands:
  get [--json]                    Print the scripts (human lines
                                  "name: command", or the raw JSON list
                                  with --json)
  set --json-stdin [--check]      Validate and replace file_manager_scripts
                                  from a [{"name":.., "command":..}, ...]
                                  object on stdin. Names allow letters,
                                  digits, dash, underscore, space and dot
                                  (single line); commands max 4000 chars.
                                  An empty list deletes the key.
                                  --check changes nothing.
  schema                          Print the field description as JSON
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (filemanager-changed / filemanager-unchanged).

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
  "backend": "list",
  "key": "file_manager_scripts",
  "fields": [
    {"name": "scripts", "type": "script-list", "label": "Custom scripts",
     "required": false, "default": [], "secret": false}
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
      get --json file_manager_scripts 2>/dev/null || echo "[]"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    get --json file_manager_scripts 2>/dev/null \
    | python3 -c 'import json, sys
try:
    items = json.load(sys.stdin) or []
except Exception:
    items = []
for item in items:
    if isinstance(item, dict):
        print(str(item.get("name", "")) + ": " + str(item.get("command", "")))' 2>/dev/null
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
if ! f_cleaned="$(printf '%s' "${f_json}" | python3 -c '
import json, sys
try:
    raw = json.load(sys.stdin)
except Exception as e:
    sys.exit("invalid JSON on stdin")
if not isinstance(raw, list):
    sys.exit("stdin must hold a JSON list")
cleaned = []
for item in raw:
    if not isinstance(item, dict):
        continue
    name = str(item.get("name") or "").strip()
    command = str(item.get("command") or "").strip()
    if not name or not command or chr(10) in name:
        continue
    test = name.replace("-", "").replace("_", "").replace(" ", "").replace(".", "")
    if not test.isalnum():
        sys.exit("invalid script name")
    if len(command) > 4000:
        sys.exit("command too long (max 4000 chars)")
    cleaned.append({"name": name, "command": command})
print(json.dumps(cleaned))
' 2>&1)"
then
  f_ss_fail_validation "${f_cleaned}"
fi

# --- transactional write (empty list deletes the key) ----------------------------

if [[ "${f_cleaned}" == "[]" ]]
then
  f_merge='{"file_manager_scripts": null}'
else
  f_merge="$(printf '{"file_manager_scripts": %s}' "${f_cleaned}")"
fi

f_ss_merge "${f_merge}" "filemanager" "${f_check}"
exit 0
