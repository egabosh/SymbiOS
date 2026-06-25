import subprocess
import os
import json
import glob
from datetime import datetime, timezone

DOCKER_LOG_DIR = "/docker/containers"
CONTAINER_INDEX = "/log/docker-containers.tsv"
SERVICE_STATUS_FILE = "/log/symbios-services.tsv"
HEALTH_FILE = "/log/system-health.json"
LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")
STEPCA_HOST = "acme-pki-stepca"
STEPCA_PORT = 9000
TRAEFIK_HOST = "traefik"

CHECK_HOSTS = [
    ("symbios.symbios-dev.dedyn.io", TRAEFIK_HOST, 443),
    ("auth.symbios-dev.dedyn.io", TRAEFIK_HOST, 443),
    ("ldap.symbios-dev.dedyn.io", TRAEFIK_HOST, 443),
    ("traefik.symbios-dev.dedyn.io", TRAEFIK_HOST, 443),
]


def _write_health_file(data):
    try:
        with open(HEALTH_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def _run(cmd, timeout=10):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return "", "timeout", 1
    except Exception as e:
        return "", str(e), 1


def _get_ldap_vars():
    try:
        import yaml
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        vars_ = config.get("all", {}).get("vars", {})
        base_dn = vars_.get("ldap_basedn", "dc=openldap,dc=local")
        admin_pw = vars_.get("ldap_admin_password", "changeme")
    except Exception:
        base_dn = "dc=openldap,dc=local"
        admin_pw = "changeme"
    try:
        with open("/config/.ldap_admin_pw") as f:
            pw = f.read().strip()
            if pw:
                admin_pw = pw
    except Exception:
        pass
    return base_dn, admin_pw


def check_ldap():
    base_dn, admin_pw = _get_ldap_vars()
    stdout, stderr, rc = _run([
        "ldapwhoami", "-x", "-H", LDAP_URI,
        "-D", f"cn=head-of-ldap,{base_dn}", "-w", admin_pw,
    ])
    if rc == 0:
        return {"status": "ok", "message": "Bind successful"}
    return {"status": "error", "message": stderr.strip() or f"exit code {rc}"}


def check_authelia():
    stdout, stderr, rc = _run([
        "curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}",
        "http://authelia-authelia.local-1:9091/api/health",
    ], timeout=5)
    if rc == 0:
        code = stdout.strip()
        if code == "200":
            return {"status": "ok", "message": "Healthy"}
        return {"status": "warn", "message": f"Unexpected HTTP {code}"}

    container_info = _get_container_state("authelia-authelia.local-1")
    if container_info:
        return {"status": "error", "message": f"{container_info}"}

    smtp_server, smtp_port = _get_smtp_config()
    hint = ""
    if smtp_server:
        hint = f"; check SMTP ({smtp_server}:{smtp_port})"
    return {"status": "error", "message": f"Unreachable{hint}"}


def check_traefik():
    stdout, stderr, rc = _run([
        "curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}",
        f"http://{TRAEFIK_HOST}/",
    ], timeout=5)
    if rc == 0:
        code = stdout.strip()
        if code in ("401", "200", "301", "302", "307", "308"):
            return {"status": "ok", "message": f"Responds HTTP {code}"}
        return {"status": "warn", "message": f"Unexpected HTTP {code}"}
    return {"status": "error", "message": stderr.strip() or f"exit code {rc}"}


def check_stepca():
    stdout, stderr, rc = _run([
        "curl", "-sfk",
        f"https://{STEPCA_HOST}:{STEPCA_PORT}/acme/acme/directory",
    ], timeout=5)
    if rc == 0:
        return {"status": "ok", "message": "ACME directory reachable"}
    return {"status": "error", "message": stderr.strip() or f"exit code {rc}"}


def check_config_daemon():
    try:
        with open(SERVICE_STATUS_FILE) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2 and parts[0] == "symbios-configd":
                    if parts[1] == "active":
                        return {"status": "ok", "message": "active"}
                    return {"status": "warn", "message": parts[1]}
        return {"status": "warn", "message": "Not found in status file"}
    except FileNotFoundError:
        return {"status": "warn", "message": "Status file not available"}


def check_playbooks():
    log_dir = "/log"
    failures = []
    for f in glob.glob(os.path.join(log_dir, "playbook-*.log")):
        name = os.path.basename(f).replace("playbook-", "").replace(".log", "")
        with open(f) as fh:
            content = fh.read()
        sections = content.split("PLAY RECAP")
        last = sections[-1] if sections else ""
        if "failed=1" in last or "FAILED" in last:
            failures.append(name)
    if failures:
        return {"status": "warn", "message": "Failed: " + ", ".join(failures)}
    return {"status": "ok", "message": "All playbooks passed"}


def check_containers():
    expected = {
        "traefik": "Traefik (Reverse Proxy)",
        "symbios-ui-symbios-webui-1": "WebUI",
        "ldap-openldap-1": "OpenLDAP",
        "ldap-ldap.ldap.symbios-dev.dedyn.io-1": "LDAP Domain",
        "acme-pki-stepca": "Step-CA (ACME-PKI)",
    }
    running = set()
    try:
        with open(CONTAINER_INDEX) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    running.add(parts[1])
    except FileNotFoundError:
        return {"status": "warn", "message": "Container index not available"}

    containers = {}
    for name, label in expected.items():
        if name in running:
            containers[label] = "ok"
        else:
            containers[label] = "warn"

    missing = [name for name in expected if name not in running]
    if not missing:
        return {"status": "ok", "message": f"{len(running)} containers running", "containers": containers}
    return {"status": "warn", "message": f"Missing: {', '.join(missing)}", "containers": containers}


def check_disk():
    paths = {"/": "System", "/config": "Config"}
    results = []
    for path in paths:
        try:
            stat = os.statvfs(path)
            total = stat.f_frsize * stat.f_blocks
            free = stat.f_frsize * stat.f_bfree
            used = total - free
            pct = round(used / total * 100) if total else 0
            results.append({"path": path, "total": _fmt_bytes(total), "used": _fmt_bytes(used), "pct": pct})
        except Exception:
            results.append({"path": path, "total": "?", "used": "?", "pct": 0})

    pcts = [r["pct"] for r in results if r["pct"]]
    max_pct = max(pcts) if pcts else 0
    status = "error" if max_pct > 90 else "warn" if max_pct > 75 else "ok"
    msg = "; ".join(f"{r['path']}: {r['pct']}%" for r in results)
    disk_data = results[0] if results else {}
    return {"status": status, "message": msg, "disk": disk_data}


def _fmt_bytes(num):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if num < 1024:
            return f"{num:.1f} {unit}"
        num /= 1024
    return f"{num:.1f} PB"


def _get_container_state(name):
    stdout, stderr, rc = _run([
        "docker", "ps", "--filter", f"name={name}", "--format", "{{.Status}}",
    ], timeout=5)
    if rc == 0 and stdout.strip():
        return stdout.strip()
    stdout, stderr, rc = _run([
        "docker", "ps", "-a", "--filter", f"name={name}", "--format", "{{.Status}}",
    ], timeout=5)
    if rc == 0 and stdout.strip():
        return stdout.strip()
    return None


def _get_smtp_config():
    try:
        import yaml
        with open("/config/inventory.yml") as f:
            cfg = yaml.safe_load(f) or {}
        vars_ = cfg.get("all", {}).get("vars", {})
        return vars_.get("smtp_server", ""), vars_.get("smtp_port", "")
    except Exception:
        return "", ""


def check_cert(sni_hostname, connect_host, port):
    stdout, stderr, rc = _run([
        "openssl", "s_client", "-connect", f"{connect_host}:{port}",
        "-servername", sni_hostname, "-showcerts",
    ], timeout=10)
    if rc != 0:
        msg = stderr.strip() or "Connection failed"
        if "Temporary failure in name resolution" in msg or "Name or service not known" in msg:
            return {"status": "warn", "message": f"{sni_hostname}: Unreachable (DNS)"}
        return {"status": "warn", "message": f"{sni_hostname}: {msg}"}
    for line in stdout.split("\n"):
        if "NotAfter:" in line:
            date_str = line.split("NotAfter:")[1].strip()
            return _eval_cert_date(date_str, sni_hostname)
    return {"status": "warn", "message": f"{sni_hostname}: Could not parse cert expiry"}


def _eval_cert_date(date_str, label):
    date_str = date_str.strip().rstrip(";")
    try:
        not_after = datetime.strptime(date_str, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        try:
            not_after = datetime.strptime(date_str, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=timezone.utc)
        except ValueError:
            return {"status": "warn", "message": f"{label}: Unparseable date: {date_str}"}
    now = datetime.now(timezone.utc)
    remaining = (not_after - now).days
    if remaining < 0:
        return {"status": "error", "message": f"{label}: EXPIRED on {not_after.date()}"}
    if remaining < 7:
        return {"status": "warn", "message": f"{label}: Expires in {remaining}d ({not_after.date()})"}
    return {"status": "ok", "message": f"{label}: {remaining}d ({not_after.date()})"}


def check_certs():
    results = [check_cert(sni, host, port) for sni, host, port in CHECK_HOSTS]
    errors = [r for r in results if r["status"] == "error"]
    warns = [r for r in results if r["status"] == "warn"]
    msg = "; ".join(r["message"] for r in results)
    if errors:
        return {"status": "error", "message": msg, "certs": results}
    if warns:
        return {"status": "warn", "message": msg, "certs": results}
    return {"status": "ok", "message": msg, "certs": results}


def check_root_ca():
    stdout, stderr, rc = _run([
        "openssl", "s_client", "-connect",
        f"{STEPCA_HOST}:{STEPCA_PORT}",
        "-servername", STEPCA_HOST, "-showcerts",
    ], timeout=10)
    if rc != 0:
        return {"status": "error", "message": f"Step-CA unreachable: {stderr.strip()}"}
    last_date = None
    for line in stdout.split("\n"):
        if "NotAfter:" in line:
            last_date = line.split("NotAfter:")[1].strip()
    if last_date:
        return _eval_cert_date(last_date, f"{STEPCA_HOST} Root-CA")
    return {"status": "warn", "message": "Could not parse Root-CA cert expiry"}


def check_ddns():
    try:
        import yaml
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        vars_ = config.get("all", {}).get("vars", {})
        ddns_host = vars_.get("ddns_host", "")
        ddns_apikey = vars_.get("ddns_apikey", "")
    except Exception:
        return {"status": "warn", "message": "Cannot read config"}

    if not ddns_host:
        return {"status": "warn", "message": "DDNS not configured"}

    if not ddns_host.endswith(".dedyn.io"):
        ddns_host = ddns_host + ".dedyn.io"

    if ddns_apikey:
        try:
            import urllib.request, urllib.error
            req = urllib.request.Request(
                f"https://desec.io/api/v1/domains/{ddns_host}/",
                headers={"Authorization": f"Token {ddns_apikey}"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status == 200:
                    return {"status": "ok", "message": f"{ddns_host} active on deSEC"}
                return {"status": "warn", "message": f"{ddns_host}: unexpected HTTP {resp.status}"}
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return {"status": "warn", "message": f"{ddns_host} not found on deSEC"}
            if e.code == 401:
                return {"status": "error", "message": "Invalid deSEC API key"}
            return {"status": "warn", "message": f"deSEC API error HTTP {e.code}"}
        except Exception as e:
            return {"status": "warn", "message": f"deSEC API error: {e}"}
    else:
        return {"status": "warn", "message": "DDNS configured, no API key"}


def run_all():
    data = {
        "ldap": check_ldap(),
        "authelia": check_authelia(),
        "traefik": check_traefik(),
        "stepca": check_stepca(),
        "config_daemon": check_config_daemon(),
        "playbooks": check_playbooks(),
        "ddns": check_ddns(),
        "containers": check_containers(),
        "disk": check_disk(),
        "certs": check_certs(),
        "root_ca": check_root_ca(),
    }
    _write_health_file(data)
    return data
