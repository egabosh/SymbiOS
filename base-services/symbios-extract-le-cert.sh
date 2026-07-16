#!/bin/bash
# Extract Let's Encrypt cert from Traefik acme.json to boot unlock dir.
# Run via cron so the cert is available on root partition even when
# /home (encrypted) is locked after reboot.

g_acme_json="/home/docker/traefik/letsencrypt/acme.json"
g_cert_dir="/usr/local/sbin/symbios-boot-unlock"
g_domain="${SYMBIOS_BOOT_CERT_DOMAIN:-symbios-dev.dedyn.io}"

# acme.json may not be readable (e.g. /home locked)
if [ ! -r "$g_acme_json" ]; then
    exit 0
fi

mkdir -p "$g_cert_dir"

python3 << PYEOF
import json, os, sys

acme_json = "$g_acme_json"
cert_dir = "$g_cert_dir"
domain = "$g_domain"

try:
    d = json.load(open(acme_json))
except Exception:
    sys.exit(0)

certs = d.get("letsencrypt", {}).get("Certificates", [])
target = None
for c in certs:
    if c.get("domain", {}).get("main", "") == domain:
        target = c
        break

if not target:
    sys.exit(0)

cert_pem = target.get("certificate", "").replace("\\n", "\n")
key_pem = target.get("key", "").replace("\\n", "\n")

cert_path = os.path.join(cert_dir, "cert.pem")
key_path = os.path.join(cert_dir, "key.pem")

old_cert = ""
if os.path.exists(cert_path):
    old_cert = open(cert_path).read()

if cert_pem != old_cert:
    with open(cert_path, "w") as f:
        f.write(cert_pem)
    with open(key_path, "w") as f:
        f.write(key_pem)
    os.chmod(key_path, 0o600)
    print("LE cert updated for", domain)
else:
    print("LE cert unchanged for", domain)
PYEOF
