#!/bin/bash
# SymbiOS - Discover devices on the host's networks for the dashboard WebUI.
# Output: JSON with the scanned subnets (interface, CIDR) and the devices
# found in them (IP, MAC, vendor, hostname), plus the WiFi stations that are
# currently associated to the hostapd access point.
#
# Which networks are scanned: every interface with a private IPv4 address
# except the intentionally internal networks (Docker bridges br-*/docker0
# and the SymbiOS service networks base-services/services). OpenWrt VM
# bridges and their subnets are shown. The default-route subnet is listed
# first so the physical LAN sorts on top in the WebUI.
#
# Results are cached for 60 seconds so a frequently reloaded dashboard does
# not hammer the network.
#
# Usage: symbios-network-scan.sh [--fresh]

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Use a STABLE cache location (not the per-PID g_tmp, which is removed on
# exit) so the 60-second cache is shared across invocations and repeated
# dashboard refreshes do not re-scan the network.
f_cache="/tmp/symbios-network-scan.json"
if [[ ! -w /tmp ]] || [[ ! -d /tmp ]]
then
  f_cache="${g_tmp:-/tmp}/symbios-network-scan.json"
fi
f_fresh=0
if [[ "${1:-}" == "--fresh" ]]
then
  f_fresh=1
fi

# Serve the cached result unless a fresh scan is requested.
if [[ "${f_fresh}" -ne 1 ]] && [[ -s "${f_cache}" ]]
then
  if find "${f_cache}" -mmin -1 2>/dev/null | grep -q "${f_cache}"
  then
    cat "${f_cache}"
    exit 0
  fi
fi

# The default-route gateway (marked in the device list).
f_gw=""
while read -r f_route
do
  f_gw_tmp="$(echo "${f_route}" | awk '{ for (i=1;i<=NF;i++) if ($i=="via") print $(i+1) }')"
  if [[ -n "${f_gw_tmp}" ]]
  then
    f_gw="${f_gw_tmp}"
    break
  fi
done < <(ip -4 route show default 2>/dev/null)

# The interface that owns the default route (its subnet sorts first).
f_defdev=""
while read -r f_route
do
  f_defdev_tmp="$(echo "${f_route}" | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }')"
  if [[ -n "${f_defdev_tmp}" ]]
  then
    f_defdev="${f_defdev_tmp}"
    break
  fi
done < <(ip -4 route show default 2>/dev/null)

# --- Collect candidate subnets ----------------------------------------------
# Every interface with a private IPv4 that is not an intentionally internal
# network. The default-route interface is moved to the front of the list.
g_cidrs=()
g_nets=()
g_links=()
g_host_ips=()

f_is_internal_iface() {
  case "$1" in
    lo|veth*|veth*@*|virbr*|br-*|docker*|base-services|services)
      echo "yes"
      ;;
    *)
      echo "no"
      ;;
  esac
}

while read -r f_iname f_cidr
do
  [[ -z "${f_iname}" ]] && continue
  # Only private IPv4 ranges are scanned (public/WAN IPs must not be probed
  # from inside).
  case "${f_cidr}" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
      ;;
    *)
      continue
      ;;
  esac
  if [[ "$(f_is_internal_iface "${f_iname}")" == "yes" ]]
  then
    continue
  fi
  f_prefix="${f_cidr#*/}"
  [[ "${f_prefix}" -gt 30 ]] && continue

  f_self_ip="${f_cidr%/*}"
  g_host_ips+=("${f_self_ip}")

  # Compute the network address (mawk has no and(); do the bit math in bash).
  IFS='.' read -r f_o1 f_o2 f_o3 f_o4 <<< "${f_self_ip}"
  f_addr=$(( (f_o1 * 16777216) + (f_o2 * 65536) + (f_o3 * 256) + f_o4 ))
  f_mask=$(( 0xffffffff ))
  if [[ "${f_prefix}" -gt 0 ]]
  then
    f_shift=$(( 32 - f_prefix ))
    f_mask=$(( (~((1 << f_shift) - 1)) & 0xffffffff ))
  fi
  f_net=$(( (f_addr & f_mask) & 0xffffffff ))
  f_network="$(printf '%d.%d.%d.%d/%d' \
    $(( (f_net >> 24) & 255 )) $(( (f_net >> 16) & 255 )) \
    $(( (f_net >> 8) & 255 )) $(( f_net & 255 )) "${f_prefix}")"

  # Deduplicate by network.
  f_dup=""
  for (( f_n = 0; f_n < ${#g_nets[@]}; f_n++ ))
  do
    [[ "${g_nets[$f_n]}" == "${f_net}" ]] && f_dup="yes"
  done
  if [[ -n "${f_dup}" ]]
  then
    continue
  fi

  # Default-route interface goes first (so the physical LAN sorts on top).
  if [[ "${f_iname}" == "${f_defdev}" ]]
  then
    g_cidrs=("${f_network}" "${g_cidrs[@]}")
    g_nets=("${f_net}" "${g_nets[@]}")
    g_links=("${f_iname}" "${g_links[@]}")
  else
    g_cidrs+=("${f_network}")
    g_nets+=("${f_net}")
    g_links+=("${f_iname}")
  fi
done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}')

if [[ "${#g_cidrs[@]}" -eq 0 ]]
then
  f_json_error "No scanable private networks found."
fi

# --- Scan the collected subnets --------------------------------------------
f_raw=""
if command -v nmap >/dev/null 2>&1
then
  f_raw=$(nmap -sn -T4 --min-rate 200 "${g_cidrs[@]}" 2>/dev/null)
else
  f_raw="* neighbor fallback *"
fi

# Map a device IP back to one of the scanned subnets.
f_cidr_of() {
  local f_ip="$1" f_addr=0 f_i f_oa f_ob f_oc f_od f_mask f_shift
  IFS='.' read -r f_oa f_ob f_oc f_od <<< "${f_ip}"
  f_addr=$(( (f_oa * 16777216) + (f_ob * 65536) + (f_oc * 256) + f_od ))
  for (( f_i = 0; f_i < ${#g_nets[@]}; f_i++ ))
  do
    f_cidr="${g_cidrs[$f_i]}"
    f_pfx="${f_cidr#*/}"
    f_mask=$(( 0xffffffff ))
    if [[ "${f_pfx}" -gt 0 ]]
    then
      f_shift=$(( 32 - f_pfx ))
      f_mask=$(( (~((1 << f_shift) - 1)) & 0xffffffff ))
    fi
    f_net=$(( (f_addr & f_mask) & 0xffffffff ))
    [[ "${f_net}" == "${g_nets[$f_i]}" ]] && echo "${g_cidrs[$f_i]}" && return 0
  done
  echo ""
  return 1
}

# Map a device IP back to the interface it is connected through.
f_iface_of() {
  local f_ip="$1" f_addr=0 f_i f_oa f_ob f_oc f_od f_mask f_shift
  IFS='.' read -r f_oa f_ob f_oc f_od <<< "${f_ip}"
  f_addr=$(( (f_oa * 16777216) + (f_ob * 65536) + (f_oc * 256) + f_od ))
  for (( f_i = 0; f_i < ${#g_nets[@]}; f_i++ ))
  do
    f_cidr="${g_cidrs[$f_i]}"
    f_pfx="${f_cidr#*/}"
    f_mask=$(( 0xffffffff ))
    if [[ "${f_pfx}" -gt 0 ]]
    then
      f_shift=$(( 32 - f_pfx ))
      f_mask=$(( (~((1 << f_shift) - 1)) & 0xffffffff ))
    fi
    f_net=$(( (f_addr & f_mask) & 0xffffffff ))
    [[ "${f_net}" == "${g_nets[$f_i]}" ]] && echo "${g_links[$f_i]}" && return 0
  done
  echo ""
  return 1
}

# --- Build the device rows ---------------------------------------------------
# Rows are stored in insertion order (f_order) and keyed by MAC (preferred)
# or IP so the WiFi pass can enrich an already scanned device.
f_order=()
declare -A f_row

f_emit() {
  # Fields: name|ip|mac|vendor|wifi|ap|signal
  local f_name="$1" f_ip="$2" f_mac="$3" f_vendor="${4:-}" \
        f_wifi="${5:-false}" f_ap="${6:-}" f_signal="${7:-}"
  local f_is_self="false"
  local f_is_gw="false"
  local f_subnet="$(f_cidr_of "${f_ip}")"
  # The interface a device is connected through: for WiFi stations it is the
  # AP interface itself, for everything else the interface of its subnet.
  local f_iface="${f_ap}"
  [[ -z "${f_iface}" ]] && f_iface="$(f_iface_of "${f_ip}")"
  [[ "${f_ip}" == "${f_gw}" ]] && f_is_gw="true"
  local f_x
  for f_x in "${g_host_ips[@]}"
  do
    [[ "${f_x}" == "${f_ip}" ]] && f_is_self="true"
  done
  local f_sig_json="null"
  [[ -n "${f_signal}" ]] && f_sig_json="${f_signal}"
  local f_json
  f_json=$(printf '{"ip":%s,"mac":%s,"vendor":%s,"hostname":%s,"subnet":%s,"interface":%s,"self":%s,"gateway":%s,"wifi":%s,"ap":%s,"signal":%s}' \
    "$(printf '%s' "${f_ip}" | f_json_escape)" \
    "$(printf '%s' "${f_mac}" | f_json_escape)" \
    "$(printf '%s' "${f_vendor}" | f_json_escape)" \
    "$(printf '%s' "${f_name}" | f_json_escape)" \
    "$(printf '%s' "${f_subnet}" | f_json_escape)" \
    "$(printf '%s' "${f_iface}" | f_json_escape)" \
    "${f_is_self}" \
    "${f_is_gw}" \
    "${f_wifi}" \
    "$(printf '%s' "${f_ap}" | f_json_escape)" \
    "${f_sig_json}")
  local f_key=""
  if [[ -n "${f_mac}" ]]
  then
    f_key="mac:${f_mac,,}"
  elif [[ -n "${f_ip}" ]]
  then
    f_key="ip:${f_ip}"
  else
    return 0
  fi
  if [[ -z "${f_row[${f_key}]+x}" ]]
  then
    f_order+=("${f_key}")
  fi
  f_row[${f_key}]="${f_json}"
}

# Mark an existing row as a connected WiFi station (used for stations that
# were already found by the scan - same MAC). The device is connected to
# SymbiOS through the AP radio, so its interface becomes the AP interface.
f_mark_wifi() {
  local f_key="$1" f_ap="$2" f_sig="$3"
  local f_old="${f_row[${f_key}]}"
  local f_suffix
  f_suffix="$(printf '"wifi":true,"ap":%s,"signal":%s' \
    "$(printf '%s' "${f_ap}" | f_json_escape)" \
    "${f_sig:-null}")"
  f_old="${f_old/'"wifi":false,"ap":"","signal":null}'/${f_suffix}}"
  # Point the interface at the AP radio (e.g. wlan0) for wireless clients.
  f_row[${f_key}]="$(printf '%s' "${f_old}" \
    | sed "s/\"interface\":\"[a-z0-9._-]*\"/\"interface\":\"${f_ap}\"/")"
}

# --- Scan results -----------------------------------------------------------
if [[ "${f_raw}" == "* neighbor fallback *" ]]
then
  # Fallback: kernel neighbor table for all scanned subnets.
  while IFS= read -r f_line
  do
    f_fip="$(echo "${f_line}" | awk '{print $1}')"
    f_fmac="$(echo "${f_line}" | awk '{print $5}')"
    f_state="$(echo "${f_line}" | awk '{print $6}')"
    [[ -z "$(f_cidr_of "${f_fip}")" ]] && continue
    if [[ "${f_state}" == "REACHABLE" ]] || [[ "${f_state}" == "STALE" ]] \
       || [[ "${f_state}" == "DELAY" ]] || [[ "${f_state}" == "PROBE" ]]
    then
      f_emit "" "${f_fip}" "${f_fmac}"
    fi
  done < <(ip neigh show 2>/dev/null)
else
  # Parse the nmap output. A scan report starts a new device; a MAC line
  # belongs to the current device. Devices like the host itself may have no
  # MAC line, so every scan report is emitted.
  f_cur_name=""; f_cur_ip=""; f_cur_mac=""; f_cur_vendor=""; f_cur=""
  while IFS= read -r f_line
  do
    if [[ "${f_line}" == "Nmap scan report for "* ]]
    then
      if [[ -n "${f_cur}" ]]
      then
        IFS='|' read -r f_cur_name f_cur_ip f_cur_mac f_cur_vendor <<< "${f_cur}"
        f_emit "${f_cur_name}" "${f_cur_ip}" "${f_cur_mac}" "${f_cur_vendor}"
      fi
      f_subject="${f_line#Nmap scan report for }"
      f_name=""
      f_ip=""
      if [[ "${f_subject}" == *" ("*")" ]]
      then
        f_name="${f_subject%% (*}"
        f_ip="${f_subject#* (}"
        f_ip="${f_ip%)}"
      else
        f_ip="${f_subject}"
      fi
      f_cur="${f_name}|${f_ip}||"
    elif [[ "${f_line}" == "MAC Address: "* ]]
    then
      if [[ -n "${f_cur}" ]]
      then
        f_rest="${f_line#MAC Address: }"
        f_mac="${f_rest%% *}"
        f_vendor=""
        if [[ "${f_rest}" == *" ("*")" ]]
        then
          f_vendor="${f_rest#* (}"
          f_vendor="${f_vendor%)}"
        fi
        IFS='|' read -r f_cur_name f_cur_ip _f_cur_mac _f_cur_vendor <<< "${f_cur}"
        f_cur="${f_cur_name}|${f_cur_ip}|${f_mac}|${f_vendor}"
      fi
    fi
  done <<< "${f_raw}"
  if [[ -n "${f_cur}" ]]
  then
    IFS='|' read -r f_cur_name f_cur_ip f_cur_mac f_cur_vendor <<< "${f_cur}"
    f_emit "${f_cur_name}" "${f_cur_ip}" "${f_cur_mac}" "${f_cur_vendor}"
  fi
fi

# --- WiFi stations of the hostapd access point ------------------------------
# Associated stations are read via `iw` (works without the hostapd control
# socket). A station already found by the scan (same MAC) is simply marked
# as connected to the AP; every other station is added as a WiFi client with
# its MAC and signal.
while read -r f_wlan
do
  f_wlan="${f_wlan##* }"
  [[ "${f_wlan}" != wlan* ]] && [[ "${f_wlan}" != wl* ]] && continue
  f_wtype="$(iw dev "${f_wlan}" info 2>/dev/null | awk '/type/{print $2; exit}')"
  [[ "${f_wtype}" != "AP" ]] && continue
  f_sta_mac=""
  while IFS= read -r f_line
  do
    if [[ "${f_line}" == "Station "* ]]
    then
      f_sta_mac="${f_line#Station }"
      f_sta_mac="${f_sta_mac%% *}"
      f_sta_sig=""
    elif [[ "${f_line}" == *"signal:"* ]] && [[ -n "${f_sta_mac}" ]]
    then
      f_sta_sig="$(echo "${f_line}" | awk '{ for (i=1;i<=NF;i++) if ($i=="signal:") { print $(i+1); break } }')"
      f_sta_key="mac:${f_sta_mac,,}"
      if [[ -n "${f_row[${f_sta_key}]+x}" ]]
      then
        f_mark_wifi "${f_sta_key}" "${f_wlan}" "${f_sta_sig}"
      else
        # Not seen in the scan: resolve the IP via the neighbor table.
        f_sta_ip="$(ip neigh 2>/dev/null | awk -v m="${f_sta_mac,,}" \
          '{ if (tolower($5)==m) { print $1; exit } }')"
        f_emit "" "${f_sta_ip}" "${f_sta_mac}" "" "true" "${f_wlan}" "${f_sta_sig}"
      fi
      f_sta_mac=""
    fi
  done < <(iw dev "${f_wlan}" station dump 2>/dev/null)
done < <(iw dev 2>/dev/null | grep '^	Interface')

# --- Fill the host's own rows (self) with MAC + vendor -----------------------
# nmap never emits a MAC line for the local host itself (it learns MACs only
# from ARP replies of other hosts), so self rows with an empty MAC fall back to
# reading the interface MAC from the kernel and the vendor from the OUI
# database (/usr/share/ieee-data/oui.txt, fallback nmap-mac-prefixes).
f_self_mac() {
  ip -o link show dev "$1" 2>/dev/null | awk '{ for (i=1;i<=NF;i++) if ($i=="link/ether") { print toupper($(i+1)); exit } }'
}
f_self_vendor() {
  local f_oui="${1//:/}" f_v=""
  f_oui="${f_oui:0:6}"
  f_oui="${f_oui^^}"
  if [[ -f /usr/share/ieee-data/oui.txt ]]
  then
    f_v="$(awk -v o="${f_oui}" '$1==o { sub(/^[^ \t]+[ \t]+\([^)]*\)[ \t]+/, ""); print; exit }' /usr/share/ieee-data/oui.txt 2>/dev/null)"
  fi
  # oui.txt uses CRLF line endings; strip the trailing carriage return.
  f_v="${f_v%$'\r'}"
  if [[ -z "${f_v}" ]] && [[ -f /usr/share/nmap/nmap-mac-prefixes ]]
  then
    f_v="$(awk -v o="${f_oui}" '$1==o { sub(/^[^ \t]+[ \t]+/, ""); print; exit }' /usr/share/nmap/nmap-mac-prefixes 2>/dev/null)"
  fi
  printf '%s' "${f_v}"
}
for (( f_r = 0; f_r < ${#f_order[@]}; f_r++ ))
do
  f_cur="${f_row[${f_order[$f_r]}]}"
  # Skip rows that already carry a MAC or are not the host itself.
  [[ "${f_cur}" == *'"self":true'* ]] || continue
  [[ "${f_cur}" == *'"mac":""'* ]] || continue
  f_ifn="$(printf '%s' "${f_cur}" | sed -nE 's/.*"interface":"([a-z0-9._-]*)".*/\1/p')"
  [[ -z "${f_ifn}" ]] && continue
  f_ownmac="$(f_self_mac "${f_ifn}")"
  [[ -z "${f_ownmac}" ]] && continue
  f_ownver="$(f_self_vendor "${f_ownmac}")"
  f_ownver="${f_ownver//\\/\\\\}"
  f_ownver="${f_ownver//\"/\\\"}"
  f_ownver="${f_ownver//&/\\&}"
  f_row[${f_order[$f_r]}]="$(printf '%s' "${f_cur}" \
    | sed "s/\"mac\":\"\"/\"mac\":\"${f_ownmac}\"/; s/\"vendor\":\"\"/\"vendor\":\"${f_ownver}\"/")"
done

# --- Build the final payload ------------------------------------------------
f_scan_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

f_devices=""
f_first=1
for (( f_r = 0; f_r < ${#f_order[@]}; f_r++ ))
do
  if [[ "${f_first}" -eq 1 ]]
  then
    f_first=0
  else
    f_devices+=","
  fi
  f_devices+="${f_row[${f_order[$f_r]}]}"
done

f_sub_json=""
f_sub_first=1
for (( f_i = 0; f_i < ${#g_cidrs[@]}; f_i++ ))
do
  if [[ "${f_sub_first}" -eq 1 ]]
  then
    f_sub_first=0
  else
    f_sub_json+=","
  fi
  f_sub_json+="$(printf '{"cidr":%s,"interface":%s}' \
    "$(printf '%s' "${g_cidrs[$f_i]}" | f_json_escape)" \
    "$(printf '%s' "${g_links[$f_i]}" | f_json_escape)")"
done

f_payload="$(printf '{"scanned_at":"%s","subnets":[%s],"devices":[%s]}\n' \
  "${f_scan_end}" "${f_sub_json}" "${f_devices}")"
printf '%s' "${f_payload}" > "${f_cache}"
printf '%s' "${f_payload}"

exit 0