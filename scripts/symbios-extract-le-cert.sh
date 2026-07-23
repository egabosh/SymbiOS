#!/bin/bash

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

# Extract Let's Encrypt cert from Traefik acme.json to boot unlock dir.
# Run via cron so the cert is available on root partition even when
# /home (encrypted) is locked after reboot.

g_acme_json="/home/docker/traefik/letsencrypt/acme.json"
g_cert_dir="/usr/local/sbin/symbios-boot-unlock"
g_domain="${SYMBIOS_BOOT_CERT_DOMAIN:-symbios-dev.dedyn.io}"

# acme.json may not be readable (e.g. /home locked)
if [ ! -r "$g_acme_json" ]
then
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
