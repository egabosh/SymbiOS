#!/bin/bash
# SymbiOS - Write an OpenVPN client config from stdin
# Called by the WebUI when a tunnel config is uploaded (Settings -> OpenVPN
# Client). The config may contain private keys, so it arrives via stdin (never
# on the command line or in the exec audit log) and is stored encrypted on
# the data volume (<base-services>/openvpn/<name>.conf, 0600) - never on the
# unencrypted SD card. The playbook bind-mounts it into /etc/openvpn.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <name>

Write /etc/openvpn/<name>.conf from stdin. Reads the OpenVPN client config
from stdin and replaces the existing file atomically, then restarts the
tunnel when it is enabled at boot. Called by the WebUI for tunnel uploads.

Example:
  cat homeassistant-iot.ovpn | $(basename "$0") homeassistant-iot

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

# Tunnel name doubles as a path and unit fragment - restrict the charset.
g_name="${1:-}"
if [[ ! "${g_name}" =~ ^[a-zA-Z0-9_-]+$ ]]
then
  echo '{"ok":false,"error":"Invalid tunnel name (a-z, 0-9, _ and - only)"}' >&2
  exit 1
fi

# Encrypted target directory (0700, on the LUKS volume). Missing means the
# data volume is not mounted - refuse instead of writing to the SD card.
g_target_dir="${g_base_services_root}/openvpn"
if [[ ! -d "${g_target_dir}" ]]
then
  echo '{"ok":false,"error":"Encrypted config dir missing (data volume mounted? run the openvpn playbook first)"}' >&2
  exit 1
fi

g_conf_file="${g_target_dir}/${g_name}.conf"
g_tmp="${g_conf_file}.tmp.$$"

# Read the config from stdin, write atomically on the same filesystem.
cat > "$g_tmp"
if [[ $? -ne 0 ]]
then
  rm -f "$g_tmp"
  echo '{"ok":false,"error":"Failed to read config from input"}' >&2
  exit 1
fi

# Validate: a client config needs at least a remote endpoint and a dev type.
if ! grep -qE '^[[:space:]]*remote[[:space:]]+' "$g_tmp" 2>/dev/null
then
  rm -f "$g_tmp"
  echo '{"ok":false,"error":"Invalid config: no remote directive found"}' >&2
  exit 1
fi
if ! grep -qE '^[[:space:]]*dev[[:space:]]+' "$g_tmp" 2>/dev/null
then
  rm -f "$g_tmp"
  echo '{"ok":false,"error":"Invalid config: no dev directive found"}' >&2
  exit 1
fi

# Atomic move with restricted permissions (private keys inside).
mv "$g_tmp" "$g_conf_file"
chmod 600 "$g_conf_file"

# Restart a running tunnel so the new config takes effect immediately.
if systemctl is-active "openvpn@${g_name}" >/dev/null 2>&1
then
  systemctl restart "openvpn@${g_name}" 2>/dev/null || true
fi

echo '{"ok":true,"message":"Tunnel config written."}'
