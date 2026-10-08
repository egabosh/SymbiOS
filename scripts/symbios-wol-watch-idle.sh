#!/bin/bash
# SymbiOS - Idle suspend: suspend the target over SSH when it has been idle
# longer than IDLE_TIMEOUT and no activity check reports it busy.
#
# Usage: symbios-wol-watch-idle.sh <target>   (started via wol-idle@<target>.service)
#        symbios-wol-watch-idle.sh <target> --check   (one dry run, never suspends)
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
Usage: $(basename "$0") <target> [--check]

Loop every 5 minutes and suspend <target> over SSH once it is idle.
With --check, run the evaluation once, print every check result and
never suspend (dry run for the WebUI test button).
EOF
}

if [[ -z "${1:-}" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

WOL_NAME="$1"
f_wol_wait_ready "log"

# Evaluate all checks once. Prints "<busy|idle>: <reason>" per check and
# returns 0 when the target may be suspended, 1 when it counts as busy.
function f_evaluate {
  local f_result
  local f_may_suspend=0
  for f_check in log_idle ping grace tcp extra_local extra_remote nosuspend ssh_sessions
  do
    if f_result="$(f_wol_check_${f_check})"
    then
      echo "busy: ${f_result}"
      f_may_suspend=1
    else
      echo "idle: ${f_result}"
    fi
  done
  return "${f_may_suspend}"
}

if [[ "${2:-}" == "--check" ]]
then
  f_evaluate
  if [[ "$?" -eq 0 ]]
  then
    echo "RESULT: would suspend ${WOL_SUSPEND_HOST} now"
  else
    echo "RESULT: target counts as busy, no suspend"
  fi
  exit 0
fi

g_echo_note "wol-idle for ${WOL_NAME}: checking every 5 minutes"

while true
do
  sleep 300
  # Config may change at runtime (WebUI apply) - re-read each round.
  f_wol_load_conf "${WOL_NAME}" || continue
  if [[ "${WOL_SUSPEND_ENABLED}" != "true" ]]
  then
    continue
  fi
  # Target reachable again (e.g. woken by a request): resume monitoring.
  if ping -c1 -W2 "${WOL_SUSPEND_HOST}" &>/dev/null
  then
    f_asleep_remove
  fi
  if f_evaluate > /dev/null
  then
    g_echo_warn "${WOL_SUSPEND_HOST} idle - suspending via SSH"
    # Arm the NIC Wake-on flag right before suspending; a suspend with an
    # un-armed flag leaves the box unreachable until a manual power-cycle.
    ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" "ethtool -s ${WOL_SUSPEND_IF} wol g" &>/dev/null
    ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" "systemctl suspend" &>/dev/null
    echo "${EPOCHSECONDS}" > "${WOL_LAST_WOL_FILE}"
    # Tell the Traefik healthcheck to skip this target's routes until it
    # is back (expected 502s while sleeping must not alert).
    f_asleep_add
  fi
done
