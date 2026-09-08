#!/bin/bash
# detect-wifi.sh - Detect USB and PCI WiFi adapters on the host.
# Only USB/PCI adapters can be attached to the VM via libvirt hostdev, so
# onboard wireless NICs (e.g. Raspberry Pi SDIO) are intentionally not listed.
# Output: JSON array of {value, label} objects.
{
  # USB WiFi adapters.
  lsusb 2>/dev/null | grep -i -E 'wireless|wifi|wlan|802\.11|ralink|realtek|atheros|mediatek|broadcom|intel' | \
    sed 's/^/USB: /' | \
    awk '{gsub(/"/, "\\\"", $0); print "{\"value\":\"usb:" $0 "\",\"label\":\"[USB] " $0 "\"}"}'

  # PCI WiFi adapters.
  lspci 2>/dev/null | grep -i -E 'network|wireless|wifi|wlan' | \
    sed 's/^/PCI: /' | \
    awk '{gsub(/"/, "\\\"", $0); print "{\"value\":\"pci:" $0 "\",\"label\":\"[PCI] " $0 "\"}"}'
} | jq -s '[.[] | select(type == "object")]' 2>/dev/null || echo '[]'
