#!/bin/bash

function f_usage {
  cat << EOF
Usage: $(basename "$0")

SymbiOS health daemon (normally started via runchecks.service). Runs
continuously: every 5 minutes it executes all runchecks.d/*.check scripts
and writes the combined JSON result to <log>/runchecks-results.json, which
the WebUI reads for the sidebar status and the Health page.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source gaboshlib and set up environment
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
g_staleumount

g_json_file="${g_log_dir}/runchecks-results.json"

# Override g_echo_error to capture failures for JSON output. All errors of a
# single check are accumulated (separated by " | ") instead of overwriting,
# so e.g. multiple failing disks are all reported.
# The gaboshlib original would pipe every error into /usr/local/bin/notify.sh
# immediately (one notification per 5min cycle per persistent failure).
# Instead the notify call happens once per loop below with flap protection
# (only on state change), see the notify block after each check.
function g_echo_error {
  logger -t runchecks "ERROR: $*"
  g_current_check_failed=1
  if [[ -n "$g_current_check_error" ]]
  then
    g_current_check_error="${g_current_check_error} | $*"
  else
    g_current_check_error="$*"
  fi
}

# Override g_echo_warn to capture warnings without failing the check.
# Warnings never change the check status; they only feed the same
# flap-protected notify path as errors (honoring notify_level).
function g_echo_warn {
  logger -t runchecks "WARN: $*"
  if [[ -n "$g_current_check_warn" ]]
  then
    g_current_check_warn="${g_current_check_warn} | $*"
  else
    g_current_check_warn="$*"
  fi
}

# Exit cleanly on systemd stop (TERM/INT) and never write error results
# while the system is shutting down. The interruptible sleep (background +
# wait) makes bash react to the signal immediately instead of blocking.
function g_shutdown_exit {
  g_echo "Shutting down - not writing results"
  exit 0
}
trap g_shutdown_exit TERM INT

# Category definitions: id -> label|icon
# Each check sets CHECK_CATEGORY to one of these ids.
declare -A CATEGORIES=(
  [system]="Server Resources|bi-cpu"
  [services]="Core Services|bi-hdd-stack"
  [network]="Connectivity|bi-globe"
)

# Main loop - runs forever with 5min intervals
while true
do
  g_echo "Waiting 5min"
  sleep 300 &
  wait $!
  g_echo "Next Loop"

  # Skip the whole run while the system is shutting down (services are
  # already stopping, results would be bogus errors)
  if [[ "$(systemctl is-system-running 2>/dev/null || echo unknown)" == "stopping" ]]
  then
    g_shutdown_exit
  fi

  # Ensure g_tmp directory exists (may be cleaned between cycles)
  mkdir -p "$g_tmp"

  # Notification flap state: one file per check holding the last notified
  # severity (error|warn). Notifications go out only on state change, so a
  # persistent failure does not spam every 5 minutes. Same source as the
  # dispatcher itself: /etc/symbios-notify.conf when present (written by
  # base-services/notifications.yml, also covers ansible -e overrides),
  # inventory.yml as fallback. When no channel is enabled the whole block
  # below is skipped.
  g_notify_state_dir="${g_log_dir}/notify-state"
  mkdir -p "$g_notify_state_dir"
  if [[ -r /etc/symbios-notify.conf ]]
  then
    # shellcheck disable=SC1091
    source /etc/symbios-notify.conf
    g_notify_level="${notify_level:-warn}"
    g_notify_active=0
    [[ "${notify_mail_enabled:-false}" == "true" ]] && g_notify_active=1
    [[ "${notify_matrix_enabled:-false}" == "true" ]] && g_notify_active=1
  else
    g_notify_level="$(f_symbios_var notify_level "warn")"
    g_notify_active=0
    [[ "$(f_symbios_var notify_mail_enabled "false")" == "true" ]] && g_notify_active=1
    [[ "$(f_symbios_var notify_matrix_enabled "false")" == "true" ]] && g_notify_active=1
  fi

  g_json_results=""
  g_json_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Iterate over all .check scripts sorted alphabetically
  for g_check in $(find /usr/local/sbin/runchecks.d ${g_data_root}/runchecks.d ${g_git_root}/scripts/runchecks.d  -name "*.check" -type f | sort)
  do
    g_current_check_failed=0
    g_current_check_error=""
    g_current_check_warn=""

    # Extract metadata from the check file (before sourcing, so it works
    # even if the script returns early or fails). CHECK_TITLE/DESC are
    # single-line strings; CHECK_DETAIL uses | as line separator.
    g_check_title=$(grep '^CHECK_TITLE=' "$g_check" 2>/dev/null | head -1 | sed 's/^CHECK_TITLE=//; s/^"//; s/"$//')
    g_check_desc=$(grep '^CHECK_DESC=' "$g_check" 2>/dev/null | head -1 | sed 's/^CHECK_DESC=//; s/^"//; s/"$//')
    g_check_detail=$(grep '^CHECK_DETAIL=' "$g_check" 2>/dev/null | head -1 | sed 's/^CHECK_DETAIL=//; s/^"//; s/"$//')
    g_check_category=$(grep '^CHECK_CATEGORY=' "$g_check" 2>/dev/null | head -1 | sed 's/^CHECK_CATEGORY=//; s/^"//; s/"$//')
    # JSON-escape: backslash first, then double quotes
    g_check_title=$(echo "$g_check_title" | sed 's/\\/\\\\/g; s/"/\\"/g')
    g_check_desc=$(echo "$g_check_desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    g_check_detail=$(echo "$g_check_detail" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Validate syntax then source each check script
    if bash -n "$g_check" >$g_tmp/check_error 2>&1
    then
      g_echo "Running: $g_check"
      . "$g_check"
    else
      g_current_check_failed=1
      g_current_check_error="Syntax error in $g_check: $(cat $g_tmp/check_error)"
      logger -t runchecks "ERROR: $g_current_check_error"
    fi

    g_check_name=$(basename "$g_check" .check | sed 's/^symbios-healthcheck-//')
    # JSON-escape: backslash first, then double quotes (ps output contains \_)
    g_check_msg=$(echo "$g_current_check_error" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

    # Build JSON entry with metadata
    g_meta="\"title\":\"${g_check_title}\",\"desc\":\"${g_check_desc}\",\"detail\":\"${g_check_detail}\",\"category\":\"${g_check_category}\""
    if [[ "$g_current_check_failed" -eq 1 ]]
    then
      g_entry="{\"name\":\"${g_check_name}\",\"status\":\"error\",\"message\":\"${g_check_msg}\",${g_meta},\"script\":\"${g_check}\",\"checked\":\"${g_json_ts}\"}"
    else
      g_entry="{\"name\":\"${g_check_name}\",\"status\":\"ok\",${g_meta},\"script\":\"${g_check}\",\"checked\":\"${g_json_ts}\"}"
    fi

    [[ -n "$g_json_results" ]] && g_json_results="${g_json_results},${g_entry}" || g_json_results="${g_entry}"

    # Flap-protected notification for this check (Mail and/or Matrix via
    # /usr/local/bin/notify.sh, deployed by base-services/notifications.yml):
    # error on failed checks, warning on warnings (only when
    # notify_level=warn), recovery note on ok after a notified failure.
    if [[ "$g_notify_active" -eq 1 && -x /usr/local/bin/notify.sh ]]
    then
      g_notify_state_file="${g_notify_state_dir}/${g_check_name}"
      g_notify_last=""
      [[ -f "$g_notify_state_file" ]] && g_notify_last="$(cat "$g_notify_state_file" 2>/dev/null)"
      if [[ "$g_current_check_failed" -eq 1 ]]
      then
        if [[ "$g_notify_last" != "error" ]]
        then
          printf '%s' "Healthcheck ${g_check_name} FAILED: ${g_current_check_error}" \
            | /usr/local/bin/notify.sh -s "Healthcheck ${g_check_name} FAILED" 2>/dev/null || true
          echo "error" > "$g_notify_state_file"
        fi
      elif [[ -n "$g_current_check_warn" && "$g_notify_level" == "warn" ]]
      then
        if [[ "$g_notify_last" != "warn" ]]
        then
          printf '%s' "Healthcheck ${g_check_name} WARNING: ${g_current_check_warn}" \
            | /usr/local/bin/notify.sh -s "Healthcheck ${g_check_name} WARNING" 2>/dev/null || true
          echo "warn" > "$g_notify_state_file"
        fi
      elif [[ -n "$g_notify_last" ]]
      then
        printf '%s' "Healthcheck ${g_check_name} recovered." \
          | /usr/local/bin/notify.sh -s "Healthcheck ${g_check_name} recovered" 2>/dev/null || true
        rm -f "$g_notify_state_file"
      fi
    fi
  done

  # Build categories JSON from the CATEGORIES associative array
  g_json_cats=""
  for g_cat_id in "${!CATEGORIES[@]}"
  do
    g_cat_raw="${CATEGORIES[$g_cat_id]}"
    g_cat_label="${g_cat_raw%%|*}"
    g_cat_icon="${g_cat_raw##*|}"
    [[ -n "$g_json_cats" ]] && g_json_cats="${g_json_cats},"
    g_json_cats="${g_json_cats}{\"id\":\"${g_cat_id}\",\"label\":\"${g_cat_label}\",\"icon\":\"${g_cat_icon}\"}"
  done

  # Write JSON results
  g_json="{\"last_run\":\"${g_json_ts}\",\"categories\":[${g_json_cats}],\"checks\":[${g_json_results}]}"
  echo "$g_json" | python3 -m json.tool > "$g_json_file.tmp" 2>/dev/null && \
    mv "$g_json_file.tmp" "$g_json_file" || \
    echo "$g_json" > "$g_json_file"
done
