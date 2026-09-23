#!/bin/bash
# Write host primary LAN IP for webui container

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Write the host primary LAN IP for the WebUI container: resolves the
interface of the default route (no external host is contacted) and stores
the address in <config>/.host-ip, which symbios-get-local-ip.sh and
symbios-get-local-ips.sh read. No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
# Use the interface of the default route - no external host is contacted.
f_dev=$(ip -4 route show default 2>/dev/null | grep -oP "dev \K\S+" | head -1)
if [[ -n "$f_dev" ]]
then
  ip -4 -o addr show dev "${f_dev}" scope global 2>/dev/null | grep -oP "(?<=inet )\d+(\.\d+){3}" | head -1 > "${g_config_dir}/.host-ip"
fi
