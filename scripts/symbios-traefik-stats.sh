#!/bin/bash
# SymbiOS - Build a static GoAccess report from the Traefik access log.
#
# The WebUI must not parse the live log itself, so this script is called by a
# cron job and writes a ready-to-serve HTML report plus a small status file
# below <log_dir>/traefik-stats/. Both the current log and the rotated logs are
# included. Lines are normalized with jq so old JSON records without the newly
# enabled User-Agent/Referer header fields stay parseable.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Build a static GoAccess HTML report from the current and rotated Traefik
access logs so the SymbiOS WebUI can show web statistics without parsing the
log on page load. No arguments.

Reads:
  <base_services_root>/traefik/log/access.log
  <base_services_root>/traefik/log/access.log.1
  <base_services_root>/traefik/log/access.log.*.gz

Writes:
  <log_dir>/traefik-stats/report.html       static GoAccess report
  <log_dir>/traefik-stats/status.json       generation time and parse status
  <log_dir>/traefik-stats/invalid-requests.log  lines GoAccess could not parse

Options:
  -h, --help          Show this help and exit

Exit codes:
  0                   Report generated
  1                   Technical error (missing tool or no access log)
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

# Required tools. jq is used to normalize the JSON records into the exact
# field order expected by the GoAccess format string below.
for f_tool in goaccess jq zcat
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

f_report_dir="${g_log_dir}/traefik-stats"
f_report="${f_report_dir}/report.html"
# GoAccess insists on a .html/.json/.csv output extension, so the temporary
# file also ends in .html before it is moved into place.
f_report_tmp="${f_report_dir}/report.tmp.html"
f_status_tmp="${f_report_dir}/status.json.tmp"
f_invalid="${f_report_dir}/invalid-requests.log"
mkdir -p "$f_report_dir" || exit 1
: >"$f_invalid" || exit 1

# Old records have no header fields; add empty placeholders so one format
# string parses the whole rotation. The key order here must match f_log_format.
# Query strings are stripped here as well: the Debian build uses a 4 KiB line
# buffer and Nextcloud uploads produce URLs far larger than that.
f_jq_filter='{ClientHost: (.ClientHost // "-"), ClientUsername: (.ClientUsername // "-"), DownstreamContentSize: (.DownstreamContentSize // 0), DownstreamStatus: (.DownstreamStatus // 0), Duration: (.Duration // 0), RequestHost: (.RequestHost // "-"), RequestMethod: (.RequestMethod // "-"), RequestPath: ((.RequestPath // "-") | split("?")[0] | .[0:2048]), RequestProtocol: (.RequestProtocol // "-"), request_Referer: (.["request_Referer"] // "-"), "request_User-Agent": (.["request_User-Agent"] // "-"), time: (.time // "")}'

# GoAccess matches JSON logs by literal field order. --no-global-config keeps
# the panel set deterministic regardless of /etc/goaccess/goaccess.conf.
f_log_format='{"ClientHost":"%h","ClientUsername":"%e","DownstreamContentSize":"%b","DownstreamStatus":"%s","Duration":"%n","RequestHost":"%v","RequestMethod":"%m","RequestPath":"%U","RequestProtocol":"%H","request_Referer":"%R","request_User-Agent":"%u","time":"%dT%t"}'

f_log_size="$(du -cb "${f_inputs[@]}" | tail -n 1 | cut -f1)"
if zcat -f "${f_inputs[@]}" \
  | jq -c "$f_jq_filter" \
  | goaccess - \
      --no-global-config \
      --log-format="$f_log_format" \
      --date-format='%Y-%m-%d' \
      --time-format='%T%z' \
      --log-size="$f_log_size" \
      --no-query-string \
      --no-strict-status \
      --no-progress \
      --invalid-requests="$f_invalid" \
      -o "$f_report_tmp"
then
  mv -f "$f_report_tmp" "$f_report" || exit 1
else
  rm -f "$f_report_tmp"
  g_echo_error "GoAccess failed to parse the Traefik access log"
  exit 1
fi

# Status metadata lets the WebUI show the report age without reading the HTML.
f_invalid_lines="$(wc -l <"$f_invalid")"
if jq -n \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson invalid "$f_invalid_lines" \
  --argjson files "${#f_inputs[@]}" \
  '{generated_at: $generated, invalid_requests: $invalid, input_files: $files}' >"$f_status_tmp"
then
  mv -f "$f_status_tmp" "${f_report_dir}/status.json" || exit 1
else
  rm -f "$f_status_tmp"
fi

if (( f_invalid_lines > 0 ))
then
  g_echo_warn "$f_invalid_lines log lines could not be parsed; see $f_invalid"
fi

g_echo_note "Traefik statistics report written to $f_report"
exit 0
