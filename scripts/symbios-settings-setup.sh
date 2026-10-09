#!/bin/bash
# SymbiOS - Manage setup assistant state (connection type).
#
# Companion CLI for the /setup/ wizard endpoint: the view is a thin
# wrapper, validation and the inventory.yml write live here. The write
# goes through symbios-inventory.py (merge, one transaction).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage setup assistant state (server connection type).

Commands:
  get [--json]                    Print the connection type
  set --network-type home|root|airgapped [--check]
                                  Validate and write to inventory.yml.
                                  --check changes nothing.
  schema                          Print the field description as JSON
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (setup-changed / setup-unchanged).

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
[
  {"name": "network_type", "type": "select", "label": "Connection type",
   "required": true, "default": "home", "secret": false,
   "options": ["home", "root", "airgapped"]}
]
EOF
  exit 0
fi

f_cur_type="$(f_symbios_var network_type "")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"network_type": %s}\n' \
      "$(printf '%s' "${f_cur_type}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "network_type=${f_cur_type}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_type=""
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --network-type)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_type="$2"
      shift 2
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

case "${f_new_type}" in
  home|root|airgapped)
    ;;
  *)
    f_ss_fail_validation "Invalid network type: ${f_new_type} (expected home|root|airgapped)"
    ;;
esac

f_merge="$(printf '{"network_type": %s}' \
  "$(printf '%s' "${f_new_type}" | f_json_escape)")"

f_ss_merge "${f_merge}" "setup" "${f_check}"
exit 0
