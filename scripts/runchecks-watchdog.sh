#!/bin/bash

# Watchdog for the runchecks health daemon.
#
# runchecks.sh exits cleanly (exit 0) on TERM/INT or when it detects a system
# shutdown, so Restart=on-failure may leave it dead forever. This watchdog
# runs independently via runchecks-watchdog.timer: if the results JSON is
# missing, unparsable or older than g_max_age seconds, it starts/restarts
# runchecks.service. A dead daemon cannot report its own death, hence this
# external check.

# Source gaboshlib and set up environment
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Maximum age of the results JSON before the daemon counts as dead
# (3 x 5min loop interval plus jitter)
g_max_age=900

g_json_file="${g_log_dir}/runchecks-results.json"

# Determine the age of the last successful run (-1 = missing/unparsable)
g_age=-1
if [[ -r "$g_json_file" ]]
then
  g_raw="$(cat "$g_json_file")"
  g_last_run="${g_raw#*\"last_run\": \"}"
  g_last_run="${g_last_run%%\"*}"
  if [[ "$g_last_run" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  then
    g_age=$(( $(date +%s) - $(date -u -d "$g_last_run" +%s) ))
  fi
fi

# Healthy: results are within the expected interval
if (( g_age >= 0 && g_age <= g_max_age ))
then
  g_echo_note "runchecks results are current (age ${g_age}s)"
  exit 0
fi

# Stale or unreadable: report and revive the daemon
if (( g_age < 0 ))
then
  g_echo_error "runchecks results missing or unparsable: $g_json_file"
else
  g_echo_error "runchecks results are stale (age ${g_age}s > ${g_max_age}s)"
fi

if systemctl is-active --quiet runchecks.service
then
  g_echo_note "runchecks.service active but not writing results - restarting"
  systemctl restart runchecks.service
else
  g_echo_note "runchecks.service inactive - starting"
  systemctl start runchecks.service
fi
