#!/bin/bash
# SymbiOS - Manage WireGuard client tunnel metadata (inventory).
#
# Settings CLI-first architecture: the WebUI page /settings/wireguard/ is a
# thin wrapper around this script for everything it stores in inventory.yml
# (tunnel metadata dict wireguard_clients + wireguard_configured flag).
# Writes go through symbios-inventory.py (dict-merge: only given fields are
# updated, stored fields are kept - so "enable/disable" is just
# "save --enabled ...").
#
# NOT handled here (stays with the existing scripts/endpoints): uploading the
# .conf config file (symbios-write-wireguard-config.sh, stdin), tunnel
# up/down/enable/disable/delete/log/status (symbios-wireguard-client.sh),
# applying (base-services/wireguard-client.yml). The view chains those
# behind the metadata write.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage WireGuard client tunnel metadata (inventory only).

Commands:
  list [--json]                   Print tunnel names (one per line), or the
                                  whole wireguard_clients dict with --json
  save --name NAME [--enabled true|false] [--dns true|false]
       [--hooks true|false] [--ufw-ports "8123/tcp, ..."] [--check]
                                  Validate and merge into the tunnel entry
                                  (only given fields are updated, stored
                                  fields are kept). Also sets
                                  wireguard_configured. --check changes
                                  nothing.
  remove --name NAME [--check]    Delete the tunnel entry from inventory
                                  (the host-side tunnel is removed by
                                  chaining symbios-wireguard-client.sh
                                  delete). --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  apply [--dry-run]               Resolve consuming playbooks (or show them
                                  with --dry-run) and run each in order.
  -h, --help                      Show this help and exit

The tunnel name doubles as the WireGuard interface name, so it is limited
to 15 characters (Linux IFNAMSIZ).

Output: human status lines. The final line carries a machine-readable
state token (wireguard-changed / wireguard-unchanged).

Examples:
  $(basename "$0") list --json
  $(basename "$0") save --name iot --enabled true --ufw-ports "8123/tcp"
  $(basename "$0") save --name iot --enabled false
  $(basename "$0") remove --name iot

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="wireguard_clients"

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

# The tunnel name is also the interface name (Linux limit: 15 characters).
function f_valid_name {
  [[ -n "$1" ]] && [[ "$1" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  list|save|remove|schema|apply)
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
  {"name": "name", "type": "text", "label": "Tunnel name",
   "required": true, "default": "", "secret": false,
   "pattern": "^[a-zA-Z0-9_-]{1,15}$"},
  {"name": "enabled", "type": "bool", "label": "Enabled",
   "required": false, "default": false, "secret": false},
  {"name": "dns", "type": "bool", "label": "Apply DNS from the config",
   "required": false, "default": false, "secret": false},
  {"name": "hooks", "type": "bool", "label": "Allow config hooks",
   "required": false, "default": false, "secret": false},
  {"name": "ufw_ports", "type": "text", "label": "Allowed ports",
   "required": false, "default": "", "secret": false,
   "placeholder": "8123/tcp, 8889/tcp"}
]
EOF
  exit 0
fi

if [[ "${f_command}" == "list" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
      get --json wireguard_clients 2>/dev/null || echo "{}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for list: $1" >&2
    f_ss_fail_usage
  fi
  # Names via the inventory CLI (no JSON parsing in bash).
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-keys wireguard_clients 2>/dev/null
  exit 0
fi

# --- subcommands save/remove: parse options --------------------------------------

f_name=""
f_enabled=""
f_given_enabled="no"
f_dns=""
f_given_dns="no"
f_hooks=""
f_given_hooks="no"
f_ufw_ports=""
f_given_ufw="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_name="$2"
      shift 2
      ;;
    --enabled)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_enabled="$2"
      f_given_enabled="yes"
      shift 2
      ;;
    --dns)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_dns="$2"
      f_given_dns="yes"
      shift 2
      ;;
    --hooks)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_hooks="$2"
      f_given_hooks="yes"
      shift 2
      ;;
    --ufw-ports)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_ufw_ports="$2"
      f_given_ufw="yes"
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
      f_ss_fail_usage
      ;;
  esac
done

f_valid_name "${f_name}" \
  || f_ss_fail_validation "Invalid tunnel name (1-15 chars, a-z, 0-9, _ and - only)"

if [[ "${f_command}" == "remove" ]]
then
  f_check_flag=""
  [[ "${f_check}" == "yes" ]] && f_check_flag="--check"
  if ! f_out="$("$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-del wireguard_clients "${f_name}" ${f_check_flag} 2>&1)"
  then
    f_ss_fail_technical "Failed to write inventory: ${f_out}"
  fi
  f_ss_result "${f_out}" "wireguard" "${f_check}"
  exit 0
fi

# --- subcommand: save ---------------------------------------------------------------

if [[ "${f_given_enabled}" == "no" && "${f_given_dns}" == "no" \
   && "${f_given_hooks}" == "no" && "${f_given_ufw}" == "no" ]]
then
  f_ss_fail_validation "Nothing to save - pass at least one field option"
fi

if [[ "${f_given_enabled}" == "yes" ]]
then
  if ! f_parsed_bool="$(f_ss_parse_bool "${f_enabled}")"
  then
    f_ss_fail_validation "Invalid --enabled value: ${f_enabled} (expected true|false)"
  fi
  f_enabled="${f_parsed_bool}"
fi
if [[ "${f_given_dns}" == "yes" ]]
then
  if ! f_parsed_bool="$(f_ss_parse_bool "${f_dns}")"
  then
    f_ss_fail_validation "Invalid --dns value: ${f_dns} (expected true|false)"
  fi
  f_dns="${f_parsed_bool}"
fi
if [[ "${f_given_hooks}" == "yes" ]]
then
  if ! f_parsed_bool="$(f_ss_parse_bool "${f_hooks}")"
  then
    f_ss_fail_validation "Invalid --hooks value: ${f_hooks} (expected true|false)"
  fi
  f_hooks="${f_parsed_bool}"
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
      f_ss_fail_validation "Invalid port: ${f_p}"
    fi
    if [[ "${f_proto}" != "tcp" && "${f_proto}" != "udp" ]]
    then
      f_ss_fail_validation "Invalid protocol: ${f_proto}"
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
[[ "${f_given_dns}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"dns\": ${f_dns}"
}
[[ "${f_given_hooks}" == "yes" ]] && {
  [[ "${f_first}" == "yes" ]] || f_entry="${f_entry}, "
  f_first="no"
  f_entry="${f_entry}\"hooks\": ${f_hooks}"
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
  | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" dict-merge wireguard_clients "${f_name}" ${f_check_flag} 2>&1)"
then
  f_ss_fail_technical "Failed to write inventory: ${f_out}"
fi

# The configured flag travels in a second transaction (one save marks the
# domain configured).
if [[ "${f_check}" != "yes" ]] && ! grep -q "^unchanged$" <<< "${f_out}"
then
  if ! f_flag_out="$(printf '%s' '{"wireguard_configured": true}' \
    | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge 2>&1)"
  then
    f_ss_fail_technical "Failed to write inventory: ${f_flag_out}"
  fi
  f_out="${f_out}
${f_flag_out}"
fi

f_ss_result "${f_out}" "wireguard" "${f_check}"
exit 0
