#!/bin/bash

# SymbiOS backup dispatcher - nightly entry point (cron /etc/cron.d/backup_local).

function f_usage {
  cat << EOF
Usage: $(basename "$0")

SymbiOS backup dispatcher. No arguments - this is the nightly cron entry point.

  1. Runs all *.backup modules from backup.d/ (pre-run dumps: LDAP export,
     MySQL/MariaDB/PostgreSQL dumps). The dumps land in \${backup_root}
     (= /symbios/backups) and are therefore part of every snapshot.
  2. Runs symbios-backup.sh which creates the daily main snapshot of the
     whole data root (/symbios): locally below /symbios/backup or on a
     remote SSH/SFTP server (optionally encrypted).

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
set -o pipefail

# Target directory for the pre-run database dumps of backup.d/*.backup.
#
# It has to live inside the data root, because symbios-backup.sh snapshots all
# of it and the dumps are the reason these modules run before the snapshot.
# It must not be below ${data_root}/backup: that path holds the snapshots
# themselves and is excluded from the rsync (see f_bk_write_excludes), so
# dumps stored there would never reach the backup server. backup_root
# (<data_root>/backups) is included in the snapshot and not excluded.
#
# g_backupdir was a gaboshlib global that no longer exists; with it unset the
# modules redirected their dumps to "/<name>" and silently backed up nothing.
g_backupdir="${g_backup_root}/db"
mkdir -p "$g_backupdir"

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
