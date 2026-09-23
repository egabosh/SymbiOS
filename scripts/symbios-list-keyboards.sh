#!/bin/bash
# SymbiOS - List available keyboard layouts from XKB symbols directory

function f_usage {
  cat << EOF
Usage: $(basename "$0")

List available keyboard layouts from the XKB symbols directory for the
WebUI (Settings -> Localization). Output: one layout name per line, sorted,
built-in modifier/utility files filtered out. No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include

find /usr/share/X11/xkb/symbols -maxdepth 1 -type f 2>/dev/null \
  | xargs -I{} basename {} \
  | grep -vE '^(pc|keypad|compose|ctrl|shift|level|capslock|scrolllock|terminate|altwin|kpdl|nbsp|srvr|macintosh|olpc|empty|trans|typo|group|latin|bqn|brai|inet|rupeesign|eurosign|parens|misc|ancient|apl|grab)' \
  | sort
