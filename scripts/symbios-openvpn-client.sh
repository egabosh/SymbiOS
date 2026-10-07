#!/bin/bash
# SymbiOS - Manage OpenVPN client tunnels on the host
# Lists tunnel status for the WebUI (Settings -> OpenVPN Client) and controls
# the openvpn@<name> systemd units. Config files live in /etc/openvpn/<name>.conf
# (0600, may contain private keys). Fetch-mode tunnels additionally own
# /etc/openvpn/fetch-<name>.sh (deployed by the playbook from inventory).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [args]

List OpenVPN client tunnels and control the openvpn@<name> systemd units
for the WebUI (Settings -> OpenVPN Client).

Commands:
  list                  JSON with all tunnels in /etc/openvpn/*.conf
  status <name>         JSON with a single tunnel
  up <name>             Start the tunnel (systemctl start openvpn@<name>)
  down <name>           Stop the tunnel (systemctl stop openvpn@<name>)
  enable <name>         Enable the tunnel at boot
  disable <name>        Disable the tunnel at boot
  delete <name>         Stop/disable the tunnel and remove its config
  fetch <name>          Run /etc/openvpn/fetch-<name>.sh (fetch mode only)
  log <name> [lines]    Last journal lines of openvpn@<name> (default 50)

Examples:
  $(basename "$0") list
  $(basename "$0") up homeassistant-iot

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Check that a tunnel name is safe for use in paths and unit names.
function f_valid_name {
  local f_name="$1"
  [[ "${f_name}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Read the "dev <iface>" directive from a tunnel config (empty when dynamic).
function f_dev_iface {
  local f_conf="$1"
  local f_dev=""
  f_dev="$(grep -E '^[[:space:]]*dev[[:space:]]+' "${f_conf}" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r')"
  if [[ "${f_dev}" == "tun" || "${f_dev}" == "tap" || "${f_dev}" == "null" ]]
  then
    echo ""
  else
    echo "${f_dev}"
  fi
}

# Emit the JSON object for one tunnel (no surrounding array).
function f_tunnel_json {
  local f_name="$1"
  local f_conf="/etc/openvpn/${f_name}.conf"
  local f_active="false"
  local f_enabled="false"
  local f_iface=""
  local f_ip=""
  local f_fetch="false"

  # Service state via systemd (missing unit counts as inactive, not an error).
  if systemctl is-active "openvpn@${f_name}" >/dev/null 2>&1
  then
    f_active="true"
  fi
  if systemctl is-enabled "openvpn@${f_name}" >/dev/null 2>&1
  then
    f_enabled="true"
  fi

  # Interface and IPv4 address from the dev directive.
  f_iface="$(f_dev_iface "${f_conf}")"
  if [[ -n "${f_iface}" ]]
  then
    f_ip="$(ip -o -4 addr show dev "${f_iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  fi

  # Fetch mode when a fetch helper exists for this tunnel.
  if [[ -x "/etc/openvpn/fetch-${f_name}.sh" ]]
  then
    f_fetch="true"
  fi

  printf '{"name":%s,"active":%s,"enabled":%s,"interface":%s,"ip":%s,"fetch_mode":%s}' \
    "$(echo "${f_name}" | f_json_escape)" \
    "${f_active}" \
    "${f_enabled}" \
    "$(echo "${f_iface}" | f_json_escape)" \
    "$(echo "${f_ip}" | f_json_escape)" \
    "${f_fetch}"
}

g_cmd="${1:-list}"

# List all tunnels as a single JSON line (even on expected empty results).
if [[ "${g_cmd}" == "list" ]]
then
  printf '{"tunnels":['
  g_first=1
  for g_conf in /etc/openvpn/*.conf
  do
    [[ -e "${g_conf}" ]] || continue
    g_tunnel="$(basename "${g_conf}" .conf)"
    if [[ "${g_first}" -eq 1 ]]
    then
      g_first=0
    else
      printf ','
    fi
    f_tunnel_json "${g_tunnel}"
  done
  printf '],"openvpn_installed":'
  if command -v openvpn >/dev/null 2>&1
  then
    printf 'true'
  else
    printf 'false'
  fi
  printf '}\n'
  exit 0
fi

# Single-tunnel status as JSON.
if [[ "${g_cmd}" == "status" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ ! -f "/etc/openvpn/${g_name}.conf" ]]
  then
    f_json_error "Tunnel not found: ${g_name}"
  fi
  printf '{"tunnel":'
  f_tunnel_json "${g_name}"
  printf '}\n'
  exit 0
fi

# Start/stop/enable/disable map directly to systemctl on the template unit.
if [[ "${g_cmd}" == "up" || "${g_cmd}" == "down" || "${g_cmd}" == "enable" || "${g_cmd}" == "disable" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ ! -f "/etc/openvpn/${g_name}.conf" ]]
  then
    f_json_error "Tunnel not found: ${g_name}"
  fi
  case "${g_cmd}" in
    up)
      g_action="start"
      ;;
    down)
      g_action="stop"
      ;;
    enable)
      g_action="enable"
      ;;
    disable)
      g_action="disable"
      ;;
  esac
  if systemctl "${g_action}" "openvpn@${g_name}" 2>/dev/null
  then
    printf '{"ok":true,"message":"Tunnel %s: %s done."}\n' "${g_name}" "${g_action}"
  else
    f_json_error "systemctl ${g_action} openvpn@${g_name} failed"
  fi
  exit 0
fi

# Re-fetch the config of a fetch-mode tunnel, then restart it when enabled.
if [[ "${g_cmd}" == "fetch" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ ! -x "/etc/openvpn/fetch-${g_name}.sh" ]]
  then
    f_json_error "No fetch helper for tunnel: ${g_name}"
  fi
  if "/etc/openvpn/fetch-${g_name}.sh" 2>/dev/null
  then
    if systemctl is-enabled "openvpn@${g_name}" >/dev/null 2>&1
    then
      systemctl restart "openvpn@${g_name}" 2>/dev/null || true
    fi
    printf '{"ok":true,"message":"Config for %s refreshed."}\n' "${g_name}"
  else
    f_json_error "Fetch helper failed for tunnel: ${g_name}"
  fi
  exit 0
fi

# Delete a tunnel: stop/disable the unit, remove config, fetch helper and cron.
if [[ "${g_cmd}" == "delete" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  # Stop and disable first - failures are fine (unit may not exist).
  systemctl stop "openvpn@${g_name}" 2>/dev/null || true
  systemctl disable "openvpn@${g_name}" 2>/dev/null || true
  # Remove the config, the fetch helper and the refresh cron entry.
  rm -f "/etc/openvpn/${g_name}.conf" "/etc/openvpn/fetch-${g_name}.sh"
  if crontab -l 2>/dev/null | grep -q "SymbiOS openvpn fetch ${g_name}"
  then
    (crontab -l 2>/dev/null | grep -v "SymbiOS openvpn fetch ${g_name}") | crontab - 2>/dev/null || true
  fi
  printf '{"ok":true,"message":"Tunnel %s deleted."}\n' "${g_name}"
  exit 0
fi

# Last journal lines of a tunnel unit (plain text, for the WebUI log view).
if [[ "${g_cmd}" == "log" ]]
then
  g_name="${2:-}"
  g_lines="${3:-50}"
  if ! f_valid_name "${g_name}"
  then
    echo "Invalid tunnel name" >&2
    exit 1
  fi
  [[ "${g_lines}" =~ ^[0-9]+$ ]] || g_lines=50
  journalctl -u "openvpn@${g_name}" -n "${g_lines}" --no-pager 2>/dev/null || echo "(no log available)"
  exit 0
fi

f_usage >&2
exit 1
