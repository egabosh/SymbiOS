#!/bin/bash

# SymbiOS backup dispatcher - nightly entry point (cron /etc/cron.d/backup_local).
#
# 1. Runs all *.backup modules from backup.d/ (pre-run dumps: LDAP export,
#    MySQL/MariaDB/PostgreSQL dumps). The dumps land in ${backup_root}
#    (= /symbios/backups) and are therefore part of every snapshot.
# 2. Runs symbios-backup.sh which creates the daily main snapshot of the
#    whole data root (/symbios): locally below /symbios/backup or on a
#    remote SSH/SFTP server (optionally encrypted).
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
set -o pipefail

# Pre-run dumps (database exports) - failures must not stop the snapshot.
for g_backup in $(find /usr/local/sbin/backup.d ${g_data_root}/backup.d ${g_git_root}/scripts/backup.d -name "*.backup" -type f | sort)
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

# Main snapshot of the whole data root (local/remote, optional encryption)
if [[ -x "${g_git_root}/scripts/symbios-backup.sh" ]]
then
  "${g_git_root}/scripts/symbios-backup.sh"
else
  g_echo_error "symbios-backup.sh not found - no main snapshot created"
fi
g_echo "Backup script finished"
