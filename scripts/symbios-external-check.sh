#!/bin/bash
# SymbiOS - Check external reachability via base_domain
# Verifies from the server itself whether the internet can reach it
# through port forwarding (DNS, external port probe, local service).
#
# Usage: symbios-external-check.sh [OPTIONS]
#   -d, --domain <domain>   Domain to check (default: base_domain from inventory.yml)
#   -p, --ports <80,443>    Comma-separated ports (default: 80,443)
#   -h, --help              Show this help
#
# Output: JSON on stdout, exit 0 only if all ports are externally reachable.

source /etc/bash/gaboshlib.include
source symbios-lib.sh

g_domain=""
g_ports="80,443"
g_probe_url="https://ports.yougetsignal.com/check-port.php"
g_public_ip=""
g_public_ip6=""
g_dns_ip=""
g_dns_ip6=""

function f_usage {
  echo "Usage: $0 [OPTIONS]"
  echo "  -d, --domain <domain>   Domain to check (default: base_domain from inventory.yml)"
  echo "  -p, --ports <80,443>    Comma-separated ports (default: 80,443)"
  echo "  -h, --help              Show this help"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]
do
  case "$1" in
    -d|--domain)
      g_domain="$2"
      shift 2
      ;;
    -p|--ports)
      g_ports="$2"
      shift 2
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      f_usage >&2
      exit 1
      ;;
  esac
done

# Read base_domain from inventory.yml if not given on the command line
function f_load_domain {
  if [[ -n "$g_domain" ]]
  then
    return 0
  fi

  if [[ ! -f "$g_inventory" ]]
  then
    f_json_error "Inventory not found: ${g_inventory}"
  fi

  g_domain=$(f_symbios_var base_domain "")
  if [[ -z "$g_domain" ]]
  then
    f_json_error "base_domain not found in ${g_inventory}"
  fi
}

# Fetch the current public IP via deSEC's echo service (IPv4, IPv6 fallback)
function f_get_public_ip {
  g_public_ip=$(curl -s -m 10 https://checkipv4.dedyn.io/ 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$g_public_ip" ]]
  then
    g_public_ip=$(curl -s -m 10 https://checkipv6.dedyn.io/ 2>/dev/null | tr -d '[:space:]')
  fi
  if ! [[ "$g_public_ip" =~ ^[0-9a-fA-F:.]+$ ]]
  then
    g_public_ip=""
  fi
}

# DynDNS fallback resolution is only available for deSEC-hosted domains: the
# deSEC DynDNS config must exist and the domain must be managed by deSEC
# (dedyn.io/desec.io suffix or listed in dedynhosts). No third-party resolvers
# (Google/Cloudflare) are ever used.
function f_ddns_active {
  [[ -f /usr/local/etc/dedyn.conf ]] || return 1
  case "${g_domain}" in
    *.dedyn.io|*.desec.io)
      return 0
      ;;
  esac
  grep -q "${g_domain}" /usr/local/etc/dedyn.conf 2>/dev/null
}

# Query deSEC's authoritative nameservers for a record type. Used when the
# host's own resolver does not answer for a deSEC-managed domain (e.g. home
# routers that filter AAAA answers or fail DNSSEC validation).
function f_resolve_public {
  local f_type="$1" f_domain="$2" f_line
  if ! command -v dig >/dev/null 2>&1
  then
    return 1
  fi
  f_ddns_active || return 1
  for f_resolver in ns2.desec.org ns1.desec.io
  do
    f_line=$(dig +short @${f_resolver} ${f_type} "${f_domain}" 2>/dev/null | head -1)
    if [[ -n "$f_line" ]]
    then
      echo "$f_line"
      return 0
    fi
  done
  return 1
}

# Resolve the domain's IPv4 (A) address: host resolver first, then public
# resolvers. AAAA records are reported separately via f_resolve_dns6.
function f_resolve_dns {
  local f_domain="$1"
  local f_line
  f_line=$(getent ahostsv4 "${f_domain}" 2>/dev/null | head -1)
  if [[ -n "$f_line" ]]
  then
    echo "${f_line%% *}"
    return 0
  fi
  f_line=$(f_resolve_public A "${f_domain}")
  if [[ -n "$f_line" ]]
  then
    echo "$f_line"
    return 0
  fi
  return 1
}

# Resolve the domain's IPv6 address (AAAA record) only: host resolver first,
# then public resolvers.
function f_resolve_dns6 {
  local f_domain="$1"
  local f_line
  f_line=$(getent ahostsv6 "${f_domain}" 2>/dev/null | head -1)
  if [[ -n "$f_line" ]]
  then
    echo "${f_line%% *}"
    return 0
  fi
  f_line=$(f_resolve_public AAAA "${f_domain}")
  if [[ -n "$f_line" ]]
  then
    echo "$f_line"
    return 0
  fi
  return 1
}

# Fetch the current public IPv6 address (returns empty if not IPv6 capable).
function f_get_public_ip6 {
  g_public_ip6=$(curl -s -m 10 https://checkipv6.dedyn.io/ 2>/dev/null | tr -d '[:space:]')
  if ! [[ "$g_public_ip6" =~ ^[0-9a-fA-F:]+$ ]]
  then
    g_public_ip6=""
  fi
}

# Probe a port from outside (external service connects to domain:port)
function f_probe_port {
  local f_domain="$1" f_port="$2"
  local f_resp

  f_resp=$(curl -s -m 20 -X POST "${g_probe_url}" \
    -d "remoteAddress=${f_domain}&portNumber=${f_port}" 2>/dev/null)

  if [[ "$f_resp" == *"is open on"* ]]
  then
    echo "open"
  elif [[ "$f_resp" == *"is closed on"* ]]
  then
    echo "closed"
  elif [[ "$f_resp" == *"Invalid remote address"* ]]
  then
    # The probe service cannot resolve the domain to an IPv4 address (no A
    # record): an IPv6-only domain cannot be verified by an IPv4-based probe.
    echo "no_ipv4"
  else
    echo "unknown"
  fi
}

# Raw TCP connect check against a host (IPv4, or IPv6 in brackets).
function f_tcp_check {
  local f_host="$1" f_port="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/${f_host}/${f_port}" 2>/dev/null
}

# Check whether the port is reachable locally (IPv4 loopback, falling back to
# IPv6 loopback for services that listen only on IPv6).
function f_check_local {
  local f_port="$1"

  if f_tcp_check "127.0.0.1" "$f_port" || f_tcp_check "[::1]" "$f_port"
  then
    echo "up"
  else
    echo "down"
  fi
}

# Check whether the port is served on the IPv6 stack (wildcard or an explicit
# IPv6 address). A TCP connect to the public address from inside the LAN can
# fail because of router hairpinning, so the listening socket is inspected
# instead. Combined with the AAAA match this verifies IPv6 reachability, which
# needs no port forwarding/NAT.
function f_check_public_ipv6 {
  local f_port="$1"

  if [[ -z "$g_public_ip6" ]]
  then
    echo "down"
    return 0
  fi
  if ss -ltn 2>/dev/null | grep -qP "\[[^]]+\]:${f_port}\s"
  then
    echo "up"
  else
    echo "down"
  fi
}

# --- Main ---

g_lockfile

f_load_domain
f_get_public_ip
f_get_public_ip6
g_dns_ip=$(f_resolve_dns "$g_domain")
g_dns_ip6=$(f_resolve_dns6 "$g_domain")

# DNS match (public IP vs resolved A record)
g_dns_match="unknown"
if [[ -n "$g_public_ip" ]] && [[ -n "$g_dns_ip" ]]
then
  if [[ "$g_public_ip" == "$g_dns_ip" ]]
  then
    g_dns_match="true"
  else
    g_dns_match="false"
  fi
fi

# DNS match over IPv6 (AAAA record vs current global IPv6 address).
# Only meaningful when the host actually has IPv6.
g_dns_match6="unknown"
if [[ -n "$g_public_ip6" ]]
then
  if [[ -n "$g_dns_ip6" ]]
  then
    if [[ "$g_public_ip6" == "$g_dns_ip6" ]]
    then
      g_dns_match6="true"
    else
      g_dns_match6="false"
    fi
  fi
fi

# Pure IPv6 mode: the domain has no IPv4 A record, the host has a public IPv6
# and the domain resolves to an AAAA record. IPv6 needs no port forwarding
# (no NAT), so the IPv4-only external probe service is skipped entirely.
g_ipv6_only=false
if [[ -z "$g_dns_ip" ]] && [[ -n "$g_dns_ip6" ]] && [[ -n "$g_public_ip6" ]]
then
  g_ipv6_only=true
fi

# Run checks for every requested port
g_ports_json=""
g_first_port=true
g_all_open=true
g_unknown_count=0
g_port_count=0

for f_port in ${g_ports//,/ }
do
  g_port_count=$((g_port_count + 1))

  if [[ "$g_ipv6_only" == true ]]
  then
    # IPv6-only: no external IPv4 probe possible. Verify the port on the
    # public IPv6 address instead; reachable only when the AAAA record also
    # points to that address.
    f_ext=$(f_check_public_ipv6 "$f_port")
    f_loc=$(f_check_local "$f_port")
    if [[ "$f_ext" == "up" ]] && [[ "$g_dns_match6" == "true" ]]
    then
      f_open=true
    else
      f_open=false
    fi
  else
    f_ext=$(f_probe_port "$g_domain" "$f_port")
    f_loc=$(f_check_local "$f_port")
    [[ "$f_ext" == "open" ]] && f_open=true || f_open=false
    [[ "$f_ext" == "unknown" ]] && g_unknown_count=$((g_unknown_count + 1))
  fi

  [[ "$f_open" == true ]] || g_all_open=false

  if [[ "$g_first_port" == true ]]
  then
    g_first_port=false
    g_ports_json="["
  else
    g_ports_json+=","
  fi
  g_ports_json+="{\"port\":${f_port},\"external\":\"${f_ext}\",\"local\":\"${f_loc}\"}"
done

if [[ -n "$g_ports_json" ]]
then
  g_ports_json+="]"
else
  g_ports_json="[]"
fi

# Build human-readable summary
g_summary=""
if [[ "$g_ipv6_only" == true ]]
then
  # IPv6 needs no port forwarding (no NAT) - the AAAA match plus the service
  # answering on the public IPv6 address is the meaningful verification.
  if [[ "$g_dns_match6" == "true" ]] && [[ "$g_all_open" == true ]]
  then
    g_summary="IPv6-only setup: the AAAA record matches the public IPv6 address and all ports are served on it. IPv6 needs no port forwarding - make sure the router allows inbound IPv6."
  else
    g_summary="IPv6-only setup: the AAAA record matches the public IPv6 address, but not all ports answer on it (service down or the router blocks inbound IPv6)."
  fi
elif [[ "$g_unknown_count" -eq "$g_port_count" ]]
then
  g_summary="External port probe service unreachable - cannot verify port forwarding."
elif [[ "$g_all_open" == true ]]
then
  g_summary="All requested ports are reachable from the internet."
else
  g_summary="Some ports are not reachable from the internet. Check the router port forwarding - note that ISPs with CGNAT may block inbound connections."
fi

if [[ "$g_dns_match" == false ]]
then
  g_summary+=" DNS (IPv4) resolves to ${g_dns_ip}, but the current public IP is ${g_public_ip} (DynDNS may be outdated)."
fi

if [[ -n "$g_public_ip6" ]] && [[ "$g_dns_match6" == false ]]
then
  g_summary+=" DNS (IPv6) resolves to ${g_dns_ip6}, but the current public IPv6 is ${g_public_ip6}."
fi

# Assemble final JSON
if [[ "$g_all_open" == true ]]
then
  g_ok="true"
else
  g_ok="false"
fi

printf '{"ok":%s,"domain":%s,"public_ip":%s,"dns_resolved":%s,"dns_match":"%s","public_ip6":%s,"dns_resolved6":%s,"dns_match6":"%s","ports":%s,"summary":%s}\n' \
  "$g_ok" \
  "$(echo "$g_domain" | f_json_escape)" \
  "$(echo "$g_public_ip" | f_json_escape)" \
  "$(echo "$g_dns_ip" | f_json_escape)" \
  "$g_dns_match" \
  "$(echo "$g_public_ip6" | f_json_escape)" \
  "$(echo "$g_dns_ip6" | f_json_escape)" \
  "$g_dns_match6" \
  "$g_ports_json" \
  "$(echo "$g_summary" | f_json_escape)"

if [[ "$g_all_open" == true ]]
then
  exit 0
else
  exit 1
fi
