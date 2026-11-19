#!/bin/bash
# SymbiOS - Render text from stdin as an SVG QR code on stdout.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Read text from stdin and write an SVG QR code to stdout. The WebUI uses this
to turn a VPN client config into a scannable QR on the SymbiOS host, so no
extra package is needed on the remote router. No arguments.

Options:
  -h, --help          Show this help and exit

Output: SVG document on stdout.
Exit codes:
  0  success
  1  qrencode is missing or failed
  2  usage error
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Shared helpers only add stderr logging; stdout stays reserved for the SVG.
if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include || true
fi
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${g_script_dir}/symbios-lib.sh"
f_no_args "$@"

function f_error {
  if declare -F g_echo_error >/dev/null
  then
    g_echo_error "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}

# Keep the package check here: a missing tool must produce a clear error in
# the WebUI job instead of an empty SVG document.
if ! command -v qrencode >/dev/null 2>&1
then
  f_error "qrencode is missing - install it with the basics playbook."
  exit 1
fi

exec qrencode -t SVG -o -
