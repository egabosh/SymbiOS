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

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
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

# Append a combined stats + top JSON line to today's history file. The line
# merges every field of dashboard-stats.json with the top process lists so a
# single reader (CLI or WebUI) yields the full minute snapshot.
f_append_history() {
  python3 - "${g_log_dir}/dashboard-stats.json" "${g_log_dir}/dashboard-top.json" \
    "${g_log_dir}/dashboard-docker.json" \
    "${g_log_dir}/dashboard-history-$(date -u +%Y%m%d).jsonl" <<'PYEOF'
import json
import os
import sys

stats_path, top_path, docker_path, out_path = sys.argv[1:5]
line = {}
if os.path.exists(stats_path):
    with open(stats_path) as fh:
        line = json.load(fh)
top = {}
if os.path.exists(top_path):
    try:
        with open(top_path) as fh:
            top = json.load(fh)
    except (ValueError, OSError):
        top = {}
line["top_cpu"] = top.get("cpu", [])
line["top_mem"] = top.get("mem", [])
line["top_io"] = top.get("io", [])
line["measuring_io"] = top.get("measuring_io", True)
line["interval_sec"] = top.get("interval_sec", 0)
docker = []
if os.path.exists(docker_path):
    try:
        with open(docker_path) as fh:
            docker = json.load(fh).get("containers", [])
    except (ValueError, OSError):
        pass
line["docker"] = docker
with open(out_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(line, ensure_ascii=False, separators=(",", ":")))
    fh.write("\n")
PYEOF
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