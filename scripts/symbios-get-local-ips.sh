#!/bin/bash
# SymbiOS - Report server identity: short hostname, primary LAN IPv4 and
# global IPv6 (GUA) address. Prints one JSON line.
# IPv4 must be RFC1918-private, IPv6 must be a global unicast address
# (link-local fe80::/10 and ULA fc00::/7 are ignored).

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_host_ip_file="${g_config_dir}/.host-ip"
g_ipv4=""
g_ipv6=""

# Primary IPv4: read from file written by host cron, else hostname -I
# filtered to RFC1918 private ranges (same logic as symbios-get-local-ip.sh).
if [[ -r "$g_host_ip_file" ]]
then
  g_ipv4=$(cat "$g_host_ip_file" 2>/dev/null | tr -d '[:space:]')
fi
if [[ -z "$g_ipv4" ]]
then
  for g_ip in $(hostname -I 2>/dev/null)
  do
    case "$g_ip" in
      192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        g_ipv4="$g_ip"
        break
        ;;
    esac
  done
fi

# Global IPv6: hostname -I filtered to GUA (first hex digit 2 or 3,
# i.e. 2000::/3); link-local (fe80::/10) and ULA (fc00::/7) are excluded.
for g_ip in $(hostname -I 2>/dev/null)
do
  case "$g_ip" in
    [23][0-9a-f][0-9a-f][0-9a-f]:*)
      g_ipv6="$g_ip"
      break
      ;;
  esac
done

# Short hostname as the user-facing server name
g_host=$(hostname -s 2>/dev/null)

echo "{\"hostname\":\"${g_host}\",\"ipv4\":\"${g_ipv4}\",\"ipv6\":\"${g_ipv6}\"}"
