#!/bin/bash
# SymbiOS - Detect the server connection type: 'home' (behind a router/NAT),
# 'root' (own public IP) or 'airgapped' (enterprise intranet without direct
# internet access). Prints one JSON line with the detection result and a short
# reason so the setup assistant can pre-select the option.
#
# Only the interface of the default route is considered - Docker bridges and
# other secondary interfaces (172.17.x, ...) must not influence the result.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Primary IPv4: the address on the interface the default route uses. This is
# the address a NAT/router would translate (same logic as update_host_ip.sh).
g_dev=$(ip -4 route show default 2>/dev/null | grep -oP "dev \K\S+" | head -1)
g_primary_ipv4=""
if [[ -n "$g_dev" ]]
then
  g_primary_ipv4=$(ip -4 -o addr show dev "${g_dev}" scope global 2>/dev/null | grep -oP "(?<=inet )\d+(\.\d+){3}" | head -1)
fi

# Default gateway address (for the reason string).
g_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')

# Internet reachability probe: an air-gapped intranet has no route out. Use a
# short TCP connect to a well-known public address (works even when ICMP is
# filtered and independent of the configured DNS server).
g_online=""
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null
then
  g_online="yes"
fi

f_network_type=""
f_reason=""
if [[ -z "$g_primary_ipv4" ]]
then
  f_network_type=""
  f_reason="Could not determine the primary interface IP"
elif [[ -n "$g_primary_ipv4" ]] && ! [[ "$g_primary_ipv4" =~ ^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]
then
  f_network_type="root"
  f_reason="Server has its own public IP ${g_primary_ipv4}"
elif [[ -z "$g_online" ]]
then
  f_network_type="airgapped"
  f_reason="No outbound internet connection detected (${g_primary_ipv4})"
else
  f_network_type="home"
  f_reason="Server has a private LAN IP ${g_primary_ipv4} with internet access"
fi

echo "{\"network_type\":\"${f_network_type}\",\"reason\":\"${f_reason}\",\"ipv4\":\"${g_primary_ipv4}\",\"gateway\":\"${g_gateway}\",\"online\":\"${g_online}\"}"
exit 0
