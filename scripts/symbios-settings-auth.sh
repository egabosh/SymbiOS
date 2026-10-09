#!/bin/bash
# SymbiOS - Manage login/2FA settings (twofa_enabled).
#
# Settings CLI-first architecture: the WebUI page /settings/auth/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction, real JSON booleans).
#
# Enabling 2FA requires a configured SMTP server (smtp_server + smtp_from),
# because Authelia sends the second factor by mail - this precondition used
# to live in the WebUI view and now lives here, so CLI and WebUI agree.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS login and two-factor authentication settings.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set --twofa true|false [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads {"twofa_enabled": ..}.
                                  Enabling requires smtp_server and
                                  smtp_from to be configured.
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (auth-changed / auth-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (2FA without SMTP, bad boolean, ...)
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
  {"name": "twofa_enabled", "type": "bool", "label": "Two-factor authentication",
   "required": true, "default": false, "secret": false,
   "needs": ["smtp_server", "smtp_from"]}
]
EOF
  exit 0
fi

f_cur_twofa="$(f_symbios_var twofa_enabled "")"
if [[ "${f_cur_twofa}" == "True" || "${f_cur_twofa}" == "true" ]]
then
  f_cur_twofa="true"
else
  f_cur_twofa="false"
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"twofa_enabled": %s}\n' "${f_cur_twofa}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "twofa_enabled=${f_cur_twofa}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_twofa=""
f_given_twofa="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --twofa)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_twofa="$2"
      f_given_twofa="yes"
      shift 2
      ;;
    --twofa=*)
      f_new_twofa="${1#--twofa=}"
      f_given_twofa="yes"
      shift
      ;;
    --json-stdin)
      f_json="$(cat)"
      # Booleans arrive unquoted - match generously, fall back to a
      # quoted string value.
      f_onoff="$(grep -o '"twofa_enabled"[[:space:]]*:[[:space:]]*[^,}]*' <<< "${f_json}" | head -1)"
      f_onoff="${f_onoff##*:}"
      f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
      f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
      f_onoff="${f_onoff%\"}"
      f_onoff="${f_onoff#\"}"
      f_new_twofa="${f_onoff}"
      f_given_twofa="yes"
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

if [[ "${f_given_twofa}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --twofa true|false"
fi

if ! f_parsed_twofa="$(f_ss_parse_bool "${f_new_twofa}")"
then
  f_ss_fail_validation "Invalid --twofa value: ${f_new_twofa} (expected true|false)"
fi
f_new_twofa="${f_parsed_twofa}"

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

# --- transactional write (real JSON boolean) -----------------------------------

f_ss_merge "$(printf '{"twofa_enabled": %s}' "${f_new_twofa}")" "auth" "${f_check}"
exit 0
