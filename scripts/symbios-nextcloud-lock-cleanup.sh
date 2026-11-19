#!/bin/bash
# SymbiOS - Report and remove stale LibreOffice/Collabora lock files in Nextcloud.
#
# Notes and collaborative Text locks live in the database/Redis and expire via
# files_lock lock_timeout. LibreOffice/Collabora instead leave plain
# ".~lock.<file>#" files in the user's files tree; neither occ files:cleanup
# nor the lock timeout ever sees them. A stale one makes the file look
# permanently locked by another user and blocks editing and syncing.
#
# Only files older than the threshold are touched, every removal is logged.
# The nightly clean leaves its report in a small cache file; the 5-minute
# healthcheck reads that cache instead of rescanning the whole data tree.

set -o pipefail

# Load shared helpers: all paths come from symbios-lib.sh, no host specifics.
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <report|clean> [--older-than DAYS] [--dry-run]

Report or remove stale LibreOffice/Collabora lock files in Nextcloud data.

Actions:
  report                Show cached stale locks ("user | age-days | path");
                        scans once if no cache exists yet
  clean                 Remove stale locks, refresh the report cache
Options:
  --older-than DAYS     Age threshold in days (default: 7)
  --dry-run             With clean: show candidates without deleting
  -h, --help            Show this help and exit

Exit codes: 0 ok, 1 technical error, 2 usage/validation error
EOF
}

# Parse arguments strictly: a typo must never turn into a cleanup run.
f_action=""
f_days=7
f_dry_run=0
while [[ $# -gt 0 ]]
do
  case "$1" in
    report|clean)
      if [[ -n "${f_action}" ]]
      then
        g_echo_error "Only one action allowed"
        f_usage >&2
        exit 2
      fi
      f_action="$1"
      shift
      ;;
    --older-than)
      if [[ $# -lt 2 ]]
      then
        g_echo_error "Missing value for --older-than"
        exit 2
      fi
      f_days="$2"
      shift 2
      ;;
    --dry-run)
      f_dry_run=1
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${f_action}" ]]
then
  g_echo_error "Missing action (report or clean)"
  f_usage >&2
  exit 2
fi

if ! [[ "${f_days}" =~ ^[1-9][0-9]*$ ]]
then
  g_echo_error "--older-than must be a positive integer (days)"
  exit 2
fi

if [[ "${f_action}" == "report" && "${f_dry_run}" -eq 1 ]]
then
  g_echo_error "--dry-run only applies to clean"
  f_usage >&2
  exit 2
fi

# Cache file for the healthcheck: rescanning 463 GB every 5 min is too slow.
g_lock_report_cache="${g_log_dir}/nextcloud-locks-report.txt"

# Print one line per candidate with the owning uid and its age in days.
function f_report_line {
  local f_file="$1"
  local f_rel="${f_file#${g_nc_data_dir}/}"
  local f_user="${f_rel%%/*}"
  local f_mtime f_age
  f_mtime="$(stat -c %Y "$f_file" 2>/dev/null || echo 0)"
  f_age=$((( $(date +%s) - f_mtime ) / 86400))
  printf '%s | %s | %s\n' "$f_user" "$f_age" "$f_file"
}

# Collect only .~lock.*# files inside user files trees, older than the limit.
function f_collect_candidates {
  g_nc_data_dir="${g_services_root}/nextcloud/nextcloud-data/data"
  local f_minutes=$((f_days * 1440))
  local f_file
  f_candidates=()
  if [[ -d "${g_nc_data_dir}" ]]
  then
    while IFS= read -r -d '' f_file
    do
      f_candidates+=("$f_file")
    done < <(find "${g_nc_data_dir}" -type f -name '.~lock.*#' -path '*/files/*' -mmin "+${f_minutes}" -print0 2>/dev/null)
  fi
}

# Replace the cache atomically so the healthcheck never reads a partial report.
function f_write_report_cache {
  local f_tmp f_file
  mkdir -p "${g_log_dir}" 2>/dev/null || true
  f_tmp="$(mktemp "${g_lock_report_cache}.XXXXXX")" || return 1
  for f_file in "$@"
  do
    f_report_line "$f_file"
  done >"$f_tmp"
  mv -f -- "$f_tmp" "$g_lock_report_cache"
}

# The healthcheck reads the cached report; only a missing cache triggers a
# live scan (first run after install or after the log dir was cleared).
if [[ "${f_action}" == "report" ]]
then
  if [[ -r "${g_lock_report_cache}" ]]
  then
    cat -- "${g_lock_report_cache}"
    exit 0
  fi
  f_collect_candidates
  f_write_report_cache "${f_candidates[@]}" || true
  for f_file in "${f_candidates[@]}"
  do
    f_report_line "$f_file"
  done
  exit 0
fi

f_collect_candidates

# Remove only the selected files, log every removal and refresh the cache so
# deleted locks disappear from the healthcheck immediately.
function f_clean {
  local f_file
  local f_failed=0
  local -a f_remaining=()
  local f_log="${g_log_dir}/nextcloud-lock-cleanup.log"
  mkdir -p "${g_log_dir}" 2>/dev/null || true
  for f_file in "${f_candidates[@]}"
  do
    if [[ "${f_dry_run}" -eq 1 ]]
    then
      printf 'DRY-RUN: %s\n' "$f_file"
      continue
    fi
    if ! rm -f -- "$f_file"
    then
      g_echo_error "Could not remove lock: $f_file"
      f_remaining+=("$f_file")
      f_failed=1
      continue
    fi
    printf '%s removed stale lock: %s\n' "$(date --iso-8601=seconds)" "$f_file" >>"$f_log"
    g_echo_note "Removed stale lock: $f_file"
  done
  if [[ "${f_dry_run}" -eq 0 ]]
  then
    f_write_report_cache "${f_remaining[@]}" || f_failed=1
  fi
  return "${f_failed}"
}

f_clean
