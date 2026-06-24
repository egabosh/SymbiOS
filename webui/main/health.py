import subprocess
import os
import json
from datetime import datetime, timezone

DOCKER_LOG_DIR = "/docker/containers"
CONTAINER_INDEX = "/var/run/docker-containers.tsv"
SERVICE_STATUS_FILE = "/var/run/symbios-services.tsv"
LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")
STEPCA_HOST = "acme-pki-stepca"
STEPCA_PORT = 9000

CHECK_HOSTS = [
    ("symbios.local", 443),
    ("auth.local", 443),
    ("openldap.local", 636),
    ("ldap.local", 443),
    ("traefik.local", 443),
]

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
        "curl", "-sf", "-o", "/dev/null",
        "http://authelia:9091/api/health",
    ], timeout=5)
    if rc == 0:
        return {"status": "ok", "message": "Healthy"}
    return {"status": "error", "message": stderr.strip() or f"exit code {rc}"}

def check_traefik():
    stdout, stderr, rc = _run([
        "curl", "-sf", "http://traefik:8080/api/version",
    ], timeout=5)
    if rc == 0:
        try:
            data = json.loads(stdout)
            return {"status": "ok", "message": f"Version {data.get('Version', '?')}"}
        except Exception:
            return {"status": "ok", "message": "API reachable"}
    return {"status": "error", "message": stderr.strip() or f"exit code {rc}"}

def check_stepca():
    stdout, stderr, rc = _run([
        "curl", "-sf",
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

def check_containers():
    expected = [
        "traefik",
        "symbios-ui-symbios-webui-1",
        "ldap-openldap-1",
        "ldap-ldap.ldap.local-1",
        "acme-pki-stepca",
    ]
    running = set()
    try:
        with open(CONTAINER_INDEX) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    running.add(parts[1])
    except FileNotFoundError:
        return {"status": "warn", "message": "Container index not available"}

    missing = [name for name in expected if name not in running]
    if not missing:
        return {"status": "ok", "message": f"{len(running)} containers running"}
    return {"status": "warn", "message": f"Missing: {', '.join(missing)}"}

def check_disk():
    checks = []
    for path in ["/", "/config"]:
        try:
            stat = os.statvfs(path)
            total = stat.f_frsize * stat.f_blocks
            free = stat.f_frsize * stat.f_bfree
            used_pct = 100 - (free / total * 100)
            checks.append(f"{path}: {used_pct:.0f}% used")
        except Exception:
            checks.append(f"{path}: unknown")
    return {"status": "ok", "message": "; ".join(checks)}

def check_cert(host, port):
    stdout, stderr, rc = _run([
        "openssl", "s_client", "-connect", f"{host}:{port}",
        "-servername", host, "-showcerts",
    ], timeout=10)
    if rc != 0:
        return {"status": "error", "message": stderr.strip() or "Connection failed"}
    for line in stdout.split("\n"):
        if "notAfter=" in line:
            date_str = line.split("notAfter=", 1)[1].strip()
            return _eval_cert_date(date_str, host)
    return {"status": "warn", "message": f"{host}: Could not parse cert expiry"}

def _eval_cert_date(date_str, label):
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
    results = [check_cert(host, port) for host, port in CHECK_HOSTS]
    errors = [r for r in results if r["status"] == "error"]
    warns = [r for r in results if r["status"] == "warn"]
    if errors:
        return {"status": "error", "message": "; ".join(r["message"] for r in results)}
    if warns:
        return {"status": "warn", "message": "; ".join(r["message"] for r in results)}
    return {"status": "ok", "message": "; ".join(r["message"] for r in results)}

def check_root_ca():
    stdout, stderr, rc = _run([
        "openssl", "s_client", "-connect",
        f"{STEPCA_HOST}:{STEPCA_PORT}",
        "-servername", STEPCA_HOST, "-showcerts",
    ], timeout=10)
    if rc != 0:
        return {"status": "error", "message": f"Step-CA unreachable: {stderr.strip()}"}
    for line in stdout.split("\n"):
        if "notAfter=" in line:
            date_str = line.split("notAfter=", 1)[1].strip()
            return _eval_cert_date(date_str, f"{STEPCA_HOST} Root-CA")
    return {"status": "warn", "message": "Could not parse Root-CA cert expiry"}

def run_all():
    return {
        "ldap": check_ldap(),
        "authelia": check_authelia(),
        "traefik": check_traefik(),
        "stepca": check_stepca(),
        "config_daemon": check_config_daemon(),
        "containers": check_containers(),
        "disk": check_disk(),
        "certs": check_certs(),
        "root_ca": check_root_ca(),
    }
