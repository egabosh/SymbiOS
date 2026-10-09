#!/bin/bash
# SymbiOS - Manage AI settings (server URL and API key).
#
# Settings CLI-first architecture: the WebUI page /settings/ai/ is a thin
# wrapper around this script, which owns validation and the inventory.yml
# write. The inventory write goes through symbios-inventory.py (merge, one
# transaction). Empty values delete the key (same as the WebUI before).
#
# Secrets (ai_apikey) MUST come via --json-stdin, never as argv (visible
# in ps). There is deliberately no --ai-apikey flag.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS AI settings (OpenAI-compatible server URL and API key).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--ai-server URL | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads {"ai_server":..,
                                  "ai_apikey":..} from stdin (REQUIRED for
                                  the API key - secrets never travel as
                                  argv). Empty values delete the key.
                                  --check reports what would change,
                                  changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (ai-changed / ai-unchanged) so callers can detect a change.

Examples:
  $(basename "$0") get
  $(basename "$0") set --ai-server https://ai.example.com/v1
  echo '{"ai_server":"https://ai.example.com/v1","ai_apikey":"sk-.."}' \\
    | $(basename "$0") set --json-stdin

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
  {"name": "ai_server", "type": "url", "label": "AI server URL",
   "required": false, "default": "", "secret": false,
   "placeholder": "https://ai.example.com/v1"},
  {"name": "ai_apikey", "type": "password", "label": "API key",
   "required": false, "default": "", "secret": true}
]
EOF
  exit 0
fi

f_cur_server="$(f_symbios_var ai_server "")"
f_cur_key_set="no"
[[ -n "$(f_symbios_var ai_apikey "")" ]] && f_cur_key_set="yes"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    # The key value itself is never printed (secret); only whether one
    # is configured.
    printf '{"ai_server": %s, "ai_apikey_set": %s}\n' \
      "$(printf '%s' "${f_cur_server}" | f_json_escape)" \
      "$([[ "${f_cur_key_set}" == "yes" ]] && echo "true" || echo "false")"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "ai_server=${f_cur_server}"
  echo "ai_apikey_set=${f_cur_key_set}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_server=""
f_given_server="no"
f_new_key=""
f_given_key="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --ai-server)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_server="$2"
      f_given_server="yes"
      shift 2
      ;;
    --ai-apikey|--ai-apikey=*)
      f_ss_fail_validation "ai_apikey is a secret and must be passed via --json-stdin, never as argv"
      ;;
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

if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  if f_val="$(f_json_get "${f_json}" "ai_server")" && [[ -n "${f_val}" || "${f_json}" == *'"ai_server"'* ]]
  then
    f_new_server="${f_val}"
    f_given_server="yes"
  fi
  if f_val="$(f_json_get "${f_json}" "ai_apikey")" && [[ -n "${f_val}" || "${f_json}" == *'"ai_apikey"'* ]]
  then
    f_new_key="${f_val}"
    f_given_key="yes"
  fi
fi

if [[ "${f_given_server}" == "no" && "${f_given_key}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --ai-server and/or --json-stdin"
fi

# URLs must be single-line without whitespace (the WebUI test probe adds
# https:// itself when the scheme is missing, so no scheme is required).
if [[ "${f_given_server}" == "yes" && -n "${f_new_server}" ]]
then
  f_ss_require_url "ai_server URL" "${f_new_server}"
fi
if [[ "${f_given_key}" == "yes" && -n "${f_new_key}" ]]
then
  f_ss_require_single_line "ai_apikey" "${f_new_key}"
fi

# --- transactional write (empty values delete the key) -------------------------

f_merge="{"
f_merge_first="yes"
f_ss_merge_add "ai_server" "${f_new_server}" "${f_given_server}"
f_ss_merge_add "ai_apikey" "${f_new_key}" "${f_given_key}"
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "ai" "${f_check}"
exit 0
