#!/bin/bash
# SymbiOS - Manage the single daily maintenance window (backup, then updates).
#
# CLI-first settings script: the WebUI page /settings/maintenance/ only calls
# this script, which owns validation and the inventory.yml write. One cron job
# (base-services/maintenance.yml) uses maintenance_time, so backup and updates
# can never overlap.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage the SymbiOS maintenance window (24h HH:MM). The backup (when enabled)
and all updates run in this one window, backup first.

Commands:
  get [--json]            Print the current time (key=value or JSON object)
  set [--time HH:MM | --json-stdin] [--check] [--no-apply]
                          Validate and write maintenance_time to inventory.yml,
                          then apply consuming playbooks unless --no-apply is
                          given. --json-stdin reads {"maintenance_time":"HH:MM"}.
                          --check reports what would change, changes nothing.
  schema                  Print the field description as JSON
  apply [--dry-run]       Resolve consuming playbooks (or show them with
                          --dry-run) and run each in order.
  -h, --help              Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (maintenance-changed / maintenance-unchanged).

Examples:
  $(basename "$0") get
  $(basename "$0") set --time 03:30
  echo '{"maintenance_time":"03:30"}' | $(basename "$0") set --json-stdin
  $(basename "$0") set --time 03:30 --check

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (invalid time, unknown option, ...)
  1  technical error (inventory unreadable, helper failed, ...)
EOF
}

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="maintenance_time"

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

# --- option parsing ------------------------------------------------------------

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema|apply)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "apply" ]]
then
  f_ss_apply_cmd "$@"
  exit $?
fi

if [[ "${f_command}" == "schema" ]]
then
  if [[ $# -gt 0 ]]
  then
    echo "Unknown option for schema: $1" >&2
    f_ss_fail_usage
  fi
  cat << 'EOF'
[
  {"name": "maintenance_time", "type": "text", "label": "Maintenance time (24h HH:MM)",
   "required": true, "default": "00:05", "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$",
   "placeholder": "00:05", "secret": false,
   "note": "Backup runs first (if enabled), then all updates. Both share this one cron job."}
]
EOF
  exit 0
fi

# --- current value -------------------------------------------------------------

f_cur_time="$(f_symbios_var maintenance_time "00:05")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"maintenance_time": %s}\n' \
      "$(printf '%s' "${f_cur_time}" | f_json_escape)"
    exit 0
  fi
  if [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "maintenance_time=${f_cur_time}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_time=""
f_given_time="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --time)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_time="$2"
      f_given_time="yes"
      shift 2
      ;;
    --json-stdin)
      f_json_stdin="yes"
      shift
      ;;
    --check)
      f_check="yes"
      shift
      ;;
    --no-apply)
      g_ss_no_apply="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      f_ss_fail_usage
      ;;
  esac
done

if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  f_val="$(f_json_get "${f_json}" "maintenance_time" 2>/dev/null)" && [[ -n "${f_val}" ]] && {
    f_new_time="${f_val}"
    f_given_time="yes"
  }
fi

if [[ "${f_given_time}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --time or --json-stdin"
fi

# --- validation ---------------------------------------------------------------

if ! [[ "${f_new_time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
then
  f_ss_fail_validation "Invalid maintenance time: ${f_new_time} (expected HH:MM, 00:00-23:59)"
fi

# --- transactional write -------------------------------------------------------

f_merge="$(printf '{"maintenance_time": %s}' \
  "$(printf '%s' "${f_new_time}" | f_json_escape)")"

f_ss_merge "${f_merge}" "maintenance" "${f_check}" "${f_new_time}"
f_ss_finish
exit $?
