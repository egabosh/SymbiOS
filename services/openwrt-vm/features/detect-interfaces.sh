#!/bin/bash
# detect-interfaces.sh - Detect available physical network interfaces on the host.
# Excludes loopback, Docker bridges, virtual interfaces, and already-used bridges.
# Output: JSON array of {value, label} objects.
ip -o link show 2>/dev/null | \
  awk '$2 !~ /^(lo|docker|br-|veth|virbr|bond|dummy)/ {
    gsub(/:/, "", $2)
    print $2
  }' | \
  sort | \
  jq -R -s 'split("\n") | map(select(length > 0)) | map({value: ., label: .})'
