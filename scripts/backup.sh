#!/bin/bash
. /etc/bash/gaboshlib.include
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
set -o pipefail
BACKUPDIR=/home/backup
mkdir -p ${BACKUPDIR}
chmod 700 ${BACKUPDIR}
chown root:root ${BACKUPDIR}
for backup in $(find /usr/local/sbin/backup.d -name "*.backup" -type f | sort)
do
  if bash -n "$backup" >$g_tmp/backup_error 2>&1
  then
    g_echo "Running: $backup"
    . "$backup"
  else
    g_echo_error "Error in $backup $(cat $g_tmp/backup_error)"
    continue
  fi
done
g_echo "Backup script finished"
