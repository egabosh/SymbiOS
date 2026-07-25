#!/bin/bash
# SymbiOS - Fetch system log with line count in one SSH roundtrip
# Usage: symbios-fetch-log.sh <path> [offset] [limit]
# Output: first line = total count, remaining lines = log content

source /etc/bash/gaboshlib.include

g_path="${1:-}"
g_offset="${2:-0}"
g_limit="${3:-500}"

if [[ -z "$g_path" || ! -f "$g_path" ]]
then
  echo "0"
  exit 0
fi

# Get total line count
g_total=$(wc -l < "$g_path" 2>/dev/null || echo 0)

# Fetch the requested slice
if (( g_offset > 0 ))
then
  g_content=$(tail -n "+$(( g_offset + 1 ))" "$g_path" | tail -n "$g_limit")
else
  g_content=$(tail -n "$g_limit" "$g_path")
fi

# Output: count on first line, then content lines
# The caller splits on first newline to get count, rest is log lines
echo "$g_total"
if [[ -n "$g_content" ]]
then
  echo "$g_content"
fi
