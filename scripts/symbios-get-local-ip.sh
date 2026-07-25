#!/bin/bash
# SymbiOS - Get local IPv4 address (RFC1918 private range)
# Checks .host-ip file first (written by host cron), falls back to hostname -I

source /etc/bash/gaboshlib.include

g_host_ip_file="/home/docker/symbios-ui/config/.host-ip"

# Primary: read from file written by host cron
if [[ -r "$g_host_ip_file" ]]
then
  g_ip=$(cat "$g_host_ip_file" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$g_ip" ]]
  then
    echo "$g_ip"
    exit 0
  fi
fi

# Fallback: hostname -I, filter for RFC1918 private ranges
g_ips=$(hostname -I 2>/dev/null)
for g_ip in $g_ips
do
  case "$g_ip" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      echo "$g_ip"
      exit 0
      ;;
  esac
done

echo ""
