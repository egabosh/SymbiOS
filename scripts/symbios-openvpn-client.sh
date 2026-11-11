#!/bin/bash
# SymbiOS - Manage OpenVPN client tunnels on the host
# Lists tunnel status for the WebUI (Settings -> OpenVPN Client) and controls
# the openvpn@<name> systemd units. Tunnel configs hold private keys and live
# encrypted on the data volume (<base-services>/openvpn/<name>.conf, 0700);
# /etc/openvpn/<name>.conf is a bind mount onto them (created by the playbook
# or rc.local after mount), so no plaintext ever lands on the SD card.
# Fetch-mode tunnels additionally own <base-services>/openvpn/fetch-<name>.sh.

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
  enable <name>         Mark the tunnel enabled (inventory) and start it
  disable <name>        Mark the tunnel disabled (inventory) and stop it
  delete <name>         Stop/disable the tunnel and remove its config
  fetch <name>          Refresh the config of a fetch-mode tunnel and
                        restart it only when it changed (delegates to
                        symbios-openvpn-fetch.sh, like the refresh cron)
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

# Encrypted tunnel config directory (0700, on the LUKS volume).
g_ovpn_dir="${g_base_services_root}/openvpn"

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

# Read one boolean field of the tunnel entry from the inventory (default off).
# The unit itself is never systemd-enabled (boot policy: rc.local starts it
# after the mount), so "enabled" can only come from the inventory.
function f_inv_flag {
  local f_tunnel="$1" f_flag="$2" f_entry=""
  f_entry="$("${g_symbios_dir}/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-get openvpn_clients "${f_tunnel}" 2>/dev/null || true)"
  f_entry="${f_entry//[[:space:]]/}"
  [[ "${f_entry}" == *"\"${f_flag}\":true"* ]]
}

# Bind-mount the encrypted config into /etc/openvpn (no-op when done).
# Returns 1 when no config exists (e.g. data volume not mounted).
function f_ensure_bind {
  local f_name="$1"
  local f_src="${g_ovpn_dir}/${f_name}.conf"
  local f_dst="/etc/openvpn/${f_name}.conf"
  [[ -f "${f_src}" ]] || return 1
  if mountpoint -q "${f_dst}" 2>/dev/null
  then
    return 0
  fi
  mkdir -p /etc/openvpn 2>/dev/null || return 1
  touch "${f_dst}" 2>/dev/null || return 1
  chmod 600 "${f_dst}" 2>/dev/null || true
  mount --bind "${f_src}" "${f_dst}" 2>/dev/null
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
  # Enablement is inventory state: the unit is deliberately never
  # systemd-enabled (boot policy, started from rc.local after the mount).
  if f_inv_flag "${f_name}" "enabled"
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
  if [[ -x "${g_ovpn_dir}/fetch-${f_name}.sh" ]]
  then
    f_fetch="true"
  fi

  printf '{"name":%s,"active":%s,"enabled":%s,"interface":%s,"ip":%s,"fetch_mode":%s}' \
    "$(printf '%s' "${f_name}" | f_json_escape)" \
    "${f_active}" \
    "${f_enabled}" \
    "$(printf '%s' "${f_iface}" | f_json_escape)" \
    "$(printf '%s' "${f_ip}" | f_json_escape)" \
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
    # Skip empty bind placeholders (no encrypted config mounted yet).
    [[ -s "${g_conf}" ]] || continue
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
  if [[ ! -s "/etc/openvpn/${g_name}.conf" && ! -s "${g_ovpn_dir}/${g_name}.conf" ]]
  then
    f_json_error "Tunnel not found: ${g_name}"
  fi
  printf '{"tunnel":'
  f_tunnel_json "${g_name}"
  printf '}\n'
  exit 0
fi

# Enable/disable persist the inventory flag (rc.local starts enabled tunnels
# after the mount) and apply the state right away. The unit is deliberately
# never systemd-enabled (boot policy), so the flag is the only source of
# truth - `systemctl is-enabled` always answers "disabled" by design.
if [[ "${g_cmd}" == "enable" || "${g_cmd}" == "disable" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ ! -s "/etc/openvpn/${g_name}.conf" && ! -s "${g_ovpn_dir}/${g_name}.conf" ]]
  then
    f_json_error "Tunnel not found: ${g_name}"
  fi
  if [[ "${g_cmd}" == "enable" ]]
  then
    g_flag="true"
    g_action="start"
  else
    g_flag="false"
    g_action="stop"
  fi
  if ! "${g_symbios_dir}/symbios-settings-openvpn.sh" save \
    --name "${g_name}" --enabled "${g_flag}" >/dev/null 2>&1
  then
    f_json_error "Failed to update the inventory entry of ${g_name}"
  fi
  # A tunnel that is enabled but has no config yet stays down (no config).
  if [[ "${g_action}" == "start" ]]
  then
    f_ensure_bind "${g_name}" >/dev/null 2>&1 || true
  fi
  systemctl "${g_action}" "openvpn@${g_name}" 2>/dev/null || true
  printf '{"ok":true,"message":"Tunnel %s: %s done."}\n' "${g_name}" "${g_action}"
  exit 0
fi

# Start/stop map directly to systemctl on the template unit.
if [[ "${g_cmd}" == "up" || "${g_cmd}" == "down" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  # Starting needs the bound config - bind it now when the volume is there.
  if [[ "${g_cmd}" == "up" ]]
  then
    if ! f_ensure_bind "${g_name}"
    then
      f_json_error "No config for tunnel ${g_name} (data volume mounted?)"
    fi
  elif [[ ! -s "/etc/openvpn/${g_name}.conf" && ! -s "${g_ovpn_dir}/${g_name}.conf" ]]
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
  esac
  if systemctl "${g_action}" "openvpn@${g_name}" 2>/dev/null
  then
    printf '{"ok":true,"message":"Tunnel %s: %s done."}\n' "${g_name}" "${g_action}"
  else
    f_json_error "systemctl ${g_action} openvpn@${g_name} failed"
  fi
  exit 0
fi

# Re-fetch the config of a fetch-mode tunnel and apply it when changed.
if [[ "${g_cmd}" == "fetch" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  # The refresh logic (change detection, restart only on change) lives in
  # symbios-openvpn-fetch.sh - the exact code the refresh cron runs.
  "${g_symbios_dir}/symbios-openvpn-fetch.sh" run "${g_name}"
  exit $?
fi

# Delete a tunnel: inventory entry, unit, bind mount, config, fetch helper
# and cron. The inventory entry goes first so a failure there cannot leave a
# half-deleted tunnel that the playbook would re-create.
if [[ "${g_cmd}" == "delete" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if ! "${g_symbios_dir}/symbios-settings-openvpn.sh" remove \
    --name "${g_name}" >/dev/null 2>&1
  then
    f_json_error "Failed to remove the inventory entry of ${g_name}"
  fi
  # Stop and disable first - failures are fine (unit may not exist).
  systemctl stop "openvpn@${g_name}" 2>/dev/null || true
  systemctl disable "openvpn@${g_name}" 2>/dev/null || true
  # Unmount the bind, then remove placeholder, encrypted config, fetch
  # helper and the refresh cron entry.
  umount "/etc/openvpn/${g_name}.conf" 2>/dev/null || true
  rm -f "/etc/openvpn/${g_name}.conf" "${g_ovpn_dir}/${g_name}.conf" "${g_ovpn_dir}/fetch-${g_name}.sh"
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
