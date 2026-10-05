#!/bin/bash
# SymbiOS - Reboot or shut down the whole host from the WebUI.
#
# Usage: symbios-power.sh reboot|shutdown
#
# Prints what it is about to do (so the WebUI exec modal sees the action in
# the live output and treats the following connection loss as expected),
# waits a few seconds so the browser can poll that output, then reboots or
# powers the machine off via shutdown(8).

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Only the two documented actions are accepted - anything else is refused
# so a crafted request can never run an arbitrary command here.
f_action="${1:-}"
if [[ "${f_action}" != "reboot" && "${f_action}" != "shutdown" ]]
then
  g_echo_error "Usage: $(basename "$0") reboot|shutdown"
  exit 2
fi

# Announce the action first: the WebUI exec modal watches the live output
# for "reboot"/"shutdown" and treats the following connection loss as the
# expected power action instead of a network error.
if [[ "${f_action}" == "reboot" ]]
then
  g_echo_note "Rebooting the whole SymbiOS host now - the WebUI will be back after the boot (unlock LUKS at the boot page if asked)."
else
  g_echo_note "Shutting down the whole SymbiOS host now - it stays off until powered on again."
fi

# Give the browser a few poll cycles to fetch the lines above before the
# SSH session dies with the machine.
sleep 5

# Cancel a previously scheduled shutdown first so it cannot interfere.
shutdown -c 2>/dev/null || true
if [[ "${f_action}" == "reboot" ]]
then
  shutdown -r now "SymbiOS WebUI reboot." 2>/dev/null || true
else
  shutdown -h now "SymbiOS WebUI shutdown." 2>/dev/null || true
fi
exit 0
