#!/bin/bash

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Grade every configured Traefik HTTPS host against the Qualys SSL Labs API
(api.ssllabs.com/api/v3) with curl and jq. Writes the result to
<log>/ssl-labs.json for the ssl-labs runcheck. The scan is rate limited and
can take several minutes per host. No arguments.

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
f_no_args "$@"
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"

# SSL Labs API entry point and snapshot target
g_api_base="https://api.ssllabs.com/api/v3"
g_snapshot="${g_log_dir}/ssl-labs.json"
g_tmpdir="$(mktemp -d "${g_tmp}/ssl-labs.XXXXXX")"

# Perform one API call and retry only on transient rate-limit/server errors.
# Usage: f_ssl_labs_api <url> <output-file>
function f_ssl_labs_api {
  local f_url="$1" f_out="$2" f_code f_retry=0
  while :
  do
    f_code="$(curl -sS -m 30 -o "$f_out" -w '%{http_code}' "$f_url" 2>/dev/null || echo 000)"
    case "$f_code" in
      200)
        return 0
        ;;
      429|503|529)
        if [[ "$f_retry" -ge 3 ]]
        then
          return 1
        fi
        f_retry=$(( f_retry + 1 ))
        sleep $(( 30 * f_retry ))
        ;;
      *)
        return 1
        ;;
    esac
  done
}

# Write the snapshot atomically so the runcheck never reads a partial file.
# Usage: f_write_snapshot <status> <hosts-json> [error]
function f_write_snapshot {
  local f_status="$1" f_hosts="$2" f_error="${3:-}" f_tmp="${g_snapshot}.tmp.$$"
  mkdir -p "$(dirname "$g_snapshot")"
  if jq -n \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "$f_status" \
    --arg error "$f_error" \
    --argjson hosts "$f_hosts" \
    '{generated: $generated, status: $status, error: $error, hosts: $hosts}' >"$f_tmp"
  then
    mv "$f_tmp" "$g_snapshot"
  else
    g_echo_error "Could not write SSL Labs snapshot ${g_snapshot}"
    rm -f "$f_tmp"
  fi
}

# Fetch API limits once. A missing info response is recorded in the snapshot
# so the healthcheck can distinguish an API outage from a missed cron job.
g_info_file="${g_tmpdir}/info.json"
if ! f_ssl_labs_api "${g_api_base}/info" "$g_info_file"
then
  f_write_snapshot "error" '[]' "SSL Labs API unavailable"
  g_echo_error "Qualys SSL Labs API unavailable - snapshot written with error status"
  rm -rf "$g_tmpdir"
  exit 1
fi

g_cooloff_ms="$(jq -r '.newAssessmentCoolOff // 1000' "$g_info_file" 2>/dev/null)"
[[ "$g_cooloff_ms" =~ ^[0-9]+$ ]] || g_cooloff_ms=1000
g_cooloff_sec=$(( (g_cooloff_ms + 999) / 1000 ))
[[ "$g_cooloff_sec" -le 60 ]] || g_cooloff_sec=60

# Collect all Host(`...`) rules from compose files and Traefik providers.
f_symbios_traefik_hosts

g_host_entries=()
g_index=0
while read -r g_host
do
  [[ "$g_host" =~ ^[A-Za-z0-9.-]+$ ]] || continue
  [[ "$g_host" != .* && "$g_host" != *. ]] || continue

  # Skip names that are not resolvable locally or do not answer over HTTPS.
  host "$g_host" >/dev/null 2>&1 || continue
  curl -s -m 15 "https://${g_host}" >/dev/null 2>&1 || continue

  g_index=$(( g_index + 1 ))
  g_host_enc="$(jq -rn --arg h "$g_host" '$h | @uri')"
  g_analysis="${g_tmpdir}/analysis-${g_index}.json"
  g_url="${g_api_base}/analyze?host=${g_host_enc}&publish=off&fromCache=on&maxAge=24&all=done"
  g_status="api_error"
  g_api_error=""
  g_endpoints='[]'

  # Poll until READY/ERROR. fromCache with maxAge=24 reuses a fresh report
  # and only starts a new assessment when the cached one is older.
  for g_poll in $(seq 1 20)
  do
    if ! f_ssl_labs_api "$g_url" "$g_analysis"
    then
      break
    fi
    g_status="$(jq -r '.status // "ERROR"' "$g_analysis" 2>/dev/null)"
    if [[ "$g_status" == "READY" || "$g_status" == "ERROR" ]]
    then
      break
    fi
    sleep 20
  done

  if [[ -s "$g_analysis" ]]
  then
    g_api_error="$(jq -r '[.errors[]?.message] | join("; ")' "$g_analysis" 2>/dev/null)"
    [[ -n "$g_api_error" ]] || g_api_error="$(jq -r '.statusMessage // ""' "$g_analysis" 2>/dev/null)"
    g_endpoints="$(jq -c '[.endpoints[]? | {ip: (.ipAddress // "-"), grade: (.grade // "ungraded"), status: (.statusMessage // "")}]' "$g_analysis" 2>/dev/null)"
    [[ -n "$g_endpoints" ]] || g_endpoints='[]'
  fi
  [[ -n "$g_api_error" ]] || g_api_error="no result from SSL Labs API"

  jq -n \
    --arg host "$g_host" \
    --arg status "$g_status" \
    --arg error "$g_api_error" \
    --argjson endpoints "$g_endpoints" \
    '{host: $host, status: $status, error: $error, endpoints: $endpoints}' \
    >"${g_tmpdir}/host-${g_index}.json"
  g_host_entries+=("${g_tmpdir}/host-${g_index}.json")

  # Qualys allows only a small number of concurrent new assessments.
  sleep "$g_cooloff_sec"
done < <(cut -d '`' -f2 "$g_tmp/hosts" 2>/dev/null | sort -u)

if [[ "${#g_host_entries[@]}" -gt 0 ]]
then
  g_hosts_json="$(jq -s . "${g_host_entries[@]}")"
else
  g_hosts_json='[]'
fi
f_write_snapshot "ok" "$g_hosts_json" ""

g_echo_ok "Qualys SSL Labs snapshot written to ${g_snapshot} (${g_index} host(s))"
rm -rf "$g_tmpdir"
