#!/bin/bash

# SymbiOS maintenance dispatcher - the single cron entry point.
# Backup (when enabled) always runs before the update modules.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

SymbiOS maintenance dispatcher. No arguments - this is the cron entry point.

  1. Runs backup.sh when backup_enabled is true (Settings -> Backup).
  2. Runs autoupdate.sh with all update modules (OS, Docker, SymbiOS, ...).

A shared lock keeps manual backup.sh / autoupdate.sh runs from overlapping
this sequence. Output is appended to <log>/maintenance.log and syslog.

Options:
  -h, --help          Show this help and exit

Exit codes: 0 = ok, 2 = usage error, 1 = a phase failed.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# No subcommands: a typo must not silently start a maintenance run.
if [[ $# -gt 0 ]]
then
  echo "Unknown command: $1 (this script takes no arguments)" >&2
  f_usage >&2
  exit 2
fi

. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Shared lock for all three dispatchers. The children skip their own flock
# when this marker is set, otherwise they would block on the parent's lock.
exec 9>/run/symbios-maintenance.lock
if ! flock -x -n 9
then
  g_echo_error "Another SymbiOS maintenance run is active - exiting."
  exit 1
fi
export SYMBIOS_MAINTENANCE_LOCK_HELD=1

g_lockfile
g_nice

# Log to the WebUI-visible file first, then let gaboshlib mirror every line to
# syslog. The background reader inherits this redirect, so both sinks work.
mkdir -p "${g_log_dir}" 2>/dev/null || true
g_maintenance_log="${g_log_dir}/maintenance.log"
# Keep the daily log bounded like autoupdate.log.
if [[ -f "${g_maintenance_log}" ]] && [[ "$(wc -l < "${g_maintenance_log}")" -gt 10000 ]]
then
  tail -n 4000 "${g_maintenance_log}" > "${g_maintenance_log}.tmp" \
    && mv "${g_maintenance_log}.tmp" "${g_maintenance_log}"
fi
exec > >(tee -a "${g_maintenance_log}") 2>&1
g_all-to-syslog
g_echo_ok "Starting $0"
set -o pipefail

g_maintenance_rc=0

# Phase 1: backup only while explicitly enabled (default off, needs space).
if [[ "$(f_symbios_var backup_enabled)" == "true" ]]
then
  g_echo "Phase 1/2: backup"
  "${g_git_root}/scripts/backup.sh" || g_maintenance_rc=1
else
  g_echo "Phase 1/2: backup disabled - skipping"
fi

# Phase 2: updates run even if the backup phase failed, so a temporarily
# unavailable backup target does not block security updates.
g_echo "Phase 2/2: updates"
"${g_git_root}/scripts/autoupdate.sh" || g_maintenance_rc=1

g_echo "Maintenance finished (rc=${g_maintenance_rc})"
exit ${g_maintenance_rc}
