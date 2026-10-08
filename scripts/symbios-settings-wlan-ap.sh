#!/bin/bash
# SymbiOS - Manage WLAN access point settings (hostapd).
#
# Settings CLI-first architecture: the WebUI page /settings/wlan-accesspoint/
# is a thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction, real booleans).
#
# Only the stored configuration lives here. Wireless interface discovery
# (iw/ip scans) stays in the WebUI view (host reads, no state), and
# applying stays with base-services/wlan-accesspoint.yml.
#
# Secrets (ap_passphrase) MUST come via --json-stdin, never as argv
# (visible in ps). There is deliberately no --passphrase flag.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage the SymbiOS WLAN access point (hostapd) settings.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json; the
                                  passphrase value is never printed, only
                                  whether one is set)
  set [--interface IF --name SSID --country CC --enabled true|false
       | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  Required: interface, name (SSID). The
                                  passphrase may be empty (open network) but
                                  must be 8+ characters when set. Country is
                                  empty or a 2-letter code. --json-stdin
                                  reads {"ap_interface":..,
                                  "ap_name":.., "ap_passphrase":..,
                                  "ap_country":.., "ap_enabled":..} from
                                  stdin (REQUIRED for the passphrase).
                                  --check validates only, changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (wlan-accesspoint-changed / wlan-accesspoint-unchanged).

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
  get|set|schema)
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
  {"name": "ap_interface", "type": "select", "label": "Wireless interface",
   "required": true, "default": "", "secret": false, "detect": "interfaces"},
  {"name": "ap_name", "type": "text", "label": "WLAN name (SSID)",
   "required": true, "default": "", "secret": false},
  {"name": "ap_passphrase", "type": "password", "label": "WPA passphrase",
   "required": false, "default": "", "secret": true,
   "note": "Empty means open network; 8+ characters when set"},
  {"name": "ap_country", "type": "text", "label": "Country code",
   "required": false, "default": "", "secret": false,
   "placeholder": "DE"},
  {"name": "ap_enabled", "type": "bool", "label": "Enabled",
   "required": true, "default": true, "secret": false}
]
EOF
  exit 0
fi

f_cur_iface="$(f_symbios_var ap_interface "")"
f_cur_name="$(f_symbios_var ap_name "")"
f_cur_country="$(f_symbios_var ap_country "")"
f_cur_enabled="$(f_symbios_var ap_enabled "")"
if [[ "${f_cur_enabled}" == "False" || "${f_cur_enabled}" == "false" ]]
then
  f_cur_enabled="false"
else
  # Same default as the WebUI before (enabled unless stored false).
  f_cur_enabled="true"
fi
f_cur_pw_set="no"
[[ -n "$(f_symbios_var ap_passphrase "")" ]] && f_cur_pw_set="yes"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"ap_interface": %s, "ap_name": %s, "ap_passphrase_set": %s, "ap_country": %s, "ap_enabled": %s}\n' \
      "$(printf '%s' "${f_cur_iface}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_name}" | f_json_escape)" \
      "$([[ "${f_cur_pw_set}" == "yes" ]] && echo "true" || echo "false")" \
      "$(printf '%s' "${f_cur_country}" | f_json_escape)" \
      "${f_cur_enabled}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  echo "ap_interface=${f_cur_iface}"
  echo "ap_name=${f_cur_name}"
  echo "ap_passphrase_set=${f_cur_pw_set}"
  echo "ap_country=${f_cur_country}"
  echo "ap_enabled=${f_cur_enabled}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_iface=""
f_name=""
f_country=""
f_given_country="no"
f_enabled=""
f_given_enabled="no"
f_new_pw=""
f_given_pw="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --interface)
      [[ $# -ge 2 ]] || f_fail_usage
      f_iface="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || f_fail_usage
      f_name="$2"
      shift 2
      ;;
    --country)
      [[ $# -ge 2 ]] || f_fail_usage
      f_country="$2"
      f_given_country="yes"
      shift 2
      ;;
    --enabled)
      [[ $# -ge 2 ]] || f_fail_usage
      f_enabled="$2"
      f_given_enabled="yes"
      shift 2
      ;;
    --passphrase|--passphrase=*)
      f_fail_validation "ap_passphrase is a secret and must be passed via --json-stdin, never as argv"
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
      f_fail_usage
      ;;
  esac
done

if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  for f_field in ap_interface ap_name ap_passphrase ap_country ap_enabled
  do
    [[ "${f_json}" == *'"'"${f_field}"'"'* ]] || continue
    case "${f_field}" in
      ap_enabled)
        # Booleans arrive unquoted - match true/false/1/0 generously,
        # fall back to a quoted string value.
        f_onoff="$(grep -o "\"${f_field}\"[[:space:]]*:[[:space:]]*[^,}]*" <<< "${f_json}" | head -1)"
        f_onoff="${f_onoff##*:}"
        f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
        f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
        f_onoff="${f_onoff%\"}"
        f_onoff="${f_onoff#\"}"
        case "${f_onoff,,}" in
          true|1|yes|on) f_enabled="true" ;;
          false|0|no|off) f_enabled="false" ;;
          *) f_enabled="${f_onoff}" ;;
        esac
        f_given_enabled="yes"
        ;;
      ap_passphrase)
        f_new_pw="$(f_json_get "${f_json}" "${f_field}")" || f_new_pw=""
        # Key presence (checked by the loop) with an empty value clears
        # the stored passphrase.
        f_given_pw="yes"
        ;;
      ap_interface) f_iface="$(f_json_get "${f_json}" "${f_field}")" || f_iface="" ;;
      ap_name) f_name="$(f_json_get "${f_json}" "${f_field}")" || f_name="" ;;
      ap_country)
        f_country="$(f_json_get "${f_json}" "${f_field}")" || f_country=""
        f_given_country="yes"
        ;;
    esac
  done
fi

# --- validation (same rules the WebUI enforced before) ---------------------------

[[ -n "${f_iface}" ]] || f_fail_validation "Please select a wireless interface"
[[ -n "${f_name}" ]] || f_fail_validation "Please enter a WLAN name (SSID)"
if [[ "${f_given_pw}" == "yes" && -n "${f_new_pw}" && "${#f_new_pw}" -lt 8 ]]
then
  f_fail_validation "WPA passphrase must be at least 8 characters"
fi
if [[ "${f_given_country}" == "yes" ]]
then
  f_country="${f_country^^}"
  if [[ -n "${f_country}" ]] \
    && { [[ "${#f_country}" != "2" ]] || ! [[ "${f_country}" =~ ^[A-Z]+$ ]]; }
  then
    f_fail_validation "Country code must be two letters (e.g. DE, US)"
  fi
else
  f_country="${f_cur_country}"
fi
if [[ "${f_given_enabled}" == "yes" ]]
then
  case "${f_enabled,,}" in
    true|1|yes|on) f_enabled="true" ;;
    false|0|no|off) f_enabled="false" ;;
    *) f_fail_validation "Invalid --enabled value: ${f_enabled} (expected true|false)" ;;
  esac
else
  f_enabled="${f_cur_enabled}"
fi
if [[ "${f_iface}" == *$'\n'* ]] || [[ "${f_name}" == *$'\n'* ]]
then
  f_fail_validation "Interface and name must be single-line values"
fi

# --- transactional write (empty passphrase clears the stored one) ------------------

f_merge="$(printf '{"ap_interface": %s, "ap_name": %s, "ap_country": %s, "ap_enabled": %s, "ap_configured": true' \
  "$(printf '%s' "${f_iface}" | f_json_escape)" \
  "$(printf '%s' "${f_name}" | f_json_escape)" \
  "$(printf '%s' "${f_country}" | f_json_escape)" \
  "${f_enabled}")"
if [[ "${f_given_pw}" == "yes" ]]
then
  f_merge="${f_merge}, \"ap_passphrase\": $(printf '%s' "${f_new_pw}" | f_json_escape)"
fi
f_merge="${f_merge}}"

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
  g_echo_note "wlan-accesspoint-unchanged"
else
  g_echo_note "wlan-accesspoint-changed"
fi
exit 0
