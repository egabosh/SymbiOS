#!/bin/bash
# Write host primary LAN IP for webui container
ip route get 1.1.1.1 2>/dev/null | grep -oP "src \K[0-9.]+" > /home/docker/symbios-ui/config/.host-ip
