#!/usr/bin/env bash
# symbios-ow-bridge-dhcp.sh - maintain a DHCP lease on the OpenWrt host
# bridges (see f_usage below).

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Maintain a DHCP lease on the OpenWrt host bridges. The OpenWrt VM (the
per-segment dnsmasq/DHCP server) only starts after the LUKS boot-unlock via
rc.local, i.e. after ifupdown already ran. This script is driven by the
symbios-ow-bridge-dhcp.timer (every 5 minutes): it starts dhclient on every
bridge without a lease and is a no-op once all segments hold one (and while
a client is already running). No arguments.

Operates on the bridges: openwrt-lan openwrt-iot openwrt-tor openwrt-misc.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# The OpenWrt VM (the per-segment dnsmasq/DHCP server) only starts
# after the LUKS boot-unlock via rc.local, i.e. after ifupdown already ran.
# This script is driven by the symbios-ow-bridge-dhcp.timer (every 5
# minutes): it starts dhclient on every bridge without a lease and is a no-op
# once all four segments hold one (and while a client is already running).
#
# NOTE: the bridges are "inet manual" in ifupdown on purpose. "inet dhcp"
# starts dhclient at boot (blocking ifup and spawning stray daemons) and the
# segment's Router option would be turned into a default route. Instead
# dhclient is started directly here with its own pidfile; the
# dhclient-exit-hooks.d hook (symbios-openwrt-routes) drops any default route
# the segment offers after each lease event.

# The four openwrt-vm internal segment bridges (see services/openwrt-vm.yml)
g_bridges="openwrt-lan openwrt-iot openwrt-tor openwrt-misc"

for f_bridge in $g_bridges
do
  # Skip bridges that already hold an IPv4 address from the segment's dnsmasq
  if ip -4 addr show "$f_bridge" 2>/dev/null | grep -q "inet "
  then
    continue
  fi
  # Skip while a dhclient for this bridge is already running (started by a
  # previous timer tick and still waiting for the lease).
  f_pidfile="/run/dhclient.${f_bridge}.pid"
  if [ -f "$f_pidfile" ] && kill -0 "$(cat "$f_pidfile" 2>/dev/null)" 2>/dev/null
  then
    continue
  fi
  # Start dhclient in interactive mode (-i, as ifupdown does): it keeps
  # DISCOVERing after a failed attempt instead of going to "sleep" with no
  # lease (which would block the pidfile guard and stall further retries).
  dhclient -v -i -pf "$f_pidfile" "$f_bridge" >/dev/null 2>&1 &
  disown
done