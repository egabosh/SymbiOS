#!/bin/bash
# SymbiOS - Manage port-forwarding inventory state (mode flags, UFW list).
#
# Settings CLI-first architecture: the WebUI page /settings/port-forwarding/
# is a thin wrapper around this script for everything it stores in
# inventory.yml. Router control itself (detect/list/add/delete/config,
# static IP) stays with symbios-router-upnp.sh - the view calls that
# directly and only records state here.
#
# Stored state:
#   port_forwarding_method                 auto|manual|'' (how rules are made)
#   port_forwarding_configured             standard web forwards present
#   port_forwarding_static_ip_configured   server IPv4 pinned on the router
#   ufw_extra_inbound                      [{port, proto}] for IPv6 forwards
#                                          (re-opened on reapply)

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage port-forwarding inventory state (router rules stay with
symbios-router-upnp.sh).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--method auto|manual|"" --configured true|false
       --static-ip-configured true|false] [--check]
                                  Validate and write the flags. --method
                                  manual marks both configured flags done
                                  (the user handles the router by hand);
                                  auto or empty clears them (real router
                                  state decides again). Options left out
                                  keep their values. --check changes nothing.
  ufw-add --port PORT --proto tcp|udp [--check]
                                  Record an IPv6 forward (skipped when
                                  already present).
  ufw-remove --port PORT --proto tcp|udp [--check]
                                  Forget a recorded IPv6 forward.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (port-forwarding-changed / port-forwarding-unchanged).

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

# Normalize a boolean word to true/false, or fail.
function f_parse_bool {
  case "${1,,}" in
    true|1|yes|on) echo "true" ;;
    false|0|no|off) echo "false" ;;
    *) return 1 ;;
  esac
}

# Validate a port/proto pair, echo the canonical entry JSON on success.
function f_ufw_entry {
  local f_port="$1" f_proto="$2"
  f_proto="${f_proto,,}"
  # The 10# prefix forces decimal: leading zeros (080) must not parse as
  # octal (bash arithmetic) nor fail printf %d.
  if ! [[ "${f_port}" =~ ^[0-9]+$ ]] || [[ "10#${f_port}" -lt 1 || "10#${f_port}" -gt 65535 ]]
  then
    return 1
  fi
  if [[ "${f_proto}" != "tcp" && "${f_proto}" != "udp" ]]
  then
    return 1
  fi
  # Canonicalize via arithmetic (strips leading zeros, so 080 matches
  # 80 - same as the WebUI int() did). Printf itself knows no 10# prefix.
  printf '{"port": %d, "proto": "%s"}' "$((10#${f_port}))" "${f_proto}"
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|ufw-add|ufw-remove|schema)
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

f_inv() {
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" "$@"
}

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "port_forwarding_method", "type": "select", "label": "Method",
   "required": false, "default": "", "secret": false,
   "options": ["", "auto", "manual"]},
  {"name": "port_forwarding_configured", "type": "bool", "label": "Standard forwards present",
   "required": true, "default": false, "secret": false},
  {"name": "port_forwarding_static_ip_configured", "type": "bool", "label": "Static IP settled",
   "required": true, "default": false, "secret": false}
]
EOF
  exit 0
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    f_method="$(f_symbios_var port_forwarding_method "")"
    f_conf="$(f_symbios_var port_forwarding_configured "")"
    [[ "${f_conf}" == "True" || "${f_conf}" == "true" ]] && f_conf="true" || f_conf="false"
    f_static="$(f_symbios_var port_forwarding_static_ip_configured "")"
    [[ "${f_static}" == "True" || "${f_static}" == "true" ]] && f_static="true" || f_static="false"
    f_ufw="$(f_inv get --json ufw_extra_inbound 2>/dev/null)" || f_ufw="[]"
    printf '{"port_forwarding_method": %s, "port_forwarding_configured": %s, "port_forwarding_static_ip_configured": %s, "ufw_extra_inbound": %s}\n' \
      "$(printf '%s' "${f_method}" | f_json_escape)" \
      "${f_conf}" \
      "${f_static}" \
      "${f_ufw}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  echo "port_forwarding_method=$(f_symbios_var port_forwarding_method "")"
  echo "port_forwarding_configured=$(f_symbios_var port_forwarding_configured "")"
  echo "port_forwarding_static_ip_configured=$(f_symbios_var port_forwarding_static_ip_configured "")"
  f_inv get --json ufw_extra_inbound 2>/dev/null || echo "[]"
  exit 0
fi

# --- subcommands ufw-add / ufw-remove --------------------------------------------

if [[ "${f_command}" == "ufw-add" || "${f_command}" == "ufw-remove" ]]
then
  f_port=""
  f_proto=""
  f_check="no"
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --port)
        [[ $# -ge 2 ]] || f_fail_usage
        f_port="$2"
        shift 2
        ;;
      --proto)
        [[ $# -ge 2 ]] || f_fail_usage
        f_proto="$2"
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
  if ! f_entry="$(f_ufw_entry "${f_port}" "${f_proto}")"
  then
    f_fail_validation "Invalid port/proto: ${f_port}/${f_proto} (expected 1-65535 + tcp|udp)"
  fi
  f_op="list-add"
  [[ "${f_command}" == "ufw-remove" ]] && f_op="list-del"
  f_check_flag=""
  [[ "${f_check}" == "yes" ]] && f_check_flag="--check"
  if ! f_out="$(printf '%s' "${f_entry}" | f_inv "${f_op}" ufw_extra_inbound ${f_check_flag} 2>&1)"
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
    g_echo_note "port-forwarding-unchanged"
  else
    g_echo_note "port-forwarding-changed"
  fi
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_method=""
f_given_method="no"
f_conf=""
f_given_conf="no"
f_static=""
f_given_static="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --method)
      [[ $# -ge 2 ]] || f_fail_usage
      f_method="$2"
      f_given_method="yes"
      shift 2
      ;;
    --configured)
      [[ $# -ge 2 ]] || f_fail_usage
      f_conf="$2"
      f_given_conf="yes"
      shift 2
      ;;
    --static-ip-configured)
      [[ $# -ge 2 ]] || f_fail_usage
      f_static="$2"
      f_given_static="yes"
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

f_merge="{"
f_merge_first="yes"
if [[ "${f_given_method}" == "yes" ]]
then
  case "${f_method}" in
    auto|manual|"") ;;
    *) f_fail_validation "Invalid --method: ${f_method} (expected auto|manual|\"\")" ;;
  esac
  f_merge="${f_merge}\"port_forwarding_method\": $(printf '%s' "${f_method}" | f_json_escape)"
  f_merge_first="no"
  # Manual mode trusts the user's hand-made router setup (both steps
  # done); automatic mode lets the real router state decide again.
  if [[ "${f_method}" == "manual" ]]
  then
    f_merge="${f_merge}, \"port_forwarding_configured\": true, \"port_forwarding_static_ip_configured\": true"
  else
    f_merge="${f_merge}, \"port_forwarding_configured\": false, \"port_forwarding_static_ip_configured\": false"
  fi
fi
if [[ "${f_given_conf}" == "yes" ]]
then
  f_conf="$(f_parse_bool "${f_conf}")" \
    || f_fail_validation "Invalid --configured value: ${f_conf} (expected true|false)"
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge_first="no"
  f_merge="${f_merge}\"port_forwarding_configured\": ${f_conf}"
fi
if [[ "${f_given_static}" == "yes" ]]
then
  f_static="$(f_parse_bool "${f_static}")" \
    || f_fail_validation "Invalid --static-ip-configured value: ${f_static} (expected true|false)"
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge_first="no"
  f_merge="${f_merge}\"port_forwarding_static_ip_configured\": ${f_static}"
fi
f_merge="${f_merge}}"

if [[ "${f_merge}" == "{}" ]]
then
  f_fail_validation "Nothing to set - pass --method, --configured and/or --static-ip-configured"
fi

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
  g_echo_note "port-forwarding-unchanged"
else
  g_echo_note "port-forwarding-changed"
fi
exit 0
