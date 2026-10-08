#!/bin/bash
# SymbiOS - Manage OpenVPN client tunnels (inventory metadata).
#
# Settings CLI-first architecture: the WebUI page /settings/openvpn/ is a
# thin wrapper around this script for everything it stores in inventory.yml
# (tunnel metadata dict openvpn_clients + openvpn_configured flag). Writes
# go through symbios-inventory.py (dict-merge: only given fields are
# updated, stored fields are kept - so "enable/disable" is just
# "save --enabled ...").
#
# NOT handled here (stays with the existing scripts/endpoints): uploading
# the .ovpn config file (symbios-write-openvpn-config.sh, stdin),
# tunnel up/down/delete/fetch/log/status (symbios-openvpn-client.sh),
# applying (base-services/openvpn-client.yml). The view chains those
# behind the metadata write.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage OpenVPN client tunnel metadata (inventory only).

Commands:
  list [--json]                   Print tunnel names (one per line), or the
                                  whole openvpn_clients dict with --json
  save --name NAME [--mode upload|fetch --interface IF --fetch-cmd CMD
       --cron CRON --ufw-ports "8123/tcp, ..." --enabled true|false]
       [--check]
                                  Validate and merge into the tunnel entry
                                  (only given fields are updated, stored
                                  fields are kept). Also sets
                                  openvpn_configured. --mode fetch needs a
                                  non-empty --fetch-cmd in the same call.
                                  --check changes nothing.
  remove --name NAME [--check]    Delete the tunnel entry from inventory
                                  (the host-side tunnel is removed by
                                  chaining symbios-openvpn-client.sh
                                  delete). --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (openvpn-changed / openvpn-unchanged).

Examples:
  $(basename "$0") list --json
  $(basename "$0") save --name office --mode upload --interface tun0 --enabled true
  $(basename "$0") save --name office --enabled false
  $(basename "$0") remove --name office

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

function f_valid_name {
  [[ -n "$1" ]] && [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  list|save|remove|schema)
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
  {"name": "name", "type": "text", "label": "Tunnel name",
   "required": true, "default": "", "secret": false,
   "pattern": "^[a-zA-Z0-9_-]+$"},
  {"name": "mode", "type": "select", "label": "Config source",
   "required": false, "default": "upload", "secret": false,
   "options": ["upload", "fetch"]},
  {"name": "interface", "type": "text", "label": "Interface",
   "required": false, "default": "tun0", "secret": false},
  {"name": "fetch_cmd", "type": "text", "label": "Fetch command",
   "required": false, "default": "", "secret": false},
  {"name": "cron", "type": "text", "label": "Refresh schedule",
   "required": false, "default": "*/5 * * * *", "secret": false},
  {"name": "ufw_ports", "type": "text", "label": "Allowed ports",
   "required": false, "default": "", "secret": false,
   "placeholder": "8123/tcp, 8889/tcp"},
  {"name": "enabled", "type": "bool", "label": "Enabled",
   "required": false, "default": false, "secret": false}
]
EOF
  exit 0
fi

if [[ "${f_command}" == "list" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
      get --json openvpn_clients 2>/dev/null || echo "{}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for list: $1" >&2
    f_fail_usage
  fi
  # Names via the inventory CLI (no JSON parsing in bash).
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-keys openvpn_clients 2>/dev/null
  exit 0
fi

# --- subcommands save/remove: parse options --------------------------------------

f_name=""
f_mode=""
f_given_mode="no"
f_interface=""
f_given_interface="no"
f_fetch_cmd=""
f_given_fetch_cmd="no"
f_cron=""
f_given_cron="no"
f_ufw_ports=""
f_given_ufw="no"
f_enabled=""
f_given_enabled="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || f_fail_usage
      f_name="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || f_fail_usage
      f_mode="$2"
      f_given_mode="yes"
      shift 2
      ;;
    --interface)
      [[ $# -ge 2 ]] || f_fail_usage
      f_interface="$2"
      f_given_interface="yes"
      shift 2
      ;;
    --fetch-cmd)
      [[ $# -ge 2 ]] || f_fail_usage
      f_fetch_cmd="$2"
      f_given_fetch_cmd="yes"
      shift 2
      ;;
    --cron)
      [[ $# -ge 2 ]] || f_fail_usage
      f_cron="$2"
      f_given_cron="yes"
      shift 2
      ;;
    --ufw-ports)
      [[ $# -ge 2 ]] || f_fail_usage
      f_ufw_ports="$2"
      f_given_ufw="yes"
      shift 2
      ;;
    --enabled)
      [[ $# -ge 2 ]] || f_fail_usage
      f_enabled="$2"
      f_given_enabled="yes"
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
      f_fail_usage
      ;;
  esac
done

f_valid_name "${f_name}" \
  || f_fail_validation "Invalid tunnel name (a-z, 0-9, _ and - only)"

if [[ "${f_command}" == "remove" ]]
then
  f_check_flag=""
  [[ "${f_check}" == "yes" ]] && f_check_flag="--check"
  if ! f_out="$("$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-del openvpn_clients "${f_name}" ${f_check_flag} 2>&1)"
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
    g_echo_note "openvpn-unchanged"
  else
    g_echo_note "openvpn-changed"
  fi
  exit 0
fi

# --- subcommand: save ---------------------------------------------------------------

if [[ "${f_given_mode}" == "no" && "${f_given_interface}" == "no" \
   && "${f_given_fetch_cmd}" == "no" && "${f_given_cron}" == "no" \
   && "${f_given_ufw}" == "no" && "${f_given_enabled}" == "no" ]]
then
  f_fail_validation "Nothing to save - pass at least one field option"
fi

if [[ "${f_given_mode}" == "yes" && "${f_mode}" != "upload" && "${f_mode}" != "fetch" ]]
then
  # Same leniency as the WebUI before: unknown modes fall back to upload.
  f_mode="upload"
fi
if [[ "${f_given_interface}" == "yes" ]]
then
  [[ -z "${f_interface}" ]] && f_interface="tun0"
  f_valid_name "${f_interface}" \
    || f_fail_validation "Invalid interface name"
fi
if [[ "${f_given_cron}" == "yes" ]]
then
  [[ -z "${f_cron}" ]] && f_cron="*/5 * * * *"
  if [[ "$(printf '%s' "${f_cron}" | wc -w)" != "5" ]]
  then
    f_fail_validation "Refresh schedule must have 5 fields (e.g. */5 * * * *)"
  fi
fi
if [[ "${f_given_mode}" == "yes" && "${f_mode}" == "fetch" ]]
then
  # Fetch mode needs its command in the same call (stored values are not
  # re-read here; the WebUI form always sends both).
  if [[ "${f_given_fetch_cmd}" == "no" || -z "${f_fetch_cmd}" ]]
  then
    f_fail_validation "Fetch mode needs a fetch command"
  fi
fi
if [[ "${f_given_enabled}" == "yes" ]]
then
  case "${f_enabled,,}" in
    true|1|yes|on) f_enabled="true" ;;
    false|0|no|off) f_enabled="false" ;;
    *) f_fail_validation "Invalid --enabled value: ${f_enabled} (expected true|false)" ;;
  esac
fi

# Parse "8123/tcp, 8889" into a JSON array (same rules as the WebUI).
f_ufw_json="[]"
if [[ "${f_given_ufw}" == "yes" ]]
then
  f_ufw_json="["
  f_first="yes"
  f_rest="${f_ufw_ports},"
  while [[ -n "${f_rest}" ]]
  do
    f_part="${f_rest%%,*}"
    f_rest="${f_rest#*,}"
    # Trim whitespace without external tools.
    f_part="${f_part#"${f_part%%[![:space:]]*}"}"
    f_part="${f_part%"${f_part##*[![:space:]]}"}"
    [[ -z "${f_part}" ]] && continue
    if [[ "${f_part}" == */* ]]
    then
      f_p="${f_part%%/*}"
      f_proto="${f_part#*/}"
    else
      f_p="${f_part}"
      f_proto="tcp"
    fi
    f_p="${f_p#"${f_p%%[![:space:]]*}"}"
    f_p="${f_p%"${f_p##*[![:space:]]}"}"
    f_proto="${f_proto#"${f_proto%%[![:space:]]*}"}"
    f_proto="${f_proto%"${f_proto##*[![:space:]]}"}"
    f_proto="${f_proto,,}"
    if ! [[ "${f_p}" =~ ^[0-9]+$ ]] || [[ "10#${f_p}" -lt 1 || "10#${f_p}" -gt 65535 ]]
    then
      f_fail_validation "Invalid port: ${f_p}"
    fi
    if [[ "${f_proto}" != "tcp" && "${f_proto}" != "udp" ]]
    then
      f_fail_validation "Invalid protocol: ${f_proto}"
    fi
    [[ "${f_first}" == "yes" ]] || f_ufw_json="${f_ufw_json}, "
    f_first="no"
    f_ufw_json="${f_ufw_json}{\"port\": ${f_p}, \"proto\": \"${f_proto}\"}"
  done
  f_ufw_json="${f_ufw_json}]"
fi

# --- transactional entry merge (only given fields) -----------------------------------

f_entry="{"
f_first="yes"
[[ "${f_given_enabled}" == "yes" ]] && {
  f_entry="${f_entry}\"enabled\": ${f_enabled}"
  f_first="no"
}
[[ "${f_given_mode}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"mode\": $(printf '%s' "${f_mode}" | f_json_escape)"
}
[[ "${f_given_interface}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"interface\": $(printf '%s' "${f_interface}" | f_json_escape)"
}
[[ "${f_given_fetch_cmd}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"fetch_cmd\": $(printf '%s' "${f_fetch_cmd}" | f_json_escape)"
}
[[ "${f_given_cron}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"cron\": $(printf '%s' "${f_cron}" | f_json_escape)"
}
[[ "${f_given_ufw}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"ufw_allow\": ${f_ufw_json}"
}
f_entry="${f_entry}}"

f_check_flag=""
[[ "${f_check}" == "yes" ]] && f_check_flag="--check"

if ! f_out="$(printf '%s' "${f_entry}" \
  | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" dict-merge openvpn_clients "${f_name}" ${f_check_flag} 2>&1)"
then
  f_fail_technical "Failed to write inventory: ${f_out}"
fi
g_echo "${f_out}"

# The configured flag travels in a second transaction (same as before: one
# save marks the domain configured).
if [[ "${f_check}" != "yes" ]] && ! grep -q "^unchanged$" <<< "${f_out}"
then
  if ! f_flag_out="$(printf '%s' '{"openvpn_configured": true}' \
    | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge 2>&1)"
  then
    f_fail_technical "Failed to write inventory: ${f_flag_out}"
  fi
  g_echo "${f_flag_out}"
fi

if [[ "${f_check}" == "yes" ]]
then
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

if grep -q "^unchanged$" <<< "${f_out}"
then
  g_echo_note "openvpn-unchanged"
else
  g_echo_note "openvpn-changed"
fi
exit 0
