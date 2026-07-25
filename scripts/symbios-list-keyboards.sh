#!/bin/bash
# SymbiOS - List available keyboard layouts from XKB symbols directory
# Output: one layout name per line, sorted

source /etc/bash/gaboshlib.include

find /usr/share/X11/xkb/symbols -maxdepth 1 -type f 2>/dev/null \
  | xargs -I{} basename {} \
  | grep -vE '^(pc|keypad|compose|ctrl|shift|level|capslock|scrolllock|terminate|altwin|kpdl|nbsp|srvr|macintosh|olpc|empty|trans|typo|group|latin|bqn|brai|inet|rupeesign|eurosign|parens|misc|ancient|apl|grab)' \
  | sort
