#!/bin/bash
# SymbiOS - Build static GoAccess reports for the installed Traefik hosts.
#
# The WebUI must not parse the live log itself, so this script is called by a
# cron job and writes ready-to-serve HTML reports plus a small index below
# <log_dir>/traefik-stats/. The host list comes from the Traefik Host labels of
# the installed services, including custom domains such as WordPress instances.
# Both the current log and the rotated logs are included. Lines are normalized
# with jq
# so old JSON records without the newly enabled User-Agent/Referer header
# fields stay parseable.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Build one static GoAccess HTML report per installed host in the Traefik access
log so the SymbiOS WebUI can show web statistics without parsing the log on
page load. No arguments.

Reads:
  <base_services_root>/traefik/log/access.log
  <base_services_root>/traefik/log/access.log.1
  <base_services_root>/traefik/log/access.log.*.gz
  Traefik Host labels from the installed services (via symbios-lib.sh)

Writes:
  <log_dir>/traefik-stats/index.json                   generated_at + host list
  <log_dir>/traefik-stats/reports/<host>.html          one report per host
  <log_dir>/traefik-stats/summaries/<host>.json        compact tables for the WebUI
  <log_dir>/traefik-stats/invalid/<host>.log           lines GoAccess skipped

Options:
  -h, --help          Show this help and exit

Exit codes:
  0                   Reports generated
  1                   Technical error (missing tool, log or installed host)
  2                   Unknown argument
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
# Inline guard: older hosts may not provide f_no_args in symbios-lib.sh yet.
if [[ $# -gt 0 ]]
then
  f_usage >&2
  exit 2
fi
g_lockfile
g_nice
set -o pipefail

# Required tools. jq normalizes the JSON records into the exact field order
# expected by the GoAccess format string below; python3 builds the summaries.
for f_tool in goaccess jq python3 zcat
do
  if ! command -v "$f_tool" >/dev/null 2>&1
  then
    g_echo_error "Missing required tool: $f_tool"
    exit 1
  fi
done

# Collect the live log, the delayed-compression rotation and all gzip archives.
f_log_dir="${g_base_services_root}/traefik/log"
f_inputs=()
if [[ -f "$f_log_dir/access.log" ]]
then
  f_inputs+=("$f_log_dir/access.log")
fi
if [[ -f "$f_log_dir/access.log.1" ]]
then
  f_inputs+=("$f_log_dir/access.log.1")
fi
for f_file in "$f_log_dir"/access.log.*.gz
do
  if [[ -f "$f_file" ]]
  then
    f_inputs+=("$f_file")
  fi
done
if (( ${#f_inputs[@]} == 0 ))
then
  g_echo_error "No Traefik access log found below $f_log_dir"
  exit 1
fi

# Derive the report hosts from the installed Traefik routes. The shared helper
# already skips disabled service directories, so no second inventory is needed.
mapfile -t f_hosts < <(
  f_symbios_traefik_hosts
  grep -o 'Host(`[^`]*`)' "$g_tmp/hosts" \
    | sed -e 's/^Host(`//' -e 's/`)$//' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u \
    | while read -r f_host
      do
        # Only real host names get a report; all installed routes count, not
        # just hosts below the base domain.
        [[ "$f_host" =~ ^[a-z0-9.-]+$ ]] || continue
        [[ "$f_host" != *"*"* ]] || continue
        printf '%s\n' "$f_host"
      done
)
if (( ${#f_hosts[@]} == 0 ))
then
  g_echo_error "No installed Traefik host found"
  exit 1
fi

f_report_dir="${g_log_dir}/traefik-stats"
f_staging="${f_report_dir}/.build.$$"
mkdir -p "$f_report_dir" || exit 1
# An interrupted run leaves a full staging tree behind (reboot, kill, OOM).
# Only remove trees older than two hours so a still-running job is untouched.
find "$f_report_dir" -maxdepth 1 -type d -name '.build.*' -mmin +120 \
  -exec rm -rf {} + 2>/dev/null || true
rm -rf "$f_staging"
mkdir -p "$f_staging/hosts" "$f_staging/reports" "$f_staging/summaries" \
  "$f_staging/invalid" || exit 1

# Old records have no header fields; add empty placeholders so one format
# string parses the whole rotation. The key order here must match f_log_format.
# Query strings are stripped here as well: the Debian build uses a 4 KiB line
# buffer and Nextcloud uploads produce URLs far larger than that.
f_jq_filter='{ClientHost: (.ClientHost // "-"), ClientUsername: (.ClientUsername // "-"), DownstreamContentSize: (.DownstreamContentSize // 0), DownstreamStatus: (.DownstreamStatus // 0), Duration: (.Duration // 0), RequestHost: (.RequestHost // "-"), RequestMethod: (.RequestMethod // "-"), RequestPath: ((.RequestPath // "-") | split("?")[0] | .[0:2048]), RequestProtocol: (.RequestProtocol // "-"), request_Referer: (.["request_Referer"] // "-"), "request_User-Agent": (.["request_User-Agent"] // "-"), time: (.time // "")}'

# GoAccess matches JSON logs by literal field order. --no-global-config keeps
# the panel set deterministic regardless of /etc/goaccess/goaccess.conf.
f_log_format='{"ClientHost":"%h","ClientUsername":"%e","DownstreamContentSize":"%b","DownstreamStatus":"%s","Duration":"%n","RequestHost":"%v","RequestMethod":"%m","RequestPath":"%U","RequestProtocol":"%H","request_Referer":"%R","request_User-Agent":"%u","time":"%dT%t"}'

# The WebUI summary is built from the same normalized records, not from a
# second GoAccess run. symbios-traefik-summary.py accumulates all tables in
# one pass; repeated jq group_by/unique passes dominated the hourly CPU load.

# Normalize and split in one pass. Writing each record straight to its host
# file avoids re-reading the whole normalized log once per installed host.
f_log_size="$(du -cb "${f_inputs[@]}" | tail -n 1 | cut -f1)"
printf '%s\n' "${f_hosts[@]}" >"$f_staging/hosts.list" || exit 1
for f_host in "${f_hosts[@]}"
do
  : >"$f_staging/hosts/${f_host}.json" || exit 1
done
if ! zcat -f "${f_inputs[@]}" \
  | jq -c "$f_jq_filter" \
  | awk -v f_dir="$f_staging/hosts" -v f_list="$f_staging/hosts.list" '
      BEGIN {
        while ((getline f_allowed_host < f_list) > 0) f_hosts[f_allowed_host] = 1
        close(f_list)
      }
      {
        if (match($0, /"RequestHost":"[^"]*"/))
        {
          f_hostname = substr($0, RSTART, RLENGTH)
          sub(/^"RequestHost":"/, "", f_hostname)
          sub(/"$/, "", f_hostname)
          # Only installed hosts get a file: RequestHost comes from the log
          # and must never become an arbitrary path below the staging dir.
          if (f_hostname in f_hosts)
          {
            print > (f_dir "/" f_hostname ".json")
          }
        }
      }'
then
  rm -rf "$f_staging"
  g_echo_error "Failed to normalize and split the Traefik access log"
  exit 1
fi

# Build one report and one summary per installed host, then record its status.
: >"$f_staging/domains.jsonl" || exit 1
f_generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for f_host in "${f_hosts[@]}"
do
  f_host_log="$f_staging/hosts/${f_host}.json"
  f_host_summary="$f_staging/summaries/${f_host}.json"
  f_host_report="$f_staging/reports/${f_host}.html"
  f_host_invalid="$f_staging/invalid/${f_host}.log"
  : >"$f_host_invalid"

  if ! goaccess "$f_host_log" \
      --no-global-config \
      --log-format="$f_log_format" \
      --date-format='%Y-%m-%d' \
      --time-format='%T%z' \
      --log-size="$f_log_size" \
      --no-query-string \
      --no-strict-status \
      --no-progress \
      --invalid-requests="$f_host_invalid" \
      -o "$f_host_report"
  then
    rm -rf "$f_staging"
    g_echo_error "GoAccess failed to parse the Traefik log for $f_host"
    exit 1
  fi
  if ! python3 "$g_symbios_dir/symbios-traefik-summary.py" \
    --host "$f_host" \
    --generated "$f_generated_at" \
    "$f_host_log" >"$f_host_summary"
  then
    rm -rf "$f_staging"
    g_echo_error "Failed to build the statistics summary for $f_host"
    exit 1
  fi
  f_invalid_lines="$(wc -l <"$f_host_invalid")"
  if ! jq -n \
    --arg host "$f_host" \
    --argjson invalid "$f_invalid_lines" \
    '{host: $host, invalid_requests: $invalid}' >>"$f_staging/domains.jsonl"
  then
    rm -rf "$f_staging"
    g_echo_error "Failed to record the report status for $f_host"
    exit 1
  fi
done

# The index is the WebUI's only source of installed hosts and report ages.
if ! jq -n \
  --arg generated "$f_generated_at" \
  --slurpfile domains "$f_staging/domains.jsonl" \
  '{generated_at: $generated, domains: $domains}' >"$f_staging/index.json"
then
  rm -rf "$f_staging"
  g_echo_error "Failed to write the Traefik statistics index"
  exit 1
fi

# Swap the finished set into place so the WebUI never sees a partial report.
rm -rf "${f_report_dir}/reports" "${f_report_dir}/summaries" "${f_report_dir}/invalid"
mv "$f_staging/reports" "${f_report_dir}/reports" || exit 1
mv "$f_staging/summaries" "${f_report_dir}/summaries" || exit 1
mv "$f_staging/invalid" "${f_report_dir}/invalid" || exit 1
mv "$f_staging/index.json" "${f_report_dir}/index.json" || exit 1
rm -rf "$f_staging"

# Remove artifacts of the previous single-report implementation.
rm -f "${f_report_dir}/report.html" "${f_report_dir}/status.json" \
  "${f_report_dir}/invalid-requests.log"

f_invalid_total="$(jq -r '[.domains[].invalid_requests] | add // 0' "${f_report_dir}/index.json")"
if (( f_invalid_total > 0 ))
then
  g_echo_warn "$f_invalid_total line(s) could not be parsed; see $f_report_dir/invalid/"
fi

g_echo_note "Traefik statistics reports and summaries written for ${#f_hosts[@]} host(s) to ${f_report_dir}"
exit 0
