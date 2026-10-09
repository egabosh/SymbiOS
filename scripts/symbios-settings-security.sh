#!/bin/bash
# SymbiOS - Manage security settings (password policy, WebUI access scope).
#
# Settings CLI-first architecture: the WebUI page /settings/security/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction, real booleans).
#
# Two independent forms share the page, so each field is optional here:
# options left out keep their current value. Whether the traefik playbook
# must be reapplied after a public-access flip is decided by the caller
# (it compares old and new values); this script only reports the state
# token.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS security settings (password policy, WebUI access scope).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--policy POLICY --public-access true|false | --json-stdin]
       [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads {"password_policy":..,
                                  "webui_public_access":..}. POLICY is one of
                                  none|low|medium|high|paranoid. Options left
                                  out keep their current value. --check
                                  changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (security-changed / security-unchanged).

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
  {"name": "password_policy", "type": "select", "label": "Password policy",
   "required": false, "default": "medium", "secret": false,
   "options": ["none", "low", "medium", "high", "paranoid"]},
  {"name": "webui_public_access", "type": "bool", "label": "WebUI public (internet) access",
   "required": false, "default": false, "secret": false}
]
EOF
  exit 0
fi

f_cur_policy="$(f_symbios_var password_policy "")"
f_cur_public="$(f_symbios_var webui_public_access "")"
if [[ "${f_cur_public}" == "True" || "${f_cur_public}" == "true" ]]
then
  f_cur_public="true"
else
  f_cur_public="false"
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"password_policy": %s, "webui_public_access": %s}\n' \
      "$(printf '%s' "${f_cur_policy}" | f_json_escape)" \
      "${f_cur_public}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "password_policy=${f_cur_policy}"
  echo "webui_public_access=${f_cur_public}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_policy=""
f_given_policy="no"
f_new_public=""
f_given_public="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --policy)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_policy="$2"
      f_given_policy="yes"
      shift 2
      ;;
    --policy=*)
      f_new_policy="${1#--policy=}"
      f_given_policy="yes"
      shift
      ;;
    --public-access)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_public="$2"
      f_given_public="yes"
      shift 2
      ;;
    --public-access=*)
      f_new_public="${1#--public-access=}"
      f_given_public="yes"
      shift
      ;;
    --json-stdin)
      f_json="$(cat)"
      if [[ "${f_json}" == *'"password_policy"'* ]]
      then
        f_new_policy="$(f_json_get "${f_json}" "password_policy")" || f_new_policy=""
        f_given_policy="yes"
      fi
      if [[ "${f_json}" == *'"webui_public_access"'* ]]
      then
        f_onoff="$(grep -o '"webui_public_access"[[:space:]]*:[[:space:]]*[^,}]*' <<< "${f_json}" | head -1)"
        f_onoff="${f_onoff##*:}"
        f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
        f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
        f_onoff="${f_onoff%\"}"
        f_onoff="${f_onoff#\"}"
        f_new_public="${f_onoff}"
        f_given_public="yes"
      fi
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

if [[ "${f_given_policy}" == "no" && "${f_given_public}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --policy and/or --public-access"
fi

if [[ "${f_given_policy}" == "yes" ]]
then
  case "${f_new_policy}" in
    none|low|medium|high|paranoid)
      ;;
    *)
      f_ss_fail_validation "Invalid password policy: ${f_new_policy} (expected none|low|medium|high|paranoid)"
      ;;
  esac
fi

if [[ "${f_given_public}" == "yes" ]]
then
  if ! f_parsed_public="$(f_ss_parse_bool "${f_new_public}")"
  then
    f_ss_fail_validation "Invalid --public-access value: ${f_new_public} (expected true|false)"
  fi
  f_new_public="${f_parsed_public}"
fi

# --- transactional write -------------------------------------------------------

f_merge="{"
f_merge_first="yes"
if [[ "${f_given_policy}" == "yes" ]]
then
  f_merge="${f_merge}\"password_policy\": $(printf '%s' "${f_new_policy}" | f_json_escape)"
  f_merge_first="no"
fi
if [[ "${f_given_public}" == "yes" ]]
then
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge="${f_merge}\"webui_public_access\": ${f_new_public}"
fi
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "security" "${f_check}"
exit 0
