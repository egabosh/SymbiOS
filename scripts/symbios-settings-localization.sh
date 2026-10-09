#!/bin/bash
# SymbiOS - Manage localization settings (timezone, keyboard, locale).
#
# This is the pilot script for the Settings CLI-first architecture: the
# WebUI page /settings/localization/ is a thin wrapper around this script,
# which owns validation and the inventory.yml write. CLI and WebUI behavior
# are identical by construction.
#
# The inventory write goes through symbios-inventory.py (merge, one
# transaction); this script only validates domain logic.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS localization settings (timezone, keyboard layout, locale).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--timezone TZ --keyboard KB --locale LOC | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  Options left out keep their current value.
                                  --json-stdin reads {"timezone":..,
                                  "keyboard":..,"locale":..} from stdin.
                                  --check reports what would change,
                                  changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  keyboards                       List available keyboard layouts
                                  (wraps symbios-list-keyboards.sh)
  timezones                       List available timezones
                                  (from timedatectl on the host)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (localization-changed / localization-unchanged) so callers
such as Ansible and the WebUI can detect a real change.

Examples:
  $(basename "$0") get
  $(basename "$0") set --timezone Europe/Berlin --keyboard de --locale de_DE.UTF-8
  echo '{"timezone":"Europe/Berlin"}' | $(basename "$0") set --json-stdin
  $(basename "$0") set --timezone Mars/Olympus --check

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (unknown timezone/keyboard, bad locale, ...)
  1  technical error (inventory unreadable, helper failed, ...)
EOF
}

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

# --- option parsing (before sourcing libs, so --help is cheap) ---------------

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema|keyboards|timezones)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

# --- subcommand: keyboards / timezones (pure reads, no inventory) -------------

if [[ "${f_command}" == "keyboards" ]]
then
  "$g_symbios_dir/symbios-list-keyboards.sh"
  exit $?
fi

if [[ "${f_command}" == "timezones" ]]
then
  if ! timedatectl list-timezones 2>/dev/null
  then
    f_ss_fail_technical "timedatectl list-timezones failed"
  fi
  exit 0
fi

# --- subcommand: schema -------------------------------------------------------

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "timezone", "type": "select", "label": "Timezone",
   "required": true, "default": "UTC", "detect": "timezones", "secret": false},
  {"name": "keyboard", "type": "select", "label": "Keyboard layout",
   "required": true, "default": "us", "detect": "keyboards", "secret": false},
  {"name": "locale", "type": "text", "label": "Locale",
   "required": true, "default": "en_US.UTF-8",
   "pattern": "^[A-Za-z_]+(\\.[A-Za-z0-9-]+)?(@[a-zA-Z]+)?$",
   "placeholder": "en_US.UTF-8", "secret": false}
]
EOF
  exit 0
fi

# --- current values ------------------------------------------------------------

f_cur_timezone="$(f_symbios_var timezone "")"
f_cur_keyboard="$(f_symbios_var keyboard "")"
f_cur_locale="$(f_symbios_var locale "")"
f_cur_configured="$(f_symbios_var localization_configured "")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"timezone": %s, "keyboard": %s, "locale": %s, "localization_configured": %s}\n' \
      "$(printf '%s' "${f_cur_timezone}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_keyboard}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_locale}" | f_json_escape)" \
      "$([[ "${f_cur_configured}" == "true" ]] && echo "true" || echo "false")"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "timezone=${f_cur_timezone}"
  echo "keyboard=${f_cur_keyboard}"
  echo "locale=${f_cur_locale}"
  echo "localization_configured=${f_cur_configured}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_timezone=""
f_new_keyboard=""
f_new_locale=""
f_given_timezone="no"
f_given_keyboard="no"
f_given_locale="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --timezone)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_timezone="$2"
      f_given_timezone="yes"
      shift 2
      ;;
    --keyboard)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_keyboard="$2"
      f_given_keyboard="yes"
      shift 2
      ;;
    --locale)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_locale="$2"
      f_given_locale="yes"
      shift 2
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

# Values via stdin JSON (used by callers that already hold JSON, and for
# future secret-carrying domains sharing this template - never via argv).
if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  f_val="$(f_json_get "${f_json}" "timezone" 2>/dev/null)" && [[ -n "${f_val}" ]] && {
    f_new_timezone="${f_val}"
    f_given_timezone="yes"
  }
  f_val="$(f_json_get "${f_json}" "keyboard" 2>/dev/null)" && [[ -n "${f_val}" ]] && {
    f_new_keyboard="${f_val}"
    f_given_keyboard="yes"
  }
  f_val="$(f_json_get "${f_json}" "locale" 2>/dev/null)" && [[ -n "${f_val}" ]] && {
    f_new_locale="${f_val}"
    f_given_locale="yes"
  }
fi

if [[ "${f_given_timezone}" == "no" && "${f_given_keyboard}" == "no" \
   && "${f_given_locale}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --timezone, --keyboard, --locale or --json-stdin"
fi

# Options left out keep their current value.
[[ "${f_given_timezone}" == "no" ]] && f_new_timezone="${f_cur_timezone}"
[[ "${f_given_keyboard}" == "no" ]] && f_new_keyboard="${f_cur_keyboard}"
[[ "${f_given_locale}" == "no" ]] && f_new_locale="${f_cur_locale}"

# --- validation ---------------------------------------------------------------

# Single-line values only (multi-line would break key=value output and the
# ansible templates consuming these vars).
for f_pair in "timezone:${f_new_timezone}" "keyboard:${f_new_keyboard}" \
  "locale:${f_new_locale}"
do
  f_name="${f_pair%%:*}"
  f_val="${f_pair#*:}"
  if [[ -z "${f_val}" ]]
  then
    f_ss_fail_validation "${f_name} must not be empty"
  fi
  if [[ "${f_val}" == *$'\n'* ]]
  then
    f_ss_fail_validation "${f_name} must be a single line"
  fi
done

# Timezone must exist on the host (authoritative list). If timedatectl is
# unavailable the non-empty check above is all we can do.
if f_tz_list="$(timedatectl list-timezones 2>/dev/null)" && [[ -n "${f_tz_list}" ]]
then
  if ! grep -qxF "${f_new_timezone}" <<< "${f_tz_list}"
  then
    f_ss_fail_validation "Unknown timezone: ${f_new_timezone}"
  fi
fi

# Keyboard must exist in the XKB list when the list is available. On hosts
# without X11 data the list is empty and any non-empty layout is accepted.
if f_kb_list="$("$g_symbios_dir/symbios-list-keyboards.sh" 2>/dev/null)" && [[ -n "${f_kb_list}" ]]
then
  if ! grep -qxF "${f_new_keyboard}" <<< "${f_kb_list}"
  then
    f_ss_fail_validation "Unknown keyboard layout: ${f_new_keyboard}"
  fi
fi

# Locale syntax: language[_territory][.codeset][@modifier], e.g. de_DE.UTF-8.
if ! [[ "${f_new_locale}" =~ ^[A-Za-z_]+(\.[A-Za-z0-9-]+)?(@[a-zA-Z]+)?$ ]]
then
  f_ss_fail_validation "Invalid locale: ${f_new_locale} (expected e.g. de_DE.UTF-8)"
fi

# --- transactional write -------------------------------------------------------

f_merge="$(printf '{"timezone": %s, "keyboard": %s, "locale": %s, "localization_configured": true}' \
  "$(printf '%s' "${f_new_timezone}" | f_json_escape)" \
  "$(printf '%s' "${f_new_keyboard}" | f_json_escape)" \
  "$(printf '%s' "${f_new_locale}" | f_json_escape)")"

f_ss_merge "${f_merge}" "localization" "${f_check}" \
  "${f_new_timezone} ${f_new_keyboard} ${f_new_locale}"
exit 0
