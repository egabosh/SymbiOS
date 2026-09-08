#!/bin/bash
# detect-interfaces.sh - Detect available physical network interfaces on the host.
# Excludes loopback, Docker bridges (incl. Docker network interfaces), virtual
# interfaces, and already-used bridges. Output: JSON array of {value, label}.

ip -o link show 2>/dev/null | \
  awk '$2 !~ /^(lo|docker|br-|veth|virbr|bond|dummy)/ {
    gsub(/:/, "", $2)
    print $2
  }' | \
  while read -r f_iface
  do
    # Skip Linux bridges (e.g. Docker network interfaces like base-services).
    if [[ -d "/sys/class/net/${f_iface}/bridge" ]]
    then
      continue
    fi
    echo "$f_iface"
  done | \
  sort | \
  jq -R -s 'split("\n") | map(select(length > 0)) | map({value: ., label: .})'
