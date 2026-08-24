#!/bin/bash
# detect-radios.sh - Detect WiFi radios on the OpenWrt VM via SSH.
# Output: JSON array of {value, label} objects.
VM_IP="${VM_IP:-192.168.41.201}"
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$VM_IP" \
  "uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 | sort -u" 2>/dev/null | \
  jq -R -s 'split("\n") | map(select(length > 0)) | map({value: ., label: .})' 2>/dev/null || \
  echo '[]'
