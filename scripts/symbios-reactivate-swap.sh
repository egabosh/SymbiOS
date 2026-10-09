#!/bin/bash
# SymbiOS - Reactivate swap on the encrypted mapper without reboot.
#
# Skipped when too much swap is in use (swapoff could OOM the box) - then
# the next reboot activates it via crypttab/fstab. Called from
# base-services/hardening.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Reactivate swap on the encrypted mapper (cryptswap) without rebooting.
Skips the swapoff when too much swap is in use. Always reports changed
(the playbook sets changed_when: true). No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_reactivate_swap {
  local f_used f_free
  f_used=$(free -m | awk '/^Swap:/ {print $3}')
  f_free=$(free -m | awk '/^Mem:/ {print $7}')
  if [[ "${f_used}" -ge "${f_free}" ]]
  then
    echo "too much swap in use (${f_used}M used, ${f_free}M free), reboot to activate encrypted swap"
    return 0
  fi
  swapoff -a
  if systemctl restart systemd-cryptsetup@cryptswap 2>/dev/null
  then
    true
  else
    /lib/cryptsetup/cryptdisks_start cryptswap
  fi
  swapon -a
  swapon --show=NAME --noheadings
}

f_reactivate_swap
