#!/bin/bash
# Write host primary LAN IP for webui container
source symbios-lib.sh
ip route get 1.1.1.1 2>/dev/null | grep -oP "src \K[0-9.]+" > "${g_config_dir}/.host-ip"
