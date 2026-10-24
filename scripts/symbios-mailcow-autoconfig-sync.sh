#!/bin/bash
# SymbiOS - Sync autoconfig/autodiscover routes from mailcow domains
#
# Reads all active, non-relay domains from mailcow's MariaDB and updates
# /symbios/base-services/traefik/providers/mailcow-autoconfig.yml accordingly.
# autoconfig.<base_domain>/autodiscover.<base_domain> are always included.

function f_usage {
  cat << 'USAGE'
Usage: $(basename "$0") [OPTIONS]

Sync autoconfig/autodiscover routes from mailcow domains.

Options:
  -h, --help          Show this help and exit
  --dry-run           Show what would be written without writing
  -v, --verbose       Verbose output

Environment (from symbios-lib.sh):
  g_git_root, g_data_root and others are used.

Exit codes:
  0 - ok, file created/updated or unchanged
  1 - error (mailcow DB not reachable or write failed)
USAGE
}

g_verbose=0
g_dryrun=0
while [[ $# -gt 0 ]]
do
  case "$1" in
    -h|--help)
      f_usage
      exit 0
      ;;
    --dry-run)
      g_dryrun=1
      shift
      ;;
    -v|--verbose)
      g_verbose=1
      shift
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage
      exit 1
      ;;
  esac
done

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f /etc/bash/gaboshlib.include ]] && . /etc/bash/gaboshlib.include
source "${g_script_dir}/symbios-lib.sh"

g_out="${g_base_services_root}/traefik/providers/mailcow-autoconfig.yml"
g_tmp="${g_out}.tmp.$$"

function f_log {
  local level="$1"; shift
  if [[ "$level" == "DEBUG" && "$g_verbose" -eq 0 ]]; then return 0; fi
  g_echo "$level: $*"
}

f_log INFO "Starting mailcow autoconfig sync"

# Ensure target directory exists
mkdir -p "$(dirname "$g_out")"

# Get base_domain and acme_resolver from inventory
g_base_domain="$(f_symbios_var base_domain 2>/dev/null || echo "")"
if [[ -z "$g_base_domain" ]]; then
  g_echo_error "Could not determine base_domain from inventory"
  exit 1
fi

g_acme_resolver="$(f_symbios_var acme_resolver 2>/dev/null || echo "")"
[[ -z "$g_acme_resolver" ]] && g_acme_resolver="letsencrypt"

# Read active, non-relay domains from mailcow MariaDB. When the database is
# unreadable the existing provider file must stay untouched (a partial list
# would drop routes), so the script exits without writing in that case.
g_domains_raw=""
if docker ps --format '{{.Names}}' | grep -q '^mailcowdockerized-mysql-mailcow-1$'; then
  g_domains_raw="$(docker exec mailcowdockerized-mysql-mailcow-1 sh -c \
    'mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" -N -e "SELECT domain FROM domain WHERE active=1 AND backupmx=0 ORDER BY domain;"' 2>/dev/null || echo "")"
fi

if [[ -z "$g_domains_raw" ]]; then
  f_log WARN "mailcow database unreadable; keeping the existing provider file"
  exit 0
fi

# Build the host list: autoconfig/autodiscover for every mailcow domain plus
# the base domain (which is not a mailcow domain but must keep working).
g_list=""
while IFS= read -r dom; do
  [[ -z "$dom" ]] && continue
  g_list="${g_list}autoconfig.${dom}
autodiscover.${dom}
"
done <<< "${g_domains_raw}
${g_base_domain}"

# Remove duplicates while preserving order
g_unique=""
declare -A g_seen
while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  if [[ -z "${g_seen[$h]:-}" ]]; then
    g_unique="${g_unique}${h}"$'\n'
    g_seen[$h]=1
  fi
done <<< "$g_list"

# If we got no domains from DB and no base domain somehow, don't overwrite
if [[ -z "$g_unique" ]]; then
  g_echo_error "No hosts to configure; not overwriting existing file"
  exit 1
fi

# Build rule
g_rule=""
while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  if [[ -z "$g_rule" ]]; then
    g_rule="Host(\`${h}\`)"
  else
    g_rule="${g_rule} || Host(\`${h}\`)"
  fi
done <<< "$g_unique"

# Generate config
cat > "$g_tmp" << YAML
http:
  routers:
    mailcow-autoconfig:
      rule: "${g_rule}"
      service: mailcow-autoconfig
      entryPoints:
        - "https"
      tls:
        certResolver: ${g_acme_resolver}
      middlewares:
        - "secHeaders@file"
  services:
    mailcow-autoconfig:
      loadBalancer:
        servers:
          - url: "http://symbios-mailcow-autoconfig:80"
YAML

chown root:docker "$g_tmp" 2>/dev/null || true
chmod 0444 "$g_tmp"

if [[ "$g_dryrun" -eq 1 ]]; then
  f_log INFO "DRY RUN - would write:"
  cat "$g_tmp"
  rm -f "$g_tmp"
  exit 0
fi

# Compare with existing file
if [[ -f "$g_out" ]]; then
  if cmp -s "$g_tmp" "$g_out"; then
    f_log INFO "No changes"
    rm -f "$g_tmp"
    exit 0
  fi
fi

# Atomically replace
mv "$g_tmp" "$g_out"
f_log INFO "updated $(printf '%s' "$g_unique" | grep -c '^') hosts"
echo "updated"
exit 0
