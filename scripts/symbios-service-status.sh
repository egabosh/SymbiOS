#!/bin/bash
# File storing system service statuses

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Write the system service statuses to $g_log_dir/symbios-services.tsv for the
WebUI Health page. Currently no system services beyond Docker are tracked, so
the file is (re-)created empty. No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_file="${g_log_dir}/symbios-services.tsv"
g_tmp="${g_file}.tmp"

# Write status for each service to temp file
# No system services to track currently
echo -e "" > "$g_tmp"

# Set permissions on temp file
chmod 644 "$g_tmp"

# Atomically replace status file
mv "$g_tmp" "$g_file"
