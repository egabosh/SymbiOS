#!/bin/bash
# Write host primary LAN IP for webui container
source symbios-lib.sh
# Use the interface of the default route - no external host (e.g. Cloudflare's
# 1.1.1.1) is contacted.
f_dev=$(ip -4 route show default 2>/dev/null | grep -oP "dev \K\S+" | head -1)
if [[ -n "$f_dev" ]]
then
  ip -4 -o addr show dev "${f_dev}" scope global 2>/dev/null | grep -oP "(?<=inet )\d+(\.\d+){3}" | head -1 > "${g_config_dir}/.host-ip"
fi
