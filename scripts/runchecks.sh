#!/bin/bash
# Source gaboshlib and set up environment
. /etc/bash/gaboshlib.include
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"
g_staleumount

g_json_file="/home/docker/symbios-ui/log/runchecks-results.json"

# Override g_echo_error to capture failures for JSON output
g_echo_error() {
  logger -t runchecks "ERROR: $*"
  G_CURRENT_CHECK_FAILED=1
  G_CURRENT_CHECK_ERROR="$*"
}

# Main loop - runs forever with 5min intervals
while true
do
  g_echo "Waiting 5min"
  sleep 300
  g_echo "Next Loop"

  # Ensure g_tmp directory exists (may be cleaned between cycles)
  mkdir -p "$g_tmp"

  g_json_results=""
  g_json_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Iterate over all .check scripts sorted alphabetically
  for g_check in $(find /usr/local/sbin/runchecks.d /home/SymbiOS/scripts/runchecks.d  -name "*.check" -type f | sort)
  do
    G_CURRENT_CHECK_FAILED=0
    G_CURRENT_CHECK_ERROR=""

    # Validate syntax then source each check script
    if bash -n "$g_check" >$g_tmp/check_error 2>&1
    then
      g_echo "Running: $g_check"
      . "$g_check"
    else
      G_CURRENT_CHECK_FAILED=1
      G_CURRENT_CHECK_ERROR="Syntax error in $g_check: $(cat $g_tmp/check_error)"
      logger -t runchecks "ERROR: $G_CURRENT_CHECK_ERROR"
    fi

    g_check_name=$(basename "$g_check" .check | sed 's/^symbios-healthcheck-//')
    g_check_msg=$(echo "$G_CURRENT_CHECK_ERROR" | sed 's/"/\\"/g' | tr '\n' ' ')

    if [ "$G_CURRENT_CHECK_FAILED" -eq 1 ]
    then
      g_entry="{\"name\":\"${g_check_name}\",\"status\":\"error\",\"message\":\"${g_check_msg}\",\"checked\":\"${g_json_ts}\"}"
    else
      g_entry="{\"name\":\"${g_check_name}\",\"status\":\"ok\",\"checked\":\"${g_json_ts}\"}"
    fi

    [ -n "$g_json_results" ] && g_json_results="${g_json_results},${g_entry}" || g_json_results="${g_entry}"
  done

  # Write JSON results
  g_json="{\"last_run\":\"${g_json_ts}\",\"checks\":[${g_json_results}]}"
  echo "$g_json" | python3 -m json.tool > "$g_json_file.tmp" 2>/dev/null && \
    mv "$g_json_file.tmp" "$g_json_file" || \
    echo "$g_json" > "$g_json_file"
done
