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
# expected by the GoAccess format string below.
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
# second GoAccess run. Keep the filter in a file so its structure stays readable.
cat >"$f_staging/summary.jq" <<'SUMMARY_JQ'
def static_path:
  test("\\.(css|js|mjs|json|xml|txt|map|jpg|jpeg|png|gif|svg|webp|ico|woff2?|ttf|eot|pdf|zip|gz|mp[34]|webm|ogg|wav|flac)$"; "i");

def browser_group:
  if test("googlebot"; "i") then "Googlebot"
  elif test("bingbot"; "i") then "Bingbot"
  elif test("bot|crawler|spider|slurp|bingpreview|facebookexternalhit"; "i") then "Other bots"
  elif test("curl"; "i") then "curl"
  elif test("wget"; "i") then "Wget"
  elif test("python|httpie|postman|go-http-client"; "i") then "Other clients"
  elif test("edg/|edgios|edga"; "i") then "Edge"
  elif test("firefox|fxios"; "i") then "Firefox"
  elif test("chrome|crios"; "i") then "Chrome"
  elif test("safari"; "i") then "Safari"
  else "Other" end;

def os_group:
  if test("windows"; "i") then "Windows"
  elif test("android"; "i") then "Android"
  elif test("iphone|ipad|ipod|cpu os"; "i") then "iOS"
  elif test("mac os x|macintosh"; "i") then "macOS"
  elif test("linux"; "i") then "Linux"
  else "Other" end;

def ref_host:
  if . == "-" or . == "" then empty
  elif test("://") then (split("://")[1] | split("/")[0] | split(":")[0])
  else (split("/")[0] | split(":")[0]) end;

# GoAccess counts a visitor once per IP, day and user agent, but excludes 4xx
# responses unless --4xx-to-unique-count is set. Mirror that here so the
# summary and the detailed report show the same number.
def unique_visitors:
  map(select(.DownstreamStatus < 400 or .DownstreamStatus >= 500)
      | [.ClientHost, .time[0:10], .["request_User-Agent"]])
  | unique | length;

def top_group($key; $limit):
  group_by(.[$key])
  | map({
      value: (.[0][$key] // "-"),
      requests: length,
      visitors: unique_visitors,
      bytes: (map(.DownstreamContentSize) | add // 0)
    })
  | sort_by(-.requests, .value)
  | .[:$limit];

. as $records
| ($records | length) as $total
| def pct($n): if $total == 0 then 0 else ((($n * 1000 / $total) | round) / 10) end;
{
  host: $host,
  generated_at: $generated,
  period: {
    from: ($records | map(.time) | min // ""),
    to: ($records | map(.time) | max // "")
  },
  totals: {
    requests: $total,
    visitors: ($records | unique_visitors),
    bytes: ($records | map(.DownstreamContentSize) | add // 0),
    not_found: ($records | map(select(.DownstreamStatus == 404)) | length),
    unique_files: ($records | map(.RequestPath) | unique | length),
    unique_referrers: ($records | map(.request_Referer | select(. != "-" and . != "")) | unique | length)
  },
  daily: (
    $records
    | map({date: .time[0:10], ip: .ClientHost, ua: .["request_User-Agent"],
           bytes: .DownstreamContentSize,
           counted: (.DownstreamStatus < 400 or .DownstreamStatus >= 500)})
    | group_by(.date)
    | map({
        date: .[0].date,
        requests: length,
        visitors: (map(select(.counted) | [.ip, .ua]) | unique | length),
        bytes: (map(.bytes) | add // 0)
      })
    | sort_by(.date)
  ),
  hourly: (
    $records
    | group_by(.time[11:13])
    | map({hour: .[0].time[11:13], requests: length})
    | sort_by(.hour)
  ),
  status_codes: (
    $records
    | group_by(.DownstreamStatus)
    | map({status: (.[0].DownstreamStatus // 0), requests: length, percent: pct(length)})
    | sort_by(-.requests, .status)
  ),
  pages: (
    $records
    | map(select((.RequestPath | static_path) | not))
    | top_group("RequestPath"; 15)
  ),
  assets: (
    $records
    | map(select(.RequestPath | static_path))
    | top_group("RequestPath"; 10)
  ),
  not_found_paths: (
    $records
    | map(select(.DownstreamStatus == 404))
    | top_group("RequestPath"; 10)
  ),
  referring_sites: (
    $records
    | map({site: (.request_Referer | ref_host), ClientHost: .ClientHost, time: .time, "request_User-Agent": .["request_User-Agent"], DownstreamContentSize: .DownstreamContentSize})
    | map(select(.site != null))
    | top_group("site"; 10)
  ),
  clients: (
    $records
    | top_group("ClientHost"; 10)
  ),
  browsers: (
    $records
    | map(. + {browser: (.["request_User-Agent"] | browser_group)})
    | top_group("browser"; 10)
  ),
  operating_systems: (
    $records
    | map(. + {os: (.["request_User-Agent"] | os_group)})
    | top_group("os"; 10)
  )
}
SUMMARY_JQ

# Normalize once, then filter the same records for every host report. The
# normalized field order is fixed, so a literal grep is enough and much faster
# than running jq over the whole file once per host.
f_normalized="$f_staging/normalized.json"
f_log_size="$(du -cb "${f_inputs[@]}" | tail -n 1 | cut -f1)"
if ! zcat -f "${f_inputs[@]}" | jq -c "$f_jq_filter" >"$f_normalized"
then
  rm -rf "$f_staging"
  g_echo_error "Failed to normalize the Traefik access log"
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

  # A host with no requests is valid; grep returns 1 for an empty result.
  grep -F "\"RequestHost\":\"$f_host\"" "$f_normalized" >"$f_host_log" || true
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
  if ! jq -s -f "$f_staging/summary.jq" \
    --arg host "$f_host" \
    --arg generated "$f_generated_at" \
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
