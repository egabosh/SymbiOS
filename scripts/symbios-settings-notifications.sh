#!/bin/bash
# SymbiOS - Manage notification targets (mail / matrix toggles, level).
#
# Settings CLI-first architecture: the WebUI page /settings/notifications/
# is a thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction, real booleans).
#
# Enabling a target requires its sender to be configured: mail needs the
# SMTP relay (smtp_server + smtp_from), matrix needs a complete sender
# account (homeserver + user + room + password or token). These
# preconditions used to live in the WebUI view and now live here, so CLI
# and WebUI agree. Test delivery (test mail, test matrix message) stays in
# the WebUI (probes, no host state - explicit non-goal, see AGENTS.md).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS notification targets (mail / matrix).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--mail true|false --matrix true|false --to ADDRESS
       --level warn|error] [--check]
                                  Validate and write to inventory.yml.
                                  Enabling mail requires smtp_server and
                                  smtp_from; enabling matrix requires a
                                  complete matrix account. An empty --to
                                  deletes the recipient address.
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (notifications-changed / notifications-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (target without sender, bad email, ...)
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
  {"name": "notify_mail_enabled", "type": "bool", "label": "Mail notifications",
   "required": true, "default": false, "secret": false,
   "needs": ["smtp_server", "smtp_from"]},
  {"name": "notify_matrix_enabled", "type": "bool", "label": "Matrix notifications",
   "required": true, "default": false, "secret": false,
   "needs": ["matrix_homeserver", "matrix_user", "matrix_room"]},
  {"name": "notify_mail_to", "type": "text", "label": "Recipient address",
   "required": false, "default": "", "secret": false},
  {"name": "notify_level", "type": "select", "label": "Level",
   "required": true, "default": "warn", "secret": false,
   "options": ["warn", "error"]}
]
EOF
  exit 0
fi

f_cur_mail="$(f_symbios_var notify_mail_enabled "")"
[[ "${f_cur_mail}" == "True" || "${f_cur_mail}" == "true" ]] \
  && f_cur_mail="true" || f_cur_mail="false"
f_cur_matrix="$(f_symbios_var notify_matrix_enabled "")"
[[ "${f_cur_matrix}" == "True" || "${f_cur_matrix}" == "true" ]] \
  && f_cur_matrix="true" || f_cur_matrix="false"
f_cur_to="$(f_symbios_var notify_mail_to "")"
f_cur_level="$(f_symbios_var notify_level "warn")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"notify_mail_enabled": %s, "notify_matrix_enabled": %s, "notify_mail_to": %s, "notify_level": %s}\n' \
      "${f_cur_mail}" \
      "${f_cur_matrix}" \
      "$(printf '%s' "${f_cur_to}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_level}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "notify_mail_enabled=${f_cur_mail}"
  echo "notify_matrix_enabled=${f_cur_matrix}"
  echo "notify_mail_to=${f_cur_to}"
  echo "notify_level=${f_cur_level}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_mail=""
f_given_mail="no"
f_new_matrix=""
f_given_matrix="no"
f_new_to=""
f_given_to="no"
f_new_level=""
f_given_level="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --mail)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_mail="$2"
      f_given_mail="yes"
      shift 2
      ;;
    --mail=*)
      f_new_mail="${1#--mail=}"
      f_given_mail="yes"
      shift
      ;;
    --matrix)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_matrix="$2"
      f_given_matrix="yes"
      shift 2
      ;;
    --matrix=*)
      f_new_matrix="${1#--matrix=}"
      f_given_matrix="yes"
      shift
      ;;
    --to)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_to="$2"
      f_given_to="yes"
      shift 2
      ;;
    --level)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_level="$2"
      f_given_level="yes"
      shift 2
      ;;
    --json-stdin)
      # Full field object for generic callers. Booleans arrive unquoted.
      f_json="$(cat)"
      for f_field in notify_mail_enabled notify_matrix_enabled notify_mail_to notify_level
      do
        [[ "${f_json}" == *'"'"${f_field}"'"'* ]] || continue
        f_onoff="$(grep -o "\"${f_field}\"[[:space:]]*:[[:space:]]*[^,}]*" <<< "${f_json}" | head -1)"
        f_onoff="${f_onoff##*:}"
        f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
        f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
        f_onoff="${f_onoff%\"}"
        f_onoff="${f_onoff#\"}"
        case "${f_field}" in
          notify_mail_enabled)
            f_new_mail="${f_onoff}"
            f_given_mail="yes"
            ;;
          notify_matrix_enabled)
            f_new_matrix="${f_onoff}"
            f_given_matrix="yes"
            ;;
          notify_mail_to)
            f_new_to="$(f_json_get "${f_json}" "${f_field}")" || f_new_to=""
            f_given_to="yes"
            ;;
          notify_level)
            f_new_level="$(f_json_get "${f_json}" "${f_field}")" || f_new_level=""
            f_given_level="yes"
            ;;
        esac
      done
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

if [[ "${f_given_mail}" == "no" && "${f_given_matrix}" == "no" \
   && "${f_given_to}" == "no" && "${f_given_level}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --mail, --matrix, --to and/or --level"
fi

if [[ "${f_given_mail}" == "yes" ]]
then
  if ! f_parsed_bool="$(f_ss_parse_bool "${f_new_mail}")"
  then
    f_ss_fail_validation "Invalid --mail value: ${f_new_mail} (expected true|false)"
  fi
  f_new_mail="${f_parsed_bool}"
fi
if [[ "${f_given_matrix}" == "yes" ]]
then
  if ! f_parsed_bool="$(f_ss_parse_bool "${f_new_matrix}")"
  then
    f_ss_fail_validation "Invalid --matrix value: ${f_new_matrix} (expected true|false)"
  fi
  f_new_matrix="${f_parsed_bool}"
fi

[[ "${f_given_mail}" == "no" ]] && f_new_mail="${f_cur_mail}"
[[ "${f_given_matrix}" == "no" ]] && f_new_matrix="${f_cur_matrix}"
if [[ "${f_given_level}" == "no" ]]
then
  f_new_level="${f_cur_level}"
elif [[ "${f_new_level}" != "warn" && "${f_new_level}" != "error" ]]
then
  # Same leniency as the WebUI before: unknown levels fall back to warn.
  f_new_level="warn"
fi

# --- preconditions (same rules the WebUI enforced before) ------------------------

if [[ "${f_new_mail}" == "true" ]]
then
  if [[ -z "$(f_symbios_var smtp_server "")" ]] \
    || [[ -z "$(f_symbios_var smtp_from "")" ]]
  then
    f_ss_fail_validation "Cannot enable mail notifications: no SMTP server configured (set it up under Settings Email Sending first)"
  fi
fi
if [[ "${f_new_matrix}" == "true" ]]
then
  if [[ -z "$(f_symbios_var matrix_homeserver "")" ]] \
    || [[ -z "$(f_symbios_var matrix_user "")" ]] \
    || [[ -z "$(f_symbios_var matrix_room "")" ]] \
    || { [[ -z "$(f_symbios_var matrix_password "")" ]] \
      && [[ -z "$(f_symbios_var matrix_token "")" ]]; }
  then
    f_ss_fail_validation "Cannot enable matrix notifications: no matrix account configured (set it up under Settings Matrix Account first)"
  fi
fi
if [[ "${f_given_to}" == "yes" && -n "${f_new_to}" ]] \
  && ! [[ "${f_new_to}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
then
  f_ss_fail_validation "Invalid recipient email address format"
fi

# --- transactional write (empty recipient deletes the key) -----------------------

f_merge="$(printf '{"notify_mail_enabled": %s, "notify_matrix_enabled": %s, "notify_level": %s' \
  "${f_new_mail}" \
  "${f_new_matrix}" \
  "$(printf '%s' "${f_new_level}" | f_json_escape)")"
if [[ "${f_given_to}" == "yes" ]]
then
  if [[ -z "${f_new_to}" ]]
  then
    f_merge="${f_merge}, \"notify_mail_to\": null"
  else
    f_merge="${f_merge}, \"notify_mail_to\": $(printf '%s' "${f_new_to}" | f_json_escape)"
  fi
fi
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "notifications" "${f_check}"
exit 0
