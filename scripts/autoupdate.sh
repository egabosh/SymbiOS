#!/bin/bash
. /etc/bash/gaboshlib.include
g_nice
g_lockfile
g_all-to-syslog
DISPLAY=""
set -o pipefail
for update in $(find /usr/local/sbin/autoupdate.d /home/SymbiOS/scripts/autoupdate.d -name "*.update" -type f | sort)
do
  g_echo "Running: $update"
  . "$update"
done
