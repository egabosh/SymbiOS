#!/bin/bash
# SymbiOS - Fetch Docker container logs with total count in one SSH roundtrip
# Usage: symbios-fetch-docker-log.sh <container_id> [offset] [limit]
# Output: first line = total count, remaining lines = extracted log messages

source /etc/bash/gaboshlib.include
source symbios-lib.sh

g_container="${1:-}"
g_offset="${2:-0}"
g_limit="${3:-500}"
g_log_base="${g_docker_root}/containers"

if [[ -z "$g_container" ]]
then
  echo "0"
  exit 1
fi

g_log_file="${g_log_base}/${g_container}/${g_container}-json.log"

if [[ ! -f "$g_log_file" ]]
then
  echo "0"
  exit 0
fi

# Get total entry count (number of JSON objects)
g_total=$(grep -c '{' "$g_log_file" 2>/dev/null || echo 0)

# Fetch raw JSON entries, extract .log field using jq
if (( g_offset > 0 ))
then
  g_raw=$(tail -n "+$(( g_offset + 1 ))" "$g_log_file" | tail -n "$g_limit")
else
  g_raw=$(tail -n "$g_limit" "$g_log_file")
fi

# Extract log messages from JSON, strip trailing newlines per entry
if [[ -n "$g_raw" ]] && command -v jq &>/dev/null
then
  g_content=$(echo "$g_raw" | jq -r '.log // empty' 2>/dev/null | sed -e '${/^$/!s/\r$//}' -e '/./,$!d')
else
  # Fallback: crude extraction without jq
  g_content=$(echo "$g_raw" | grep -oP '"log"\s*:\s*"\K[^"]*' 2>/dev/null)
fi

# Output: count on first line, then content lines
echo "$g_total"
if [[ -n "$g_content" ]]
then
  echo "$g_content"
fi
