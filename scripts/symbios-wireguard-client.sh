#!/bin/bash
# SymbiOS - Manage WireGuard client tunnels on the host
# Lists tunnel status for the WebUI (Settings -> WireGuard Client) and controls
# the wg-quick@<name> systemd units. Tunnel configs hold the private key and
# live encrypted on the data volume (<base-services>/wireguard/<name>.conf,
# 0700); /etc/wireguard/<name>.conf is a bind mount onto the sanitized runtime
# copy (<name>.runtime.conf, rendered by symbios-write-wireguard-config.sh), so
# no plaintext ever lands on the SD card.
#
# Boot policy (AGENTS.md): the units are never systemd-enabled - they start
# from rc.local after the data volume is mounted. The "enabled" state therefore
# comes from the inventory (wireguard_clients.<name>.enabled), not from
# systemctl is-enabled.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [args]

List WireGuard client tunnels and control the wg-quick@<name> systemd units
for the WebUI (Settings -> WireGuard Client).

Commands:
  list                  JSON with all tunnels known on the data volume
  status <name>         JSON with a single tunnel
  up <name>             Bind the config and start the tunnel
  down <name>           Stop the tunnel
  enable <name>         Mark the tunnel enabled (inventory) and start it
  disable <name>        Mark the tunnel disabled (inventory) and stop it
  delete <name>         Stop the tunnel, remove its inventory entry, config
                        and runtime copy
  log <name> [lines]    Last journal lines of wg-quick@<name> (default 50)
  boot-start            Bind all configs and start the enabled tunnels
                        (called from rc.local after the data volume is up)

Examples:
  $(basename "$0") list
  $(basename "$0") up iot

Options:
  -h, --help          Show this help and exit

Output: list/status/up/down/enable/disable/delete print one JSON line
(log prints plain journal text, boot-start one line per started tunnel).

Exit codes:
  0  ok
  1  validation or technical error (unknown tunnel, systemctl failure, ...)
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
g_wg_dir="${g_base_services_root}/wireguard"

# Check that a tunnel name is safe for use in paths and interface names.
function f_valid_name {
  local f_name="$1"
  [[ "${f_name}" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]
}

# Read one boolean field of the tunnel entry from the inventory (default off).
function f_inv_flag {
  local f_tunnel="$1" f_flag="$2" f_entry=""
  f_entry="$("$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-get wireguard_clients "${f_tunnel}" 2>/dev/null || true)"
  f_entry="${f_entry//[[:space:]]/}"
  [[ "${f_entry}" == *"\"${f_flag}\":true"* ]]
}

# Bind the runtime config into /etc/wireguard (no-op when already bound).
# Renders the runtime copy on demand when only the stored config exists.
# Returns 1 when no config is available (e.g. data volume not mounted).
function f_ensure_bind {
  local f_name="$1"
  local f_src="${g_wg_dir}/${f_name}.runtime.conf"
  local f_raw="${g_wg_dir}/${f_name}.conf"
  local f_dst="/etc/wireguard/${f_name}.conf"

  if [[ ! -s "${f_src}" && -s "${f_raw}" ]]
  then
    "${g_symbios_dir}/symbios-write-wireguard-config.sh" --render "${f_name}" \
      >/dev/null 2>&1 || true
  fi
  [[ -s "${f_src}" ]] || return 1
  if mountpoint -q "${f_dst}" 2>/dev/null
  then
    return 0
  fi
  mkdir -p /etc/wireguard 2>/dev/null || return 1
  touch "${f_dst}" 2>/dev/null || return 1
  chmod 600 "${f_dst}" 2>/dev/null || true
  mount --bind "${f_src}" "${f_dst}" 2>/dev/null
}

# Emit the JSON object for one tunnel (no surrounding array).
function f_tunnel_json {
  local f_name="$1"
  local f_active="false"
  local f_enabled="false"
  local f_ip4=""
  local f_ip6=""
  local f_peers=0
  local f_endpoint=""
  local f_handshake=0
  local f_rx=0
  local f_tx=0
  local f_dump=""
  local f_now=""
  local f_age=-1
  local f_pub f_psk f_ep f_allowed f_hs f_rx_peer f_tx_peer f_keepalive

  # Service state via systemd (missing unit counts as inactive, not an error).
  if systemctl is-active "wg-quick@${f_name}" >/dev/null 2>&1
  then
    f_active="true"
  fi
  # Enablement is inventory state (boot start happens in rc.local).
  if f_inv_flag "${f_name}" "enabled"
  then
    f_enabled="true"
  fi

  # Addresses from the tunnel interface (IPv6 link-local is not interesting).
  f_ip4="$(ip -o -4 addr show dev "${f_name}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  f_ip6="$(ip -o -6 addr show dev "${f_name}" 2>/dev/null | awk '$4 !~ /^fe80:/ {print $4}' | cut -d/ -f1 | head -1)"

  # Peer facts from `wg show dump`: first line is the interface, every
  # following line is one peer (tab separated).
  f_dump="$(wg show "${f_name}" dump 2>/dev/null || true)"
  if [[ -n "${f_dump}" ]]
  then
    while IFS=$'\t' read -r f_pub f_psk f_ep f_allowed f_hs f_rx_peer f_tx_peer f_keepalive
    do
      [[ -n "${f_pub}" ]] || continue
      f_peers=$((f_peers + 1))
      if [[ -z "${f_endpoint}" && "${f_ep}" != "(none)" ]]
      then
        f_endpoint="${f_ep}"
      fi
      if [[ "${f_hs}" =~ ^[0-9]+$ ]] && [[ "${f_hs}" -gt "${f_handshake}" ]]
      then
        f_handshake="${f_hs}"
      fi
      if [[ "${f_rx_peer}" =~ ^[0-9]+$ ]]
      then
        f_rx=$((f_rx + f_rx_peer))
      fi
      if [[ "${f_tx_peer}" =~ ^[0-9]+$ ]]
      then
        f_tx=$((f_tx + f_tx_peer))
      fi
    done < <(tail -n +2 <<< "${f_dump}")
  fi

  # Handshake age in seconds (-1 = no handshake yet).
  if [[ "${f_handshake}" -gt 0 ]]
  then
    f_now="$(date +%s)"
    f_age=$((f_now - f_handshake))
  fi

  printf '{"name":%s,"active":%s,"enabled":%s,"interface":%s,"ip4":%s,"ip6":%s,"peers":%s,"endpoint":%s,"handshake_age":%s,"rx_bytes":%s,"tx_bytes":%s}' \
    "$(printf '%s' "${f_name}" | f_json_escape)" \
    "${f_active}" \
    "${f_enabled}" \
    "$(printf '%s' "${f_name}" | f_json_escape)" \
    "$(printf '%s' "${f_ip4}" | f_json_escape)" \
    "$(printf '%s' "${f_ip6}" | f_json_escape)" \
    "${f_peers}" \
    "$(printf '%s' "${f_endpoint}" | f_json_escape)" \
    "${f_age}" \
    "${f_rx}" \
    "${f_tx}"
}

g_cmd="${1:-list}"

# List all tunnels as a single JSON line (even on expected empty results).
if [[ "${g_cmd}" == "list" ]]
then
  printf '{"tunnels":['
  g_first=1
  for g_conf in "${g_wg_dir}"/*.conf
  do
    [[ -e "${g_conf}" ]] || continue
    g_tunnel="$(basename "${g_conf}" .conf)"
    # Skip the rendered runtime copies (*.runtime.conf).
    [[ "${g_tunnel}" == *.runtime ]] && continue
    if [[ "${g_first}" -eq 1 ]]
    then
      g_first=0
    else
      printf ','
    fi
    f_tunnel_json "${g_tunnel}"
  done
  printf '],"wireguard_installed":'
  if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1
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
  if [[ ! -s "${g_wg_dir}/${g_name}.conf" && ! -s "/etc/wireguard/${g_name}.conf" ]]
  then
    f_json_error "Tunnel not found: ${g_name}"
  fi
  printf '{"tunnel":'
  f_tunnel_json "${g_name}"
  printf '}\n'
  exit 0
fi

# Start/stop map to systemctl on the wg-quick template unit.
if [[ "${g_cmd}" == "up" || "${g_cmd}" == "down" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ "${g_cmd}" == "up" ]]
  then
    # Starting needs the bound runtime config - bind it now when the volume
    # is there.
    if ! f_ensure_bind "${g_name}"
    then
      f_json_error "No config for tunnel ${g_name} (upload it first, data volume mounted?)"
    fi
    g_action="start"
  else
    if [[ ! -s "${g_wg_dir}/${g_name}.conf" && ! -s "/etc/wireguard/${g_name}.conf" ]]
    then
      f_json_error "Tunnel not found: ${g_name}"
    fi
    g_action="stop"
  fi
  if systemctl "${g_action}" "wg-quick@${g_name}" 2>/dev/null
  then
    printf '{"ok":true,"message":"Tunnel %s: %s done."}\n' "${g_name}" "${g_action}"
  else
    f_json_error "systemctl ${g_action} wg-quick@${g_name} failed"
  fi
  exit 0
fi

# Enable/disable persist the inventory flag (rc.local starts it at boot) and
# apply the state right away.
if [[ "${g_cmd}" == "enable" || "${g_cmd}" == "disable" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  if [[ "${g_cmd}" == "enable" ]]
  then
    g_flag="true"
    g_action="start"
  else
    g_flag="false"
    g_action="stop"
  fi
  if ! "${g_symbios_dir}/symbios-settings-wireguard.sh" save \
    --name "${g_name}" --enabled "${g_flag}" >/dev/null 2>&1
  then
    f_json_error "Failed to update the inventory entry of ${g_name}"
  fi
  # A tunnel that is enabled but has no config yet stays down (no config).
  if [[ "${g_action}" == "start" ]]
  then
    f_ensure_bind "${g_name}" >/dev/null 2>&1 || true
  fi
  systemctl "${g_action}" "wg-quick@${g_name}" 2>/dev/null || true
  printf '{"ok":true,"message":"Tunnel %s: %s done."}\n' "${g_name}" "${g_action}"
  exit 0
fi

# Delete a tunnel: inventory entry, unit, UFW rules, bind mount, config and
# runtime copy.
if [[ "${g_cmd}" == "delete" ]]
then
  g_name="${2:-}"
  if ! f_valid_name "${g_name}"
  then
    f_json_error "Invalid tunnel name"
  fi
  # Inventory first: a failure there must not leave a half-deleted tunnel.
  if ! "${g_symbios_dir}/symbios-settings-wireguard.sh" remove \
    --name "${g_name}" >/dev/null 2>&1
  then
    f_json_error "Failed to remove the inventory entry of ${g_name}"
  fi
  systemctl stop "wg-quick@${g_name}" 2>/dev/null || true
  systemctl disable "wg-quick@${g_name}" 2>/dev/null || true
  # Drop the interface-bound UFW rules too. They are inert once the interface
  # is gone, but would silently apply to a later tunnel of the same name.
  # Delete from the highest rule number down, so the remaining numbers stay
  # valid while iterating.
  if command -v ufw >/dev/null 2>&1
  then
    ufw status numbered 2>/dev/null | grep -F " on ${g_name} " | \
      sed -n 's/^\[ *\([0-9]*\)\].*/\1/p' | sort -rn | \
      while read -r f_num
      do
        ufw --force delete "${f_num}" >/dev/null 2>&1 || true
      done
  fi
  umount "/etc/wireguard/${g_name}.conf" 2>/dev/null || true
  rm -f "/etc/wireguard/${g_name}.conf" \
    "${g_wg_dir}/${g_name}.conf" \
    "${g_wg_dir}/${g_name}.runtime.conf"
  printf '{"ok":true,"message":"Tunnel %s deleted."}\n' "${g_name}"
  exit 0
fi

# Boot start, called from rc.local once the data volume is mounted: bind every
# stored runtime config and start the tunnels whose inventory flag says
# enabled. The rc.local block is static and calls this, so enable/disable only
# touches the inventory and the unit - it never has to regenerate the block.
if [[ "${g_cmd}" == "boot-start" ]]
then
  for g_conf in "${g_wg_dir}"/*.conf
  do
    [[ -e "${g_conf}" ]] || continue
    g_tunnel="$(basename "${g_conf}" .conf)"
    [[ "${g_tunnel}" == *.runtime ]] && continue
    f_inv_flag "${g_tunnel}" "enabled" || continue
    f_ensure_bind "${g_tunnel}" || continue
    systemctl start "wg-quick@${g_tunnel}" 2>/dev/null || true
    echo "started ${g_tunnel}"
  done
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
  journalctl -u "wg-quick@${g_name}" -n "${g_lines}" --no-pager 2>/dev/null || echo "(no log available)"
  exit 0
fi

f_usage >&2
exit 1
