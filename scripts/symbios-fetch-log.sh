#!/bin/bash
# SymbiOS - Fetch system log with line count in one SSH roundtrip

function f_usage {
  cat << EOF
Usage: $(basename "$0") <path> [offset] [limit]

Fetch a system log in one SSH roundtrip. Output: first line = total line
count, remaining lines = log content slice.

Arguments:
  path        absolute path of the log file to read
  offset      line offset to start reading from (default: 0)
  limit       maximum number of lines to return (default: 500)

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

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
