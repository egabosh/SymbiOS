# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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


def _write_health_file(data):
    try:
        with open(HEALTH_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


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
    if not checks:
        return {"status": "warn", "message": "No checks found in runchecks data"}

    errors = [c for c in checks if c.get("status") == "error"]
    last_run = data.get("last_run", "unknown")

    results = []
    for c in checks:
        entry = {"name": c.get("name", "?"), "status": c.get("status", "unknown")}
        if c.get("message"):
            entry["message"] = c["message"]
        results.append(entry)

    if errors:
        msg = f"{len(errors)} of {len(checks)} checks failed"
        return {"status": "error", "message": msg, "last_run": last_run, "results": results}

    return {"status": "ok", "message": f"All {len(checks)} checks passed", "last_run": last_run, "results": results}


def run_all():
    data = {
        "runchecks": check_runchecks(),
    }
    _write_health_file(data)
    return data
