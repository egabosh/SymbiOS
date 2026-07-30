#!/bin/bash
# SymbiOS - Extract LE certificate from Traefik for boot-unlock HTTPS server
#
# Reads Traefik's acme.json, finds the cert for the configured domain,
# and writes PEM files to the symbios-boot-unlock directory.

acme_json="/home/docker/traefik/letsencrypt/acme.json"
cert_dir="/usr/local/sbin/symbios-boot-unlock"
domain="${SYMBIOS_BOOT_CERT_DOMAIN:-symbios-dev.dedyn.io}"

[[ ! -r "$acme_json" ]] && exit 0

cert_b64=$(jq -r \
  '.letsencrypt.Certificates[] | select(.domain.main == "'$domain'") | .certificate' \
  "$acme_json" 2>/dev/null) || exit 0

key_b64=$(jq -r \
  '.letsencrypt.Certificates[] | select(.domain.main == "'$domain'") | .key' \
  "$acme_json" 2>/dev/null) || exit 0

[[ -z "$cert_b64" ]] && exit 0

mkdir -p "$cert_dir"

cert_pem=$(echo "$cert_b64" | base64 -d 2>/dev/null) || exit 0
key_pem=$(echo "$key_b64" | base64 -d 2>/dev/null) || exit 0

old_cert=""
[[ -f "$cert_dir/cert.pem" ]] && old_cert=$(<"$cert_dir/cert.pem")

if [[ "$cert_pem" != "$old_cert" ]]
then
  echo "$cert_pem" > "$cert_dir/cert.pem"
  echo "$key_pem" > "$cert_dir/key.pem"
  chmod 600 "$cert_dir/key.pem"
  echo "LE cert updated for $domain"
fi
