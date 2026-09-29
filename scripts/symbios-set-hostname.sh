#!/bin/bash
# SymbiOS - Set the system hostname from base_domain in inventory.yml

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

Set the system hostname to the base_domain configured in inventory.yml. The
FQDN (for example symbios-dev.dedyn.io) is written to /etc/hostname and
applied at runtime with hostnamectl; without systemd the hostname command is
used instead. The name is additionally mapped to the current LAN IPv4 in
/etc/hosts so it resolves locally (hostname -f, ssh <name> from the host).

The script is idempotent: it exits 0 without touching anything when the
hostname is already correct. It also exits 0 when base_domain is not
configured yet (empty, 'none', '0' or the 'symbios.local' placeholder), so it
is safe to call from a playbook and from the WebUI at any time.

Output: plain status lines, for example:
  hostname-unchanged: symbios-dev.dedyn.io
  /etc/hostname: SymbiOS -> symbios-dev.dedyn.io
  /etc/hosts: 172.23.0.223 symbios-dev.dedyn.io symbios-dev localhost
  hostname-changed: symbios-dev.dedyn.io

The final line carries a machine-readable state token (hostname-changed /
hostname-unchanged) so callers such as Ansible can detect a real change.

Options:
  --check           Report what would change, change nothing
  -h, --help        Show this help and exit

Exit codes:
  0  hostname is set, or there is nothing to do
  1  error (invalid base_domain, not root, write failed)
EOF
}

f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --check)
      f_check="yes"
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1" 2>/dev/null || echo "Unknown option: $1" >&2
      f_usage >&2
      exit 1
      ;;
  esac
  shift
done

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

f_hosts_file="/etc/hosts"

# --- find the /etc/hosts line that carries the host name -------------------

# The image builder writes "<lan-ip> <name> localhost", so the line to rewrite
# is the first non-comment entry that maps a non-loopback IPv4 address and also
# lists 'localhost'. Without such a line the first non-comment entry with a
# non-loopback IPv4 is used, and if there is none the entry is appended.
# Prints the line number, or 0 when no line qualifies.
function f_find_hosts_line {
  local f_no=0
  local f_fallback=0
  local f_line
  local f_inet='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  local f_field
  local f_has_localhost
  while read -r f_line
  do
    f_no=$((f_no + 1))
    f_line="${f_line%%#*}"
    # Collapse the field separators so the positional parameters are the fields
    set -- ${f_line}
    [[ $# -ge 1 ]] || continue
    [[ "$1" =~ ${f_inet} ]] || continue
    [[ "$1" == 127.* ]] && continue
    [[ "${f_fallback}" == "0" ]] && f_fallback="${f_no}"
    f_has_localhost="no"
    for f_field in "$@"
    do
      if [[ "${f_field}" == "localhost" ]]
      then
        f_has_localhost="yes"
        break
      fi
    done
    if [[ "${f_has_localhost}" == "yes" ]]
    then
      echo "${f_no}"
      return 0
    fi
  done < "${f_hosts_file}"
  echo "${f_fallback}"
}

# --- resolve the target hostname -------------------------------------------

# base_domain is the shared parent domain (Traefik Host rules, Authelia
# session cookie, mail addresses), so it is the natural name for the host.
f_domain="$(f_symbios_var base_domain)"
f_domain="${f_domain,,}"
# A trailing dot is valid in a FQDN but not in /etc/hostname.
f_domain="${f_domain%.}"

if [[ -z "${f_domain}" ]] || [[ "${f_domain}" == "none" ]] || [[ "${f_domain}" == "0" ]]
then
  g_echo_note "base_domain is not configured - hostname unchanged"
  exit 0
fi

# 'symbios.local' is the internal placeholder that /settings/dns/ writes when
# the DNS configuration is removed. It is not a real domain, so it must never
# become the system hostname.
if [[ "${f_domain}" == "symbios.local" ]]
then
  g_echo_note "base_domain is the local placeholder ${f_domain} - hostname unchanged"
  exit 0
fi

# --- validate the domain ---------------------------------------------------

# Each label: alphanumeric, may contain hyphens but not at the edges. At least
# two labels are required, so the result is always a FQDN.
f_label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
if [[ ${#f_domain} -gt 253 ]] || ! [[ "${f_domain}" =~ ^${f_label}(\.${f_label})+$ ]]
then
  g_echo_error "base_domain is not a valid FQDN: ${f_domain}"
  exit 1
fi

# A dotted quad is syntactically a FQDN but must never become a hostname.
if [[ "${f_domain}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
then
  g_echo_error "base_domain must not be an IPv4 address: ${f_domain}"
  exit 1
fi

# Short hostname (first label), needed for the /etc/hosts alias.
f_short="${f_domain%%.*}"

# --- current state ---------------------------------------------------------

f_current="$(tr -d '[:space:]' < /etc/hostname 2>/dev/null)"
# The running hostname can drift away from the file (manual 'hostname', a
# restore from a backup, a container runtime). It is part of the state we own.
f_runtime="$(hostname 2>/dev/null)"

if [[ "${f_check}" == "no" ]] && [[ "$(id -u)" != "0" ]]
then
  g_echo_error "Must run as root to change the system hostname"
  exit 1
fi

# --- LAN IPv4 for the /etc/hosts entry -------------------------------------

# Collect the globally scoped IPv4 addresses with their interface names, so
# Docker bridges and other virtual interfaces can be skipped.
g_lan_ips=()
g_lan_ifaces=()
while read -r f_iface f_addr
do
  [[ -n "${f_addr}" ]] || continue
  g_lan_ips+=("${f_addr}")
  g_lan_ifaces+=("${f_iface}")
done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | sed 's|.*inet ||;s|/.*||')

function f_in_lan_ips {
  local f_ip="$1"
  local f_idx
  for f_idx in "${!g_lan_ips[@]}"
  do
    if [[ "${g_lan_ips[$f_idx]}" == "${f_ip}" ]]
    then
      return 0
    fi
  done
  return 1
}

# Prefer the address already in /etc/hosts (it stays stable across a reapply),
# then the address the host cron job recorded, then the first real interface.
# Container bridges and other virtual interfaces are never a good answer.
f_hosts_line_no="$(f_find_hosts_line)"
f_ip=""
f_hosts_ip=""
if [[ -n "${f_hosts_line_no}" && "${f_hosts_line_no}" != "0" ]]
then
  f_hosts_line="$(sed -n "${f_hosts_line_no}p" "${f_hosts_file}")"
  # Everything up to the first blank is the address.
  f_hosts_ip="${f_hosts_line%%[[:space:]]*}"
  f_in_lan_ips "${f_hosts_ip}" && f_ip="${f_hosts_ip}"
fi
if [[ -z "${f_ip}" ]]
then
  f_recorded="$(tr -d '[:space:]' < "${g_config_dir}/.host-ip" 2>/dev/null)"
  if [[ -n "${f_recorded}" ]] && f_in_lan_ips "${f_recorded}"
  then
    f_ip="${f_recorded}"
  fi
fi
if [[ -z "${f_ip}" ]]
then
  f_idx=0
  while [[ "${f_idx}" -lt "${#g_lan_ips[@]}" ]]
  do
    if ! [[ "${g_lan_ifaces[$f_idx]}" =~ ^(docker|br-|veth|virbr|cni|flannel) ]]
    then
      f_ip="${g_lan_ips[$f_idx]}"
      break
    fi
    f_idx=$((f_idx + 1))
  done
fi
if [[ -z "${f_ip}" ]]
then
  f_ip="${f_hosts_ip}"
fi
if [[ -z "${f_ip}" ]]
then
  f_ip="127.0.1.1"
  g_echo_warn "No LAN IPv4 found - mapping ${f_domain} to ${f_ip}"
fi

# --- report / apply --------------------------------------------------------

g_echo "Target hostname: ${f_domain} (short: ${f_short}, address: ${f_ip})"

f_hosts_new_line="${f_ip} ${f_domain} ${f_short} localhost"
f_hosts_current=""
if [[ -n "${f_hosts_line_no}" && "${f_hosts_line_no}" != "0" ]]
then
  f_hosts_current="$(sed -n "${f_hosts_line_no}p" "${f_hosts_file}")"
fi

# Compare field by field: /etc/hosts may separate the columns with tabs or
# several spaces, so a plain string comparison would always report a change.
function f_hosts_same {
  local f_current_line="$1"
  local f_expected_line="$2"
  local f_expected
  local f_field
  local f_found
  # Split the expected line into the positional parameters (unquoted on
  # purpose: this is the word splitting).
  # shellcheck disable=SC2086
  set -- ${f_expected_line}
  for f_expected in "$@"
  do
    f_found="no"
    # shellcheck disable=SC2086
    for f_field in ${f_current_line}
    do
      [[ "${f_field}" == "${f_expected}" ]] && f_found="yes"
    done
    [[ "${f_found}" == "yes" ]] || return 1
  done
  return 0
}

if f_hosts_same "${f_hosts_current}" "${f_hosts_new_line}"
then
  g_echo "  /etc/hosts unchanged: ${f_hosts_new_line}"
  f_hosts_changed="no"
else
  g_echo "  /etc/hosts: ${f_hosts_current:-<none>} -> ${f_hosts_new_line}"
  f_hosts_changed="yes"
fi

# The Traefik healthcheck maps every service host to the Traefik bridge, which
# can include base_domain itself. Pointing the name at the host address wins
# for the resolver (first match), so say so instead of letting it surprise.
f_conflict="$(grep -E "[[:space:]]${f_domain}([[:space:]]|\$)" "${f_hosts_file}" \
  | grep -v -F "${f_hosts_new_line}")"
if [[ -n "${f_conflict}" ]]
then
  g_echo_warn "Another /etc/hosts line also maps ${f_domain}, it will be shadowed:"
  while read -r f_line
  do
    [[ -n "${f_line}" ]] && g_echo_warn "  ${f_line}"
  done <<< "${f_conflict}"
fi

if [[ "${f_current}" == "${f_domain}" && "${f_runtime}" == "${f_domain}" \
   && "${f_hosts_changed}" == "no" ]]
then
  g_echo_note "hostname-unchanged: ${f_domain}"
  exit 0
fi

if [[ "${f_check}" == "yes" ]]
then
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

# Replace the line in place, otherwise append it. A plain line loop keeps the
# rest of the file byte for byte identical and avoids awk quoting surprises
# with tabs in the replacement.
f_tmp="$(mktemp)"
f_no=0
while read -r f_line
do
  f_no=$((f_no + 1))
  if [[ "${f_no}" == "${f_hosts_line_no}" ]]
  then
    printf '%s\n' "${f_hosts_new_line}"
  else
    printf '%s\n' "${f_line}"
  fi
done < "${f_hosts_file}" > "${f_tmp}"
if [[ -z "${f_hosts_line_no}" || "${f_hosts_line_no}" == "0" ]]
then
  printf '\n%s\n' "${f_hosts_new_line}" >> "${f_tmp}"
fi
cat "${f_tmp}" > "${f_hosts_file}"
rm -f "${f_tmp}"
chmod 0644 "${f_hosts_file}"

# /etc/hostname first, so the file is authoritative even without systemd.
if [[ "${f_current}" != "${f_domain}" ]]
then
  printf '%s\n' "${f_domain}" > /etc/hostname
  chmod 0644 /etc/hostname
  g_echo "  /etc/hostname: ${f_current:-<none>} -> ${f_domain}"
else
  g_echo "  /etc/hostname unchanged: ${f_domain}"
fi

# hostnamectl also rewrites /etc/hostname, but it is the supported way to
# apply the name to the running system and to record it in systemd's state.
if [[ -d /run/systemd/system ]]
then
  if hostnamectl set-hostname "${f_domain}" 2>/dev/null
  then
    g_echo "  hostnamectl set-hostname ${f_domain}"
  else
    g_echo_warn "hostnamectl failed - using hostname(1) instead"
    hostname "${f_domain}"
  fi
elif hostname "${f_domain}" 2>/dev/null
then
  g_echo "  hostname ${f_domain} (no systemd)"
else
  g_echo_error "Failed to apply the hostname at runtime"
  exit 1
fi

g_echo_note "hostname-changed: ${f_domain}"
exit 0
