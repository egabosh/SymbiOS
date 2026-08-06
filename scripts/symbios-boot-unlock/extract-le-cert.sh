#!/bin/bash
# SymbiOS - Extract LE certificate from Traefik for boot-unlock HTTPS server
#
# Reads Traefik's acme.json, finds the cert for the configured domain,
# and writes PEM files to the symbios-boot-unlock directory.

acme_json="/symbios/base-services/traefik/letsencrypt/acme.json"
cert_dir="/usr/local/sbin/symbios-boot-unlock"
inventory="/symbios/base-services/symbios-ui/config/inventory.yml"
domain="${SYMBIOS_BOOT_CERT_DOMAIN:-}"

# Fall back to base_domain from the inventory (bash-only extraction, no python/jq)
if [[ -z "$domain" ]] && [[ -r "$inventory" ]]
then
  f_content=$(<"$inventory")
  if [[ "$f_content" == *base_domain:* ]]
  then
    f_line="${f_content#*base_domain:}"
    f_line="${f_line%%$'\n'*}"
    domain="${f_line//[[:space:]\'\"]/}"
  fi
fi

[[ -z "$domain" ]] && exit 0

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
