#!/bin/bash
# SymbiOS - Capture Docker container statistics into a machine-readable JSON
# snapshot (dashboard-docker.json). Called once per minute by
# symbios-dashboard-snapshot.sh (cron) so the WebUI never runs docker itself.
#
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

python3 - "${f_raw_tmp}" "${f_ts}" <<'PYEOF'
import json
import re
import sys

raw_path, ts = sys.argv[1:3]

_PREFIXES = {
    "": 1.0, "B": 1.0, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
    "KiB": 1024.0, "MiB": 1024.0 ** 2, "GiB": 1024.0 ** 3, "TiB": 1024.0 ** 4,
}


def _parse_size(text):
    """Normalize a docker human-readable size ('1.2GiB', '512kB') to MB."""
    m = re.match(r"^\s*([0-9.]+)\s*([A-Za-z]*)\s*$", text or "")
    if not m:
        return 0.0
    try:
        return float(m.group(1)) * _PREFIXES.get(m.group(2), 1.0) / (1024.0 ** 2)
    except ValueError:
        return 0.0


def _split_io(text):
    """Split a 'rxB / txB' pair into (rx_mb, tx_mb)."""
    parts = str(text or "").split("/")
    return _parse_size(parts[0]) if parts else 0.0, (_parse_size(parts[1]) if len(parts) > 1 else 0.0)


def _parse_pct(text):
    m = re.match(r"^\s*([0-9.]+)", text or "")
    if not m:
        return 0.0
    try:
        return float(m.group(1))
    except ValueError:
        return 0.0


def _parse_pids(text):
    m = re.match(r"\d+", str(text or ""))
    try:
        return int(m.group(0)) if m else 0
    except ValueError:
        return 0


containers = []
with open(raw_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except (ValueError, json.JSONDecodeError):
            continue
        name = str(obj.get("Name", "")).lstrip("/") or obj.get("Container", "")
        used, limit = _split_io(obj.get("MemUsage"))
        net_rx, net_tx = _split_io(obj.get("NetIO"))
        blk_r, blk_w = _split_io(obj.get("BlockIO"))
        containers.append({
            "name": name,
            "id": str(obj.get("ID", obj.get("Container", "")))[:12],
            "cpu_percent": round(_parse_pct(obj.get("CPUPerc")), 2),
            "mem_percent": round(_parse_pct(obj.get("MemPerc")), 2),
            "mem_used_mb": round(used, 1),
            "mem_limit_mb": round(limit, 1),
            "net_rx_mb": round(net_rx, 1),
            "net_tx_mb": round(net_tx, 1),
            "block_read_mb": round(blk_r, 1),
            "block_write_mb": round(blk_w, 1),
            "pids": _parse_pids(obj.get("PIDs")),
        })

containers.sort(key=lambda c: c["mem_percent"], reverse=True)
out = {"timestamp": ts, "containers": containers}
print(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
PYEOF

rm -f "${f_raw_tmp}" "${f_err_tmp}"
exit 0