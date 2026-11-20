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

# This script is called through the root exec gateway. Reject anything that
# is not a plain file below /var/log, including symlinks out of that tree and
# ../ traversal: the WebUI passes a log name, never an arbitrary path.
g_real_path="$(realpath -m -- "$g_path" 2>/dev/null || true)"
if [[ -z "$g_real_path" || "$g_real_path" != /var/log/* || ! -f "$g_real_path" ]]
then
  echo "0"
  exit 0
fi
g_path="$g_real_path"

# Numeric arguments end up in arithmetic expressions; never trust their text.
[[ "$g_offset" =~ ^[0-9]+$ ]] || g_offset=0
[[ "$g_limit" =~ ^[0-9]+$ ]] || g_limit=500
(( g_limit > 0 && g_limit <= 10000 )) || g_limit=500

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
