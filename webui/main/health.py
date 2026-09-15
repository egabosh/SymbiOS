# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

import json

HEALTH_FILE = "/log/system-health.json"
RUNCHECKS_FILE = "/log/runchecks-results.json"
TOP_FILE = "/log/dashboard-top.json"
HISTORY_GLOB = "/log/dashboard-history-*.jsonl"
DOCKER_FILE = "/log/dashboard-docker.json"


def _write_health_file(data):
    try:
        with open(HEALTH_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


STATS_FILE = "/log/dashboard-stats.json"


def check_current_stats():
    """Read the latest dashboard-stats.json snapshot (live load/CPU/mem).

    Produced by symbios-dashboard-snapshot.sh every minute. Used to show the
    current one-minute load average next to the 24h trend sparkline.
    Returns a dict with 'load1', 'load5', 'load15', 'cpu_percent',
    'mem_percent' (all possibly empty) plus an 'updated' timestamp.
    """
    try:
        with open(STATS_FILE) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        return {}
    return {
        "updated": data.get("timestamp", ""),
        "load1": data.get("load1", ""),
        "load5": data.get("load5", ""),
        "load15": data.get("load15", ""),
        "cpu_percent": data.get("cpu_percent", ""),
        "mem_percent": data.get("mem_percent", ""),
    }


def check_top_procs():
    """Read the current top process snapshot produced by symbios-top-procs.sh.

    Returns a dict with 'cpu' / 'mem' / 'io' lists, 'interval_sec',
    'measuring_io', 'updated' and 'status'. Returns status 'warn' when the
    snapshot file is missing (cron not yet run / not installed).
    """
    try:
        with open(TOP_FILE) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"status": "warn", "message": "No top process data yet (snapshot cron not run or not installed)"}
    except (json.JSONDecodeError, ValueError) as e:
        return {"status": "warn", "message": f"Invalid top process data: {e}"}

    out = {
        "status": "ok",
        "updated": data.get("timestamp", "unknown"),
        "interval_sec": data.get("interval_sec", 0),
        "measuring_io": bool(data.get("measuring_io", True)),
        "cpu": data.get("cpu", []),
        "mem": data.get("mem", []),
        "io": data.get("io", []),
    }
    return out


def history_trend(hours=24, bucket_minutes=5, max_buckets=288):
    """Aggregate the JSONL history files into a downsample trend series.

    Reads all dashboard-history-*.jsonl files and returns one point per time
    bucket over the last `hours`. Values are averaged per bucket:
      {"ts": "HH:MM", "cpu": float, "mem": float, "load": float}
    Used by the Health page mini sparklines.
    """
    import glob
    import time
    from datetime import datetime, timedelta, timezone

    try:
        files = sorted(glob.glob(HISTORY_GLOB))
    except ValueError:
        files = []

    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=hours)
    bucket_s = 60 * bucket_minutes

    buckets = {}
    for path in files:
        try:
            with open(path) as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        rec = json.loads(raw)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    ts = rec.get("timestamp", "")
                    try:
                        t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except (ValueError, TypeError):
                        continue
                    if t < cutoff:
                        continue
                    key = int(t.timestamp() // bucket_s) * bucket_s
                    b = buckets.setdefault(key, {"cpu": [], "mem": [], "load": []})
                    b["cpu"].append(float(rec.get("cpu_percent", 0) or 0))
                    b["mem"].append(float(rec.get("mem_percent", 0) or 0))
                    b["load"].append(float(rec.get("load1", 0) or 0))
        except OSError:
            continue

    series = []
    for key in sorted(buckets):
        b = buckets[key]
        if not b["cpu"]:
            continue
        t = datetime.fromtimestamp(key, tz=timezone.utc).astimezone()
        series.append({
            "ts": t.strftime("%H:%M"),
            "cpu": round(sum(b["cpu"]) / len(b["cpu"]), 1),
            "mem": round(sum(b["mem"]) / len(b["mem"]), 1),
            "load": round(sum(b["load"]) / len(b["load"]), 2),
        })
        if len(series) >= max_buckets:
            break
    return series


def check_docker_stats():
    """Read the docker stats snapshot produced by symbios-docker-stats.sh.

    Runs via the minutely snapshot cron; this loader never invokes docker.
    Returns the container list (sorted by memory descending from the file),
    'updated' and 'status'. 'warn' when the snapshot is missing or docker
    reported an error (containers empty + 'error' comment).
    """
    try:
        with open(DOCKER_FILE) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"status": "warn", "message": "No docker stats yet (snapshot cron not run or not installed)"}
    except (json.JSONDecodeError, ValueError) as e:
        return {"status": "warn", "message": f"Invalid docker stats: {e}"}

    containers = data.get("containers", [])
    if data.get("error"):
        return {
            "status": "warn",
            "message": data["error"],
            "updated": data.get("timestamp", "unknown"),
            "containers": containers,
        }
    return {
        "status": "ok",
        "updated": data.get("timestamp", "unknown"),
        "containers": containers,
    }


def check_runchecks():
    """Read the runchecks daemon JSON output and return the latest results."""
    try:
        with open(RUNCHECKS_FILE) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"status": "warn", "message": "No runchecks data yet (daemon not started or no run completed)"}
    except (json.JSONDecodeError, ValueError) as e:
        return {"status": "warn", "message": f"Invalid runchecks data: {e}"}

    checks = data.get("checks", [])
    categories = data.get("categories", [])
    if not checks:
        return {"status": "warn", "message": "No checks found in runchecks data"}

    errors = [c for c in checks if c.get("status") == "error"]
    last_run = data.get("last_run", "unknown")

    results = []
    for c in checks:
        entry = {"name": c.get("name", "?"), "status": c.get("status", "unknown")}
        if c.get("message"):
            entry["message"] = c["message"]
        if c.get("title"):
            entry["title"] = c["title"]
        if c.get("desc"):
            entry["desc"] = c["desc"]
        if c.get("detail"):
            entry["detail"] = c["detail"]
        if c.get("category"):
            entry["category"] = c["category"]
        if c.get("script"):
            entry["script"] = c["script"]
        results.append(entry)

    if errors:
        msg = f"{len(errors)} of {len(checks)} checks failed"
        return {"status": "error", "message": msg, "last_run": last_run, "categories": categories, "results": results}

    return {"status": "ok", "message": f"All {len(checks)} checks passed", "last_run": last_run, "categories": categories, "results": results}


def run_all():
    data = {
        "runchecks": check_runchecks(),
        "top_procs": check_top_procs(),
        "history_trend": history_trend(),
        "current_stats": check_current_stats(),
        "docker_stats": check_docker_stats(),
    }
    _write_health_file(data)
    return data
