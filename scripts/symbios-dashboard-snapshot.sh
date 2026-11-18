#!/bin/bash
# SymbiOS - Refresh the dashboard snapshot files (Host System stats + Network
# Devices + Top Processes) so the WebUI can render the dashboard without ever
# blocking on a live command via SSH. Deployed as a minutely cron job; the
# lockfile guards against overlap (e.g. a slow network scan taking longer than
# a minute).
#
# Writes:
#   <log>/dashboard-stats.json     -> output of symbios-system-stats.sh
#   <log>/dashboard-network.json   -> output of symbios-network-scan.sh
#   <log>/dashboard-top.json       -> output of symbios-top-procs.sh
#   <log>/dashboard-docker.json    -> output of symbios-docker-stats.sh
#   <log>/dashboard-history-YYYYMMDD.jsonl
#                                -> per-minute load/process/docker history line
#                                  (combined stats + top + docker, JSON Lines format);
#                                  files older than 7 days are pruned
#
# The WebUI reads these files ("/log" volume mount) and no longer invokes the
# underlying scripts on demand.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Refresh the dashboard snapshot files so the WebUI can render the dashboard
without ever blocking on a live command via SSH. Deployed as a minutely cron
job (/etc/cron.d/symbios-dashboard-snapshot); the lockfile guards against
overlap. No arguments.

Writes:
  <log>/dashboard-stats.json       host stats (symbios-system-stats.sh)
  <log>/dashboard-network.json     LAN scan (symbios-network-scan.sh)
  <log>/dashboard-top.json         top processes (symbios-top-procs.sh)
  <log>/dashboard-docker.json      docker stats (symbios-docker-stats.sh)
  <log>/dashboard-history-YYYYMMDD.jsonl   per-minute combined history
                                 (files older than 7 days are pruned)

Options:
  -h, --help          Show this help and exit
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
f_no_args "$@"
g_lockfile
g_nice

# Run a dashboard script and atomically refresh its snapshot file. A failed
# run keeps the previous snapshot and never leaves a half-written file behind.
f_refresh() {
  local f_target="$1" f_cmd="$2" f_tmp="${1}.tmp"
  if "${f_cmd}" > "${f_tmp}" 2>/dev/null
  then
    mv -f "${f_tmp}" "${f_target}"
  else
    rm -f "${f_tmp}"
  fi
}

# Read a snapshot as single-line JSON; a missing or corrupt file becomes {}.
function f_snapshot_json {
  local f_path="$1" f_json
  f_json="$(jq -c . "${f_path}" 2>/dev/null)"
  if [[ -z "${f_json}" ]]
  then
    printf '{}\n'
  else
    printf '%s\n' "${f_json}"
  fi
}

# Append a combined stats + top JSON line to today's history file. The line
# merges every field of dashboard-stats.json with the top process lists so a
# single reader (CLI or WebUI) yields the full minute snapshot.
f_append_history() {
  local f_out="${g_log_dir}/dashboard-history-$(date -u +%Y%m%d).jsonl"
  local f_stats f_top f_docker
  f_stats="$(f_snapshot_json "${g_log_dir}/dashboard-stats.json")"
  f_top="$(f_snapshot_json "${g_log_dir}/dashboard-top.json")"
  f_docker="$(f_snapshot_json "${g_log_dir}/dashboard-docker.json")"
  jq -c -n \
    --argjson stats "${f_stats}" \
    --argjson top "${f_top}" \
    --argjson docker "${f_docker}" \
    '($stats | if type == "object" then . else {} end) as $s
     | ($top | if type == "object" then . else {} end) as $t
     | ($docker | if type == "object" then . else {} end) as $d
     | $s + {
         top_cpu: ($t.cpu // []),
         top_mem: ($t.mem // []),
         top_io: ($t.io // []),
         # has() keeps an explicit false from becoming the default true.
         measuring_io: (if ($t | has("measuring_io")) then $t.measuring_io else true end),
         interval_sec: ($t.interval_sec // 0),
         docker: ($d.containers // [])
       }' >> "${f_out}"
}

# Prune history files older than one week.
f_prune_history() {
  find "$1" -maxdepth 1 -name 'dashboard-history-*.jsonl' -type f -mtime +7 -delete
}

f_refresh "${g_log_dir}/dashboard-stats.json"   "${g_symbios_dir}/symbios-system-stats.sh"
f_refresh "${g_log_dir}/dashboard-network.json" "${g_symbios_dir}/symbios-network-scan.sh"
f_refresh "${g_log_dir}/dashboard-top.json"     "${g_symbios_dir}/symbios-top-procs.sh"
f_refresh "${g_log_dir}/dashboard-docker.json"  "${g_symbios_dir}/symbios-docker-stats.sh"
f_append_history
f_prune_history "${g_log_dir}"

exit 0