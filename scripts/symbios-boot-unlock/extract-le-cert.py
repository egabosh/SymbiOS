#!/usr/bin/env python3

import base64
import json
import os
import sys

acme_json = "/home/docker/traefik/letsencrypt/acme.json"
cert_dir = "/usr/local/sbin/symbios-boot-unlock"
domain = os.environ.get("SYMBIOS_BOOT_CERT_DOMAIN", "symbios-dev.dedyn.io")

if not os.access(acme_json, os.R_OK):
    sys.exit(0)

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

cert_pem = target.get("certificate", "")
key_pem = target.get("key", "")

try:
    cert_pem = base64.b64decode(cert_pem).decode()
    key_pem = base64.b64decode(key_pem).decode()
except Exception:
    sys.exit(0)

os.makedirs(cert_dir, exist_ok=True)

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
