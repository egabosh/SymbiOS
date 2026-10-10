#!/bin/bash
# SymbiOS - WoL trigger: tail the access log, send a magic packet when a
# sleeping target is requested.
#
# Usage: symbios-wol-watch-tail.sh <target>   (started via wol-tail@<target>.service)
#
# Everything referenced here - script, SSH key, access log - lives under
# /symbios, which may unlock late after a reboot. The watcher waits for
# those paths instead of failing at boot.

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"
source "${g_script_dir}/symbios-wol-common.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <target>

Tail the access log and send a Wake-on-LAN magic packet to <target> when a
request for one of its patterns arrives while the target is down.
EOF
}

if [[ -z "${1:-}" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

WOL_NAME="$1"
f_wol_wait_ready "log"

g_echo_note "wol-tail for ${WOL_NAME}: watching ${WOL_LOG_PATH}"

# Both greps need --line-buffered: stdout to a pipe is block-buffered by
# default, so rare matches would sit in the second grep's 4K buffer for hours
# and the wake trigger would arrive far too late (or never).
exec tail -F "${WOL_LOG_PATH}" 2>/dev/null \
  | grep -a --line-buffered -E "${WOL_WAKE_RE}" \
  | grep --line-buffered -v '"RequestPath":"/"' \
  | while read -r f_line
  do
    # Config may change at runtime (WebUI apply) - re-read each round.
    f_wol_load_conf "${WOL_NAME}" || continue
    if [[ "${WOL_WAKE_ENABLED}" != "true" ]]
    then
      continue
    fi
    # Rate-limit to one check per 10 seconds.
    if [[ -f "${WOL_PINGFILE}" ]]
    then
      f_age=$(( EPOCHSECONDS - $(cat "${WOL_PINGFILE}") ))
      if [[ "${f_age}" -lt 10 ]]
      then
        continue
      fi
    fi
    echo "${EPOCHSECONDS}" > "${WOL_PINGFILE}"
    if ping -c1 -W2 "${WOL_WAKE_HOST}" &>/dev/null
    then
      continue
    fi
    f_host="$(echo "${f_line}" | sed 's/.*"RequestAddr":"\([^"]*\)".*/\1/')"
    g_echo "WoL ${WOL_NAME} triggered by ${f_host} (${WOL_WAKE_HOST} down)"
    f_wol_send
  done
