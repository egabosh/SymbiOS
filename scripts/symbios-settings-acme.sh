#!/bin/bash
# SymbiOS - Manage ACME settings (custom certificate authority server).
#
# Settings CLI-first architecture: the WebUI page /settings/acme/ is a thin
# wrapper around this script, which owns validation and the inventory.yml
# write. The inventory write goes through symbios-inventory.py (merge, one
# transaction). An empty inventory (default or after remove) means the
# Traefik/ACME default server is used.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS ACME settings (TLS certificate authority server).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set --server URL [--check]      Validate and write to inventory.yml.
                                  --check changes nothing.
  remove [--check]                Delete the custom server (fall back to
                                  the default CA server).
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (acme-changed / acme-unchanged).

Examples:
  $(basename "$0") get
  $(basename "$0") set --server https://ca.example.com/acme/acme/directory
  $(basename "$0") remove

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

function f_fail_usage {
  f_usage >&2
  exit 2
}

function f_fail_validation {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 2
}

function f_fail_technical {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 1
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|remove|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_fail_usage
    ;;
esac

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "acme_server", "type": "url", "label": "ACME server URL",
   "required": false, "default": "", "secret": false,
   "placeholder": "https://ca.example.com/acme/acme/directory"}
]
EOF
  exit 0
fi

f_cur_server="$(f_symbios_var acme_server "")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"acme_server": %s}\n' \
      "$(printf '%s' "${f_cur_server}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  echo "acme_server=${f_cur_server}"
  exit 0
fi

# --- subcommand: set / remove --------------------------------------------------

f_new_server=""
f_remove="no"
f_check="no"

if [[ "${f_command}" == "remove" ]]
then
  f_remove="yes"
fi

while [[ $# -gt 0 ]]
do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || f_fail_usage
      [[ "${f_remove}" == "yes" ]] && f_fail_usage
      f_new_server="$2"
      shift 2
      ;;
    --server=*)
      [[ "${f_remove}" == "yes" ]] && f_fail_usage
      f_new_server="${1#--server=}"
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
      f_fail_usage
      ;;
  esac
done

if [[ "${f_remove}" == "no" && -z "${f_new_server}" ]]
then
  f_fail_validation "Nothing to set - pass --server URL (or use remove)"
fi

# Single-line URL without whitespace. An explicit https:// scheme is not
# required here - Traefik passes caServer through as configured.
if [[ "${f_remove}" == "no" ]] \
  && { [[ "${f_new_server}" == *$'\n'* ]] || [[ "${f_new_server}" =~ [[:space:]] ]]; }
then
  f_fail_validation "Invalid --server URL: must be a single line without whitespace"
fi

# --- transactional write (remove deletes the key; the playbook default ""
# and the {% if acme_server %} guard in traefik.yml treat a missing key
# exactly like the empty string the WebUI used to write) ------------------------

if [[ "${f_remove}" == "yes" ]]
then
  f_merge='{"acme_server": null}'
else
  f_merge="$(printf '{"acme_server": %s}' \
    "$(printf '%s' "${f_new_server}" | f_json_escape)")"
fi

f_check_flag=""
[[ "${f_check}" == "yes" ]] && f_check_flag="--check"

if ! f_out="$(printf '%s' "${f_merge}" \
  | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge ${f_check_flag} 2>&1)"
then
  f_fail_technical "Failed to write inventory: ${f_out}"
fi

g_echo "${f_out}"

if [[ "${f_check}" == "yes" ]]
then
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

if grep -q "^unchanged$" <<< "${f_out}"
then
  g_echo_note "acme-unchanged"
else
  g_echo_note "acme-changed"
fi
exit 0
