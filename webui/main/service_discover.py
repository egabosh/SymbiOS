#!/usr/bin/env python3
"""SymbiOS Service Discovery - scans /home/SymbiOS/services/*.yml"""
import json
import subprocess
from pathlib import Path

SERVICES_DIR = Path("/home/SymbiOS/services")
DOCKER_BASE = Path("/home/docker")

def discover_services():
    services = []
    if not SERVICES_DIR.exists():
        return services
    for pf in sorted(SERVICES_DIR.glob("*.yml")):
        sname = pf.stem
        sdirs = []
        for d in DOCKER_BASE.iterdir():
            if d.is_dir() and (d.name == sname or d.name.startswith(sname + ".")) and (d / "docker-compose.yml").exists():
                sdirs.append({"path": str(d), "name": d.name})
        # Get status for installed services
        status_result = get_service_status(sname)
        services.append({
            "name": sname,
            "playbook": str(pf),
            "service_dirs": sdirs,
            "installed": len(sdirs) > 0,
            "running": status_result.get("running", False),
            "containers": status_result.get("containers", [])
        })
    return services

def get_service_status(sname, hostname=""):
    status = {"service_name": sname, "hostname": hostname, "running": False, "containers": []}
    for d in DOCKER_BASE.iterdir():
        if d.is_dir() and (d.name == sname or d.name.startswith(sname + ".")) and (d / "docker-compose.yml").exists():
            try:
                r = subprocess.run(
                    f"cd {d} && docker compose ps --format json".split(),
                    capture_output=True, text=True, timeout=10
                )
                if r.stdout:
                    cs = json.loads(r.stdout)
                    status["containers"] = [
                        {"name": c.get("Name",""), "state": c.get("State","unknown"), "status": c.get("Status","")}
                        for c in cs
                    ]
                    status["running"] = any(c["state"] == "running" for c in status["containers"])
                    status["hostname"] = d.name.split(".", 1)[1] if "." in d.name else ""
                    status["path"] = str(d)
                    break
            except:
                pass
    return status

def run_playbook(sname):
    pf = SERVICES_DIR / f"{sname}.yml"
    if not pf.exists():
        return {"error": f"Playbook not found: {pf}", "rc": 1}
    cmd = [
        "ansible-playbook", "--connection=local",
        "--inventory", "localhost,", "--limit", "localhost",
        "-e", "ansible_python_interpreter=/usr/bin/python3",
        str(pf)
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    out = r.stdout[-5000:] if len(r.stdout) > 5000 else r.stdout
    err = r.stderr[-2000:] if len(r.stderr) > 2000 else r.stderr
    return {"stdout": out, "stderr": err, "rc": r.returncode, "success": r.returncode == 0}

def docker_action(sdir, action="up"):
    cmd = f"cd {sdir} && docker compose {action}"
    try:
        r = subprocess.run(cmd.split(), capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        return {
            "output": out[-3000:] if len(out) > 3000 else out,
            "rc": r.returncode,
            "success": r.returncode == 0
        }
    except Exception as e:
        return {"error": str(e), "rc": 1, "success": False}
