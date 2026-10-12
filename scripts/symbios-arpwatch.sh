#!/bin/bash
# SymbiOS - Keep one arpwatch instance per local LAN interface running.
#
# arpwatch passively records MAC/IP/hostname triples it sees on the wire
# into /var/lib/arpwatch/<iface>.dat, which symbios-network-scan.sh reads
# for the dashboard (no active probing, near-realtime data).
#
# Instances use the Debian systemd template (arpwatch@<iface>, supervised,
# restarted on failure). Interfaces are discovered dynamically on every
# run (same eligibility rules as the scan: private IPv4, excluding lo,
# veth*, virbr*, br-*, docker*, base-services and services), so added or
# removed NICs are picked up automatically.
#
# Usage: symbios-arpwatch.sh (usually every 5 minutes via cron)

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Reconcile arpwatch template instances with the currently present LAN
interfaces: enable and start missing ones, disable and stop instances
of removed interfaces. Eligible means a private IPv4 address, excluding
lo, veth*, virbr*, br-*, docker*, base-services and services.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

if ! systemctl cat arpwatch@.service >/dev/null 2>&1
then
  g_echo_error "no arpwatch@.service template (basics.yml installs arpwatch)"
  exit 1
fi

# Collect eligible interfaces (deduplicated).
g_ifaces=()
while read -r f_iname f_cidr
do
  [[ -z "${f_iname}" ]] && continue
  case "${f_iname}" in
    lo|veth*|virbr*|br-*|docker*|base-services|services)
      continue
      ;;
  esac
  case "${f_cidr}" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
      ;;
    *)
      continue
      ;;
  esac
  f_known=""
  for f_have in ${g_ifaces[@]+"${g_ifaces[@]}"}
  do
    [[ "${f_have}" == "${f_iname}" ]] && f_known="yes"
  done
  if [[ -z "${f_known}" ]]
  then
    g_ifaces+=("${f_iname}")
  fi
done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}')

# Enable and start missing instances.
for f_iface in ${g_ifaces[@]+"${g_ifaces[@]}"}
do
  if systemctl is-enabled "arpwatch@${f_iface}" >/dev/null 2>&1 \
     && systemctl is-active "arpwatch@${f_iface}" >/dev/null 2>&1
  then
    continue
  fi
  g_echo_note "enabling arpwatch@${f_iface}"
  systemctl enable --now "arpwatch@${f_iface}" 2>&1 | tail -1
done

# Disable and stop instances of interfaces that are gone.
while read -r f_unit f_rest
do
  [[ "${f_unit}" == arpwatch@* ]] || continue
  f_inst="${f_unit#arpwatch@}"
  f_inst="${f_inst%.service}"
  [[ -z "${f_inst}" ]] && continue
  f_known=""
  for f_have in ${g_ifaces[@]+"${g_ifaces[@]}"}
  do
    [[ "${f_have}" == "${f_inst}" ]] && f_known="yes"
  done
  if [[ -z "${f_known}" ]]
  then
    g_echo_note "disabling orphaned arpwatch@${f_inst}"
    systemctl disable --now "arpwatch@${f_inst}" 2>&1 | tail -1
  fi
done < <(systemctl list-units 'arpwatch@*' --all --no-legend --plain 2>/dev/null)
