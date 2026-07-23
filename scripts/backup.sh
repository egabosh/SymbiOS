#!/bin/bash

# SymbiOS backup dispatcher - runs all .check scripts from backup.d/
. /etc/bash/gaboshlib.include
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
set -o pipefail

g_backupdir=/home/backup
mkdir -p ${g_backupdir}
chmod 700 ${g_backupdir}
chown root:root ${g_backupdir}

for g_backup in $(find /usr/local/sbin/backup.d /home/SymbiOS/scripts/backup.d -name "*.backup" -type f | sort)
do
  if bash -n "$g_backup" >$g_tmp/backup_error 2>&1
  then
    g_echo "Running: $g_backup"
    . "$g_backup"
  else
    g_echo_error "Error in $g_backup $(cat $g_tmp/backup_error)"
    continue
  fi
done
g_echo "Backup script finished"
