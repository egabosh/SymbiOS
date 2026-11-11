#!/bin/bash
# SymbiOS - Write a WireGuard client config from stdin (and render its runtime copy)
# Called by the WebUI when a tunnel config is uploaded (Settings -> WireGuard
# Client). The config contains the private key, so it arrives via stdin (never
# on the command line or in the exec audit log) and is stored encrypted on the
# data volume (<base-services>/wireguard/<name>.conf, 0600) - never on the
# unencrypted SD card.
#
# The playbook bind-mounts a sanitized runtime copy (<name>.runtime.conf) into
# /etc/wireguard/<name>.conf. Sanitizing is deliberate: wg-quick executes
# PreUp/PostUp/PreDown/PostDown as root and writes DNS entries into the host
# resolver, so both stay out of the runtime config unless the tunnel enables
# them in the inventory (dns / hooks). SaveConfig is always dropped: it would
# write the private key back into a bind-mounted file.
#
# --render regenerates only the runtime copy from the stored config (used by
# base-services/wireguard-client.yml after a dns/hooks change).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <name>
       $(basename "$0") --render <name>

Write <base-services>/wireguard/<name>.conf from stdin (the WireGuard client
config) and render <name>.runtime.conf from it. --render only regenerates
the runtime copy from the stored config (no stdin, used by the playbook).

The tunnel name doubles as the WireGuard interface name, so it is limited to
15 characters. Stored files are 0600 on the encrypted data volume.

Examples:
  cat iot.conf | $(basename "$0") iot
  $(basename "$0") --render iot

Options:
  -h, --help          Show this help and exit

Exit codes:
  0  ok (including "unchanged" for --render)
  1  validation or technical error
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

# Encrypted config directory (0700, on the LUKS volume).
g_wg_dir="${g_base_services_root}/wireguard"

g_mode="write"
g_name="${1:-}"
if [[ "${1:-}" == "--render" ]]
then
  g_mode="render"
  g_name="${2:-}"
fi

# Tunnel name doubles as a path, unit and interface name - restrict charset
# and length (Linux IFNAMSIZ).
if [[ ! "${g_name}" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]
then
  echo '{"ok":false,"error":"Invalid tunnel name (1-15 chars, a-z, 0-9, _ and - only)"}' >&2
  exit 1
fi

# Missing directory means the data volume is not mounted - refuse instead of
# writing to the SD card.
if [[ ! -d "${g_wg_dir}" ]]
then
  echo '{"ok":false,"error":"Encrypted config dir missing (data volume mounted? run the wireguard playbook first)"}' >&2
  exit 1
fi

# Read one boolean field of the tunnel entry from the inventory (default off).
function f_inv_flag {
  local f_tunnel="$1" f_flag="$2" f_entry=""
  f_entry="$("$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" \
    dict-get wireguard_clients "${f_tunnel}" 2>/dev/null || true)"
  f_entry="${f_entry//[[:space:]]/}"
  [[ "${f_entry}" == *"\"${f_flag}\":true"* ]]
}

# Render the runtime copy: strip SaveConfig always, DNS and hooks unless the
# tunnel enables them. Return 0 = changed, 2 = unchanged, 1 = error.
function f_render_runtime {
  local f_tunnel="$1"
  local f_src="${g_wg_dir}/${f_tunnel}.conf"
  local f_dst="${g_wg_dir}/${f_tunnel}.runtime.conf"
  local f_tmp="${f_dst}.tmp.$$"
  local f_bind="/etc/wireguard/${f_tunnel}.conf"
  local f_dns="no" f_hooks="no" f_line f_key

  f_inv_flag "${f_tunnel}" "dns" && f_dns="yes"
  f_inv_flag "${f_tunnel}" "hooks" && f_hooks="yes"
  [[ -s "${f_src}" ]] || return 1

  : > "${f_tmp}" || return 1
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    # Normalize Windows line endings; keep every other byte as uploaded.
    f_line="${f_line%$'\r'}"
    f_key="${f_line%%=*}"
    f_key="${f_key//[[:space:]]/}"
    f_key="${f_key,,}"
    case "${f_key}" in
      saveconfig)
        continue
        ;;
      dns)
        [[ "${f_dns}" == "yes" ]] || continue
        ;;
      preup|postup|predown|postdown)
        [[ "${f_hooks}" == "yes" ]] || continue
        ;;
    esac
    printf '%s\n' "${f_line}" >> "${f_tmp}"
  done < "${f_src}"
  chmod 600 "${f_tmp}" 2>/dev/null || true

  # Unchanged content: keep file and bind mount untouched (playbook reruns
  # must not restart a running tunnel for nothing).
  if [[ -f "${f_dst}" ]] && cmp -s "${f_tmp}" "${f_dst}"
  then
    rm -f "${f_tmp}"
    return 2
  fi

  # The runtime file is bind-mounted into /etc/wireguard: replacing the inode
  # would leave the mount on the old file, so write in place when bound.
  if mountpoint -q "${f_bind}" 2>/dev/null
  then
    if ! cat "${f_tmp}" > "${f_dst}"
    then
      rm -f "${f_tmp}"
      return 1
    fi
    rm -f "${f_tmp}"
  else
    if ! mv "${f_tmp}" "${f_dst}"
    then
      rm -f "${f_tmp}"
      return 1
    fi
  fi
  chmod 600 "${f_dst}" 2>/dev/null || true
  return 0
}

# Render-only mode: no stdin, no raw write. Used by the playbook.
if [[ "${g_mode}" == "render" ]]
then
  f_render_runtime "${g_name}"
  f_rc=$?
  if [[ "${f_rc}" -eq 1 ]]
  then
    echo '{"ok":false,"error":"Failed to render the runtime config"}' >&2
    exit 1
  fi
  if [[ "${f_rc}" -eq 2 ]]
  then
    echo '{"ok":true,"state":"unchanged"}'
  else
    echo '{"ok":true,"state":"changed"}'
  fi
  exit 0
fi

# --- write mode: read, validate and store the uploaded config -------------------

g_conf_file="${g_wg_dir}/${g_name}.conf"
g_tmp="${g_conf_file}.tmp.$$"

# Read from stdin and normalize line endings (Windows-pasted configs).
if ! awk '{ sub(/\r$/, "") } { print }' > "${g_tmp}"
then
  rm -f "${g_tmp}"
  echo '{"ok":false,"error":"Failed to read config from input"}' >&2
  exit 1
fi

# Reject empty or oversized uploads (a client config is a few hundred bytes).
g_size="$(wc -c < "${g_tmp}" 2>/dev/null || echo 0)"
if [[ "${g_size}" -eq 0 ]]
then
  rm -f "${g_tmp}"
  echo '{"ok":false,"error":"Empty config"}' >&2
  exit 1
fi
if [[ "${g_size}" -gt 65536 ]]
then
  rm -f "${g_tmp}"
  echo '{"ok":false,"error":"Config too large (limit 64 KiB)"}' >&2
  exit 1
fi

# Validate the mandatory structure of a client config: one [Interface] with
# PrivateKey and Address, at least one [Peer] with PublicKey and AllowedIPs,
# and an Endpoint somewhere (a client must know where to connect).
g_err="$(awk '
  BEGIN { section=""; peers=0; pubkey=0; allowed=0; endpoint=0; iface=0; privkey=0; addr=0; bad="" }

  # Strip a trailing CR so Windows configs validate like Unix ones.
  { sub(/\r$/, "") }

  # A new section closes the previous [Peer] block and checks its keys.
  /^[[:space:]]*\[/ {
    if (section == "Peer") {
      if (!pubkey) bad = "a [Peer] block has no PublicKey"
      if (!allowed) bad = "a [Peer] block has no AllowedIPs"
    }
    s = $0
    gsub(/[][[:space:]]/, "", s)
    section = s
    if (s == "Interface") iface = 1
    if (s == "Peer") { peers++; pubkey = 0; allowed = 0 }
    next
  }

  # Collect the mandatory keys per section.
  section == "Interface" && /^[[:space:]]*PrivateKey[[:space:]]*=/ { privkey = 1 }
  section == "Interface" && /^[[:space:]]*Address[[:space:]]*=/ { addr = 1 }
  section == "Peer" && /^[[:space:]]*PublicKey[[:space:]]*=/ { pubkey = 1 }
  section == "Peer" && /^[[:space:]]*AllowedIPs[[:space:]]*=/ { allowed = 1 }
  section == "Peer" && /^[[:space:]]*Endpoint[[:space:]]*=/ { endpoint = 1 }

  END {
    if (section == "Peer") {
      if (!pubkey) bad = "a [Peer] block has no PublicKey"
      if (!allowed) bad = "a [Peer] block has no AllowedIPs"
    }
    if (bad == "" && !iface) bad = "no [Interface] section"
    if (bad == "" && !privkey) bad = "no PrivateKey in [Interface]"
    if (bad == "" && !addr) bad = "no Address in [Interface]"
    if (bad == "" && peers < 1) bad = "no [Peer] section"
    if (bad == "" && !endpoint) bad = "no Endpoint in any [Peer]"
    if (bad != "") { print bad; exit 1 }
  }
' "${g_tmp}")"
if [[ -n "${g_err}" ]]
then
  rm -f "${g_tmp}"
  echo "{\"ok\":false,\"error\":\"Invalid config: ${g_err}\"}" >&2
  exit 1
fi

# Stop a running tunnel first: a config change must not race the interface.
g_was_active="no"
if systemctl is-active "wg-quick@${g_name}" >/dev/null 2>&1
then
  g_was_active="yes"
  systemctl stop "wg-quick@${g_name}" 2>/dev/null || true
fi

# Atomic move with restricted permissions (private key inside).
if ! mv "${g_tmp}" "${g_conf_file}"
then
  rm -f "${g_tmp}"
  echo '{"ok":false,"error":"Failed to store the config"}' >&2
  exit 1
fi
chmod 600 "${g_conf_file}" 2>/dev/null || true

# Render the runtime copy (also re-establishes a changed bind mount).
if ! f_render_runtime "${g_name}"
then
  echo '{"ok":false,"error":"Failed to render the runtime config"}' >&2
  exit 1
fi

# Bring the tunnel back when it was running before the upload.
if [[ "${g_was_active}" == "yes" ]]
then
  systemctl start "wg-quick@${g_name}" 2>/dev/null || true
fi

echo '{"ok":true,"message":"Tunnel config written."}'
