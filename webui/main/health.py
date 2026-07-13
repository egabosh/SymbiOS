import subprocess
import os
import json
import glob
import time
import yaml
from datetime import datetime, timezone

DOCKER_LOG_DIR = "/docker/containers"
CONTAINER_INDEX = "/log/docker-containers.tsv"
SERVICE_STATUS_FILE = "/log/symbios-services.tsv"
HEALTH_FILE = "/log/system-health.json"
PUBLIC_IP_CACHE = "/config/.public-ips.json"
PUBLIC_IP_CACHE_TTL = 300
LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")
STEPCA_HOST = "acme-pki-stepca"
STEPCA_PORT = 9000
TRAEFIK_HOST = "traefik"

def _load_config_vars():
    """Read the SymbiOS inventory (same file the WebUI uses) and return its vars."""
    try:
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        return config.get("all", {}).get("vars", {})
    except Exception:
        return {}


def _get_check_hosts():
    """Build the list of (sni, connect_host, port) tuples to cert-check.

    LDAP is only exposed through Traefik in local mode, so it is only
    included there. All other hosts are derived from base_domain.
    """
    vars_ = _load_config_vars()
    base = vars_.get("base_domain", "symbios.local")
    default_domain = vars_.get("default_domain", "local")
    hosts = [
        (base, TRAEFIK_HOST, 443),
        (f"auth.{base}", TRAEFIK_HOST, 443),
        (f"traefik.{base}", TRAEFIK_HOST, 443),
    ]
    if default_domain == "local":
        hosts.append(("ldap.local", TRAEFIK_HOST, 443))
    return hosts


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


def check_remote_exec():
    import socket
    # The WebUI applies config changes by running playbooks directly via SSH
    # (paramiko -> host root + forced command symbios-exec.sh). No daemon is
    # involved, so we verify the on-demand exec path is ready: the SSH key must
    # be present and the host SSH gateway reachable.
    key = "/config/.ssh/id_symbios"
    if not os.path.exists(key):
        return {"status": "warn", "message": "SSH exec key missing"}
    try:
        with socket.create_connection(("host.docker.internal", 22), timeout=3):
            pass
    except OSError:
        return {"status": "warn", "message": "Cannot reach host SSH (host.docker.internal:22)"}
    return {"status": "ok", "message": "SSH exec gateway reachable"}


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
    vars_ = _load_config_vars()
    default_domain = vars_.get("default_domain", "local")
    expected = {
        "traefik": "Traefik (Reverse Proxy)",
        "symbios-ui-symbios-webui-1": "WebUI",
        "ldap-openldap-1": "OpenLDAP",
        f"ldap-ldap.ldap.{default_domain}-1": "LDAP Domain",
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


def _read_public_ip_cache():
    try:
        with open(PUBLIC_IP_CACHE) as f:
            data = json.load(f)
        if time.time() - data.get("ts", 0) < PUBLIC_IP_CACHE_TTL:
            return data
    except Exception:
        pass
    return None


def _write_public_ip_cache(ipv4, ipv6):
    try:
        with open(PUBLIC_IP_CACHE, "w") as f:
            json.dump({"ipv4": ipv4, "ipv6": ipv6, "ts": time.time()}, f)
    except Exception:
        pass


def _is_valid_ip(s):
    # Reject HTML, whitespace, empty strings
    if not s or '<' in s or '>' in s or ' ' in s or '\n' in s:
        return False
    parts = s.split('.')
    # IPv4: exactly 4 dot-separated digit groups
    if len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        return True
    # IPv6: must contain colon
    if ':' in s:
        return True
    return False


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
    results = [check_cert(sni, host, port) for sni, host, port in _get_check_hosts()]
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
    import yaml, urllib.request, urllib.error
    try:
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        vars_ = config.get("all", {}).get("vars", {})
        ddns_host = vars_.get("ddns_host", "")
        ddns_apikey = vars_.get("ddns_apikey", "")
    except Exception:
        return {"status": "warn", "message": "Cannot read config"}

    if not ddns_host:
        if vars_.get("default_domain", "local") == "local":
            return {"status": "ok", "message": "not configured (local mode)"}
        return {"status": "warn", "message": "DDNS not configured"}

    if not ddns_host.endswith(".dedyn.io"):
        ddns_host = ddns_host + ".dedyn.io"

    if ddns_apikey:
        try:
            req = urllib.request.Request(
                f"https://desec.io/api/v1/domains/{ddns_host}/",
                headers={"Authorization": f"Token {ddns_apikey}"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    return {"status": "warn", "message": f"{ddns_host}: HTTP {resp.status}"}
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

    # Fetch current public IPs (with caching)
    current_ipv4 = ""
    current_ipv6 = ""
    cache = _read_public_ip_cache()
    if cache:
        current_ipv4 = cache.get("ipv4", "")
        current_ipv6 = cache.get("ipv6", "")
    else:
        try:
            stdout, _, _ = _run(["curl", "-s", "https://checkipv4.dedyn.io/"], timeout=5)
            candidate = stdout.strip()
            if _is_valid_ip(candidate):
                current_ipv4 = candidate
        except Exception:
            pass
        try:
            stdout, _, _ = _run(["curl", "-s", "https://checkipv6.dedyn.io/"], timeout=5)
            candidate = stdout.strip()
            if _is_valid_ip(candidate) and ":" in candidate:
                current_ipv6 = candidate
        except Exception:
            pass
        if current_ipv4 or current_ipv6:
            _write_public_ip_cache(current_ipv4, current_ipv6)

    # Fetch DNS records from deSEC API
    dns_ipv4 = []
    dns_ipv6 = []
    if ddns_apikey:
        try:
            req = urllib.request.Request(
                f"https://desec.io/api/v1/domains/{ddns_host}/rrsets/",
                headers={"Authorization": f"Token {ddns_apikey}"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                rrsets = json.loads(resp.read().decode())
                for rr in rrsets:
                    if rr["type"] == "A":
                        dns_ipv4.extend(rr["records"])
                    elif rr["type"] == "AAAA":
                        dns_ipv6.extend(rr["records"])
        except Exception:
            pass

    host_msg = f"{ddns_host}"
    details = {}

    if ddns_apikey:
        ipv6_mode = vars_.get("ddns_ipv6", "")
        skip_ipv4 = ipv6_mode == "only"

        if skip_ipv4 or (current_ipv4 and current_ipv4 in dns_ipv4):
            details["ipv4"] = {"status": "ok", "message": "IPv4 match" if not skip_ipv4 else "Skipped (IPv6-only)"}
        elif current_ipv4:
            details["ipv4"] = {"status": "warn", "message": f"IPv4 mismatch: got {current_ipv4}, DNS has {dns_ipv4}"}
        elif dns_ipv4:
            details["ipv4"] = {"status": "ok", "message": f"DNS has A record {dns_ipv4}"}
        else:
            details["ipv4"] = {"status": "ok", "message": "No IPv4 (OK)"}

        if current_ipv6 and current_ipv6 in dns_ipv6:
            details["ipv6"] = {"status": "ok", "message": f"IPv6: {current_ipv6} (matches DNS)"}
        elif current_ipv6:
            details["ipv6"] = {"status": "warn", "message": f"IPv6 mismatch: got {current_ipv6}, DNS has {dns_ipv6}"}
        elif dns_ipv6:
            details["ipv6"] = {"status": "ok", "message": f"DNS has AAAA record {dns_ipv6}"}
        else:
            details["ipv6"] = {"status": "ok", "message": "No IPv6 (OK)"}
    else:
        details["ipv4"] = {"status": "warn", "message": "No API key — cannot check DNS"}
        details["ipv6"] = {"status": "warn", "message": "No API key — cannot check DNS"}

    statuses = [v["status"] for v in details.values()]
    overall = "error" if "error" in statuses else "warn" if "warn" in statuses else "ok"
    return {"status": overall, "message": host_msg, "ddns_host_status": details}


def run_all():
    data = {
        "ldap": check_ldap(),
        "authelia": check_authelia(),
        "traefik": check_traefik(),
        "stepca": check_stepca(),
        "remote_exec": check_remote_exec(),
        "playbooks": check_playbooks(),
        "ddns": check_ddns(),
        "containers": check_containers(),
        "disk": check_disk(),
        "certs": check_certs(),
        "root_ca": check_root_ca(),
    }
    _write_health_file(data)
    return data
