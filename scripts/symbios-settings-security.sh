#!/bin/bash
# SymbiOS - Manage security settings (password policy, WebUI access, reboot).
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

Manage SymbiOS security settings (password policy, reboot policy and the
deprecated webui_public_access fallback). Network exposure is configured by
symbios-settings-access.sh and no longer shown on this page. The reboot keys
are read at runtime by the healthcheck and the maintenance module, so saving
them needs no playbook apply. A reboot is only warned about or scheduled when
one is actually pending (apt marker or newer installed kernel); uptime alone
never triggers it.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--policy POLICY --public-access true|false
       --max-days N --auto true|false | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads {"password_policy":..,
                                  "webui_public_access":..,
                                  "reboot_max_days":.., "reboot_auto":..}.
                                  POLICY is one of
                                  none|low|medium|high|paranoid. --max-days 0
                                  disables the reboot policy. Options left
                                  out keep their current value. --check
                                  changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  apply [--dry-run]               Resolve consuming playbooks (or show them
                                  with --dry-run) and run each in order.
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (security-changed / security-unchanged).

Options:
  --no-apply                      Skip the automatic playbook apply after a
                                  real inventory change (smoke tests).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="webui_public_access"

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
  get|set|schema|apply)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "apply" ]]
then
  f_ss_apply_cmd "$@"
  exit $?
fi

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "password_policy", "type": "select", "label": "Password policy",
   "required": false, "default": "medium", "secret": false,
   "options": ["none", "low", "medium", "high", "paranoid"],
   "note": "Levels: none (1+ characters), low (8+), medium (10+ with letter, digit and special character), high (16+, same mix), paranoid (32+, same mix). Enforced for LDAP user passwords."},
  {"name": "reboot_max_days", "type": "number", "label": "Uptime in days after which a pending reboot may be applied automatically",
   "required": false, "default": 0, "secret": false, "pattern": "^[0-9]+$",
   "note": "0 disables the reboot policy. Otherwise the healthcheck warns as soon as a reboot is pending; this value only limits when the automatic reboot may happen."},
  {"name": "reboot_auto", "type": "bool", "label": "Automatic reboot in the daily maintenance window",
   "required": false, "default": false, "secret": false,
   "note": "Only effective with a maximum uptime above 0 and a pending reboot. Off means warning only."}
]
EOF
  exit 0
fi

f_cur_policy="$(f_symbios_var password_policy "")"
f_cur_public="$(f_symbios_var webui_public_access "")"
f_cur_max_days="$(f_symbios_var reboot_max_days 0)"
f_cur_auto="$(f_symbios_var reboot_auto false)"

# inventory.yml keeps inline comments on some defaults. f_symbios_var strips
# quotes only at the end of the line, so remove comments here before reading
# the values into the generic settings form.
f_cur_policy="${f_cur_policy%%#*}"
f_cur_policy="${f_cur_policy%"${f_cur_policy##*[![:space:]]}"}"
f_cur_policy="${f_cur_policy#\'}"
f_cur_policy="${f_cur_policy%\'}"
f_cur_policy="${f_cur_policy#\"}"
f_cur_policy="${f_cur_policy%\"}"
f_cur_public="${f_cur_public%%#*}"
f_cur_public="${f_cur_public%"${f_cur_public##*[![:space:]]}"}"

# Normalize booleans and the day counter so get --json always emits valid
# JSON types, even when inventory.yml holds YAML spellings like "True".
if [[ "${f_cur_public}" == "True" || "${f_cur_public}" == "true" ]]
then
  f_cur_public="true"
else
  f_cur_public="false"
fi
if [[ "${f_cur_auto,,}" == "true" || "${f_cur_auto}" == "1" ]]
then
  f_cur_auto="true"
else
  f_cur_auto="false"
fi
[[ "${f_cur_max_days}" =~ ^[0-9]+$ ]] || f_cur_max_days=0
f_cur_max_days=$((10#${f_cur_max_days}))

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"password_policy": %s, "webui_public_access": %s, "reboot_max_days": %d, "reboot_auto": %s}\n' \
      "$(printf '%s' "${f_cur_policy}" | f_json_escape)" \
      "${f_cur_public}" "${f_cur_max_days}" "${f_cur_auto}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "password_policy=${f_cur_policy}"
  echo "webui_public_access=${f_cur_public}"
  echo "reboot_max_days=${f_cur_max_days}"
  echo "reboot_auto=${f_cur_auto}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_policy=""
f_given_policy="no"
f_new_public=""
f_given_public="no"
f_new_max_days=""
f_given_max_days="no"
f_new_auto=""
f_given_auto="no"
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
    --max-days)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_max_days="$2"
      f_given_max_days="yes"
      shift 2
      ;;
    --max-days=*)
      f_new_max_days="${1#--max-days=}"
      f_given_max_days="yes"
      shift
      ;;
    --auto)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_auto="$2"
      f_given_auto="yes"
      shift 2
      ;;
    --auto=*)
      f_new_auto="${1#--auto=}"
      f_given_auto="yes"
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
      if [[ "${f_json}" == *'"reboot_max_days"'* ]]
      then
        f_new_max_days="$(jq -r '.reboot_max_days' <<< "${f_json}" 2>/dev/null)"
        f_given_max_days="yes"
      fi
      if [[ "${f_json}" == *'"reboot_auto"'* ]]
      then
        f_new_auto="$(jq -r '.reboot_auto' <<< "${f_json}" 2>/dev/null)"
        f_given_auto="yes"
      fi
      shift
      ;;
    --no-apply)
      g_ss_no_apply="yes"
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

if [[ "${f_given_policy}" == "no" && "${f_given_public}" == "no" \
  && "${f_given_max_days}" == "no" && "${f_given_auto}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --policy, --public-access, --max-days and/or --auto"
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

if [[ "${f_given_max_days}" == "yes" ]]
then
  if [[ ! "${f_new_max_days}" =~ ^[0-9]+$ ]]
  then
    f_ss_fail_validation "Invalid --max-days value: ${f_new_max_days} (expected a non-negative integer)"
  fi
  f_new_max_days=$((10#${f_new_max_days}))
fi

if [[ "${f_given_auto}" == "yes" ]]
then
  if ! f_parsed_auto="$(f_ss_parse_bool "${f_new_auto}")"
  then
    f_ss_fail_validation "Invalid --auto value: ${f_new_auto} (expected true|false)"
  fi
  f_new_auto="${f_parsed_auto}"
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
  f_merge_first="no"
fi
if [[ "${f_given_max_days}" == "yes" ]]
then
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge="${f_merge}\"reboot_max_days\": ${f_new_max_days}"
  f_merge_first="no"
fi
if [[ "${f_given_auto}" == "yes" ]]
then
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge="${f_merge}\"reboot_auto\": ${f_new_auto}"
fi
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "security" "${f_check}"
f_ss_finish
exit $?
