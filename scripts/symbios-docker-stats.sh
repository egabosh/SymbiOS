#!/bin/bash
# SymbiOS - Capture Docker container statistics into a machine-readable JSON
# snapshot (dashboard-docker.json). Called once per minute by
# symbios-dashboard-snapshot.sh (cron) so the WebUI never runs docker itself.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [timeout]

Capture Docker container statistics into a machine-readable JSON snapshot
(dashboard-docker.json) for the WebUI Health page. Called once per minute by
symbios-dashboard-snapshot.sh (cron).

Arguments:
  timeout     seconds before the 'docker stats' call is aborted (default: 30)

Output: one JSON document on stdout with the timestamp and a 'containers'
array (name, id, cpu_percent, mem_percent, mem_used_mb, mem_limit_mb,
net_rx_mb, net_tx_mb, block_read_mb, block_write_mb, pids), sorted by memory
percentage descending.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Output: one JSON document on stdout:
# {
#   "timestamp": "...",
#   "error": "..."            (optional; docker daemon / permission failures)
#   "containers": [{
#     "name": "...", "id": "...", "cpu_percent": <float>,
#     "mem_percent": <float>, "mem_used_mb": <float>, "mem_limit_mb": <float>,
#     "net_rx_mb": <float>, "net_tx_mb": <float>,
#     "block_read_mb": <float>, "block_write_mb": <float>, "pids": <int>
#   }, ...]
# }
#
# Containers are sorted by memory percentage descending, so the most relevant
# entries lead the list. Human-readable units from `docker stats` (e.g.
# "1.245GiB", "0.50%") are normalized to floats here, once per minute.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile

f_docker_timeout="${1:-30}"
f_raw_tmp="/tmp/symbios-docker-stats.raw.$$"
f_err_tmp="/tmp/symbios-docker-stats.err.$$"
f_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Fail fast with a clear message when the docker CLI is missing.
if ! command -v docker > /dev/null 2>&1
then
  printf '{"timestamp":"%s","containers":[],"error":"docker CLI not found"}\n' "${f_ts}"
  exit 0
fi

# One JSON object per container via the Go template; stderr (daemon down,
# permission) is captured so a failed run reports a useful `error` field.
timeout "${f_docker_timeout}" docker stats --no-stream \
  --format '{{json .}}' > "${f_raw_tmp}" 2> "${f_err_tmp}"

if [[ ! -s "${f_raw_tmp}" ]]
then
  f_err="$(head -c 300 "${f_err_tmp}" 2>/dev/null)"
  [[ -n "${f_err}" ]] || f_err="docker stats produced no output (daemon not running?)"
  f_err="${f_err//[$'\t\n\r']/ }"
  printf '{"timestamp":"%s","containers":[],"error":%s}\n' \
    "${f_ts}" "$(printf '%s' "${f_err}" | f_json_escape)"
  rm -f "${f_raw_tmp}" "${f_err_tmp}"
  exit 0
fi

# Normalize the human-readable docker units. jq rounds half away from zero
# where Python used banker's rounding - immaterial for dashboard figures.
jq -R -s -c --arg ts "${f_ts}" '
  def pct:
    ((capture("^\\s*(?<n>[0-9.]+)") // {n: "0"}).n | tonumber? // 0);
  def size:
    (capture("^\\s*(?<n>[0-9.]+)\\s*(?<u>[A-Za-z]*)\\s*$") // {n: "0", u: ""}) as $m
    | (($m.n | tonumber? // 0)
       * ({"": 1, "B": 1, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
           "KiB": 1024, "MiB": 1048576, "GiB": 1073741824,
           "TiB": 1099511627776}[$m.u] // 1)) / 1048576;
  def io:
    split("/") | [ (.[0] // "" | size), (.[1] // "" | size) ];
  def r1: ((. * 10) | round) / 10;
  def r2: ((. * 100) | round) / 100;
  def pids:
    ((capture("^(?<n>[0-9]+)") // {n: "0"}).n | tonumber? // 0);

  [ split("\n")[]
    | select(length > 0)
    | fromjson?
    | . as $o
    | ($o.MemUsage // "" | io) as $mem
    | ($o.NetIO // "" | io) as $net
    | ($o.BlockIO // "" | io) as $blk
    | (($o.Name // "" | tostring) | sub("^/+"; "")) as $name
    | (if $name == "" then ($o.Container // "" | tostring) else $name end)
    | { name: .,
        id: (($o.ID // $o.Container // "") | tostring | .[0:12]),
        cpu_percent: ($o.CPUPerc // "" | pct | r2),
        mem_percent: ($o.MemPerc // "" | pct | r2),
        mem_used_mb: ($mem[0] | r1),
        mem_limit_mb: ($mem[1] | r1),
        net_rx_mb: ($net[0] | r1),
        net_tx_mb: ($net[1] | r1),
        block_read_mb: ($blk[0] | r1),
        block_write_mb: ($blk[1] | r1),
        pids: ($o.PIDs // "" | pids) }
  ] | sort_by(-.mem_percent)
    | {timestamp: $ts, containers: .}
' "${f_raw_tmp}"

rm -f "${f_raw_tmp}" "${f_err_tmp}"
exit 0