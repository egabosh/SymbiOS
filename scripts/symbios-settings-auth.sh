#!/bin/bash
# SymbiOS - Manage login/2FA settings (twofa_enabled, twofa_lan_bypass).
#
# Settings CLI-first architecture: the WebUI page /settings/auth/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction, real JSON booleans).
#
# Enabling 2FA requires a configured SMTP server (smtp_server + smtp_from),
# because Authelia sends the second factor by mail - this precondition used
# to live in the WebUI view and now lives here, so CLI and WebUI agree.
#
# twofa_lan_bypass downgrades clients from the standard private ranges
# (RFC1918 + ULA + loopback) to one factor via an access control rule and a
# networks rule in the named OIDC client authorization policy, so logins from
# the LAN skip the second factor while remote logins keep it.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS login and two-factor authentication settings.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set --twofa true|false [--lan-bypass true|false] [--check]
                                  Validate and write to inventory.yml.
                                  At least one of --twofa / --lan-bypass is
                                  required. --json-stdin reads a (partial)
                                  object {"twofa_enabled": ..,
                                  "twofa_lan_bypass": ..}. Enabling 2FA
                                  requires smtp_server and smtp_from to be
                                  configured. --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  apply [--dry-run]               Resolve consuming playbooks (or show them
                                  with --dry-run) and run each in order.
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (auth-changed / auth-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (2FA without SMTP, bad boolean, ...)
  1  technical error (inventory unreadable, ...)
EOF
}

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="twofa_enabled twofa_lan_bypass"

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
  {"name": "twofa_enabled", "type": "bool", "label": "Two-factor authentication",
   "required": true, "default": false, "secret": false,
   "needs": ["smtp_server", "smtp_from"]},
  {"name": "twofa_lan_bypass", "type": "bool", "label": "Skip second factor from the LAN",
   "required": false, "default": false, "secret": false}
]
EOF
  exit 0
fi

# Read a boolean inventory key as true/false (absent -> false).
function f_read_bool {
  local f_val
  f_val="$(f_symbios_var "$1" "")"
  if [[ "${f_val}" == "True" || "${f_val}" == "true" ]]
  then
    echo "true"
  else
    echo "false"
  fi
}

# Extract a boolean for one key from a JSON object (unquoted or quoted).
# Prints nothing when the key is absent.
function f_json_bool {
  local f_onoff
  f_onoff="$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*[^,}]*" <<< "${2:-}" | head -1)"
  if [[ -z "${f_onoff}" ]]
  then
    return 0
  fi
  f_onoff="${f_onoff##*:}"
  f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
  f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
  f_onoff="${f_onoff%\"}"
  f_onoff="${f_onoff#\"}"
  echo "${f_onoff}"
}

f_cur_twofa="$(f_read_bool twofa_enabled)"
f_cur_bypass="$(f_read_bool twofa_lan_bypass)"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"twofa_enabled": %s, "twofa_lan_bypass": %s}\n' \
      "${f_cur_twofa}" "${f_cur_bypass}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "twofa_enabled=${f_cur_twofa}"
  echo "twofa_lan_bypass=${f_cur_bypass}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_twofa=""
f_new_bypass=""
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --twofa)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_twofa="$2"
      shift 2
      ;;
    --twofa=*)
      f_new_twofa="${1#--twofa=}"
      shift
      ;;
    --lan-bypass)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_bypass="$2"
      shift 2
      ;;
    --lan-bypass=*)
      f_new_bypass="${1#--lan-bypass=}"
      shift
      ;;
    --json-stdin)
      f_json="$(cat)"
      # Booleans arrive unquoted - match generously, fall back to a
      # quoted string value. Absent keys stay unset.
      if f_val="$(f_json_bool twofa_enabled "${f_json}")" \
        && [[ -n "${f_val}" ]]
      then
        f_new_twofa="${f_val}"
      fi
      if f_val="$(f_json_bool twofa_lan_bypass "${f_json}")" \
        && [[ -n "${f_val}" ]]
      then
        f_new_bypass="${f_val}"
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

f_given_any="no"

if [[ -n "${f_new_twofa}" ]]
then
  if ! f_parsed="$(f_ss_parse_bool "${f_new_twofa}")"
  then
    f_ss_fail_validation "Invalid --twofa value: ${f_new_twofa} (expected true|false)"
  fi
  f_new_twofa="${f_parsed}"
  f_given_any="yes"
fi

if [[ -n "${f_new_bypass}" ]]
then
  if ! f_parsed="$(f_ss_parse_bool "${f_new_bypass}")"
  then
    f_ss_fail_validation "Invalid --lan-bypass value: ${f_new_bypass} (expected true|false)"
  fi
  f_new_bypass="${f_parsed}"
  f_given_any="yes"
fi

if [[ "${f_given_any}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --twofa and/or --lan-bypass (or --json-stdin)"
fi

# 2FA mails the second factor, so enabling without an SMTP sender makes no
# sense (same rule the WebUI enforced before).
if [[ "${f_new_twofa}" == "true" ]]
then
  if [[ -z "$(f_symbios_var smtp_server "")" ]] \
    || [[ -z "$(f_symbios_var smtp_from "")" ]]
  then
    f_ss_fail_validation "Cannot enable 2FA: no SMTP server configured (set smtp_server and smtp_from first)"
  fi
fi

# --- transactional write (real JSON booleans, one merge) ------------------------

# Unspecified keys keep their current value, so the merge always carries both
# managed keys in a single write.
f_eff_twofa="${f_new_twofa:-${f_cur_twofa}}"
f_eff_bypass="${f_new_bypass:-${f_cur_bypass}}"

f_ss_merge "$(printf '{"twofa_enabled": %s, "twofa_lan_bypass": %s}' \
  "${f_eff_twofa}" "${f_eff_bypass}")" "auth" "${f_check}"
exit 0
