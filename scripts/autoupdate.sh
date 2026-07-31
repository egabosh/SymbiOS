#!/bin/bash

# SymbiOS autoupdate dispatcher - runs all .update scripts from autoupdate.d/
. /etc/bash/gaboshlib.include
source symbios-lib.sh
g_nice
g_lockfile
g_all-to-syslog
DISPLAY=""
set -o pipefail

for g_update in $(find /usr/local/sbin/autoupdate.d ${g_git_root}/scripts/autoupdate.d -name "*.update" -type f | sort)
do
  g_echo "Running: $g_update"
  . "$g_update"
done
