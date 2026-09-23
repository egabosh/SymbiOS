#!/bin/bash
# SymbiOS - Read reapply status from host /tmp

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Read the current playbook reapply status from the host (/tmp status file
written by symbios-reapply.sh) and print it as a raw string:
  idle | running | running:N/T <pb> | done:N
No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Output: raw status string (idle | running | running:N/T pb | done:N)

source /etc/bash/gaboshlib.include

g_status_file="/tmp/symbios-reapply.status"

if [[ -r "$g_status_file" ]]
then
  cat "$g_status_file"
else
  echo "idle"
fi
