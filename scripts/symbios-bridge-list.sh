#!/bin/bash
# SymbiOS - List Linux bridges and physical interfaces for the WebUI
# Output: JSON with the bridges a physical interface can be assigned to and
# the physical interfaces currently visible, plus the stored assignments.
#
# Bridges that are managed by Docker or SymbiOS infrastructure are hidden so
# they cannot be dumbly overwritten: anything named br-* (Docker / bridge-utils
# default), docker* and the SymbiOS service networks (symbios_base_services,
# symbios_services) or the base-services / services names are excluded.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Helper: print "yes" when a candidate name matches one of the reserved
# patterns. "base-services" and "services" are exact names - not prefixes -
# so a bridge called "my-services" stays selectable.
f_is_reserved() {
  local f_name="$1"
  case "${f_name}" in
    br-*|docker*|symbios_base_services|symbios_services|base-services|services)
      echo "yes"
      ;;
    *)
      echo "no"
      ;;
  esac
}

# Interfaces that are in use and must not be offered: the only exclusion
# criterion is a real IP address. Link-local addresses (IPv4 169.254.0.0/16,
# IPv6 fe80::/10) do NOT count as "in use" - look at the address itself, not
# the kernel scope flag, because IPv4 link-local is often reported with
# "scope global". WLAN interfaces stay selectable even when hostapd is bound
# to them; what gets hidden here is e.g. the management port with the default
# route attached (eth0 with its global / ULA addresses).
g_used=""
while read -r f_n
do
  [[ -z "${f_n}" ]] && continue
  g_used="${g_used} ${f_n}"
done < <(ip -o addr show 2>/dev/null | awk '{
    if ($2 == "lo") next
    if ($3 == "inet"  && $4 ~ /^169\.254\./) next
    if ($3 == "inet6" && $4 ~ /^fe80:/) next
    sub(/@.*/, "", $2)
    print $2
  }')

# Physical interfaces: everything except loopback, virtual/Docker devices,
# bridges, the reserved pattern above and in-use interfaces (scope global IP).
# WLAN and Ethernet ports without a real IP are the interesting candidates.
g_ifaces=""
while read -r f_iface
do
  [[ -z "${f_iface}" ]] && continue
  case "${f_iface}" in
    lo|docker*|veth*|veth*@*|virbr*|br-*|vnet*|tap*|tun*|sit*|gre*|gretap*|ip6tnl*|wwan*|usb*)
      continue
      ;;
  esac
  if [[ "$(f_is_reserved "${f_iface}")" == "yes" ]]
  then
    continue
  fi
  if [[ " ${g_used} " == *" ${f_iface} "* ]]
  then
    continue
  fi
  g_ifaces="${g_ifaces} ${f_iface}"
done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

# Bridges: all link objects of type bridge, minus reserved names.
g_bridges=""
while read -r f_br
do
  [[ -z "${f_br}" ]] && continue
  if [[ "$(f_is_reserved "${f_br}")" == "yes" ]]
  then
    continue
  fi
  g_bridges="${g_bridges} ${f_br}"
done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')

# Sort deterministically.
bridges_list="$(echo ${g_bridges} | tr ' ' '\n' | sort -u | grep -v '^$')"

# Drop interfaces whose name equals a detected bridge (a bridge interface
# must not be enslaved to another bridge). This also removes the openwrt-*
# virtual bridges from the assignable interface list.
ifaces_list="$(echo ${g_ifaces} | tr ' ' '\n' | sort -u | grep -v '^$')"
if [[ -n "${bridges_list}" ]]
then
  filtered=""
  while read -r f_i
  do
    [[ -z "${f_i}" ]] && continue
    if echo "${bridges_list}" | grep -qx "${f_i}"
    then
      continue
    fi
    filtered="${filtered} ${f_i}"
  done <<< "${ifaces_list}"
  ifaces_list="$(echo ${filtered} | tr ' ' '\n' | grep -v '^$')"
fi

# Read the stored assignments (dict) from the inventory via python3 (robust
# for both flow and block YAML style; f_symbios_var only supports scalars).
current_json="$(python3 - "${g_inventory}" <<'PYEOF' 2>/dev/null
import json
import sys
import yaml

path = sys.argv[1]
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(1)
assignments = (cfg.get('all', {}).get('vars', {})
               .get('bridge_assignments') or {})
print(json.dumps(assignments))
PYEOF
)"
[[ -z "${current_json}" ]] && current_json='{}'

# Build the JSON payload. Routes the arrays through json_escape-less manual
# assembly since the names are simple interface/device names (a-zA-Z0-9_.-).
printf '{"bridges":['
f_first=1
for f_b in ${bridges_list}
do
  if [[ "${f_first}" -eq 1 ]]
  then
    f_first=0
  else
    printf ','
  fi
  printf '"%s"' "${f_b}"
done
printf '],"interfaces":['
f_first=1
for f_i in ${ifaces_list}
do
  if [[ "${f_first}" -eq 1 ]]
  then
    f_first=0
  else
    printf ','
  fi
  printf '"%s"' "${f_i}"
done
printf '],"current":%s}\n' "${current_json}"
