#!/bin/bash
# SymbiOS - Remove OpenWrt VM host bridges and helper units.
#
# Reverts what services/openwrt-vm.yml deploys on the host: the ifupdown
# bridge configs, the bridges themselves, the bridge-dhcp timer unit and the
# openwrt-vm external-system state. Idempotent (missing pieces are skipped
# silently). Declared as the uninstall cleanup command in the playbook docs
# block; also usable manually before re-running the playbook. Called from
# symbios-uninstall.sh (whitelisted symbios-* command).

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Remove the OpenWrt host bridges (openwrt-lan/-iot/-tor/-misc), their
ifupdown configs, the symbios-ow-bridge-dhcp timer unit and the openwrt-vm
external-system state. Idempotent: already-removed pieces are skipped.
No arguments.

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
f_no_args "$@"

function f_openwrt_cleanup {
  local f_bridge
  local f_external_cleanup="${g_script_dir}/symbios-external-system-cleanup.sh"
  rm -f /etc/network/interfaces.d/openwrt-lan /etc/network/interfaces.d/openwrt-iot \
    /etc/network/interfaces.d/openwrt-tor /etc/network/interfaces.d/openwrt-misc
  for f_bridge in openwrt-lan openwrt-iot openwrt-tor openwrt-misc
  do
    ip link del "${f_bridge}" 2>/dev/null || true
  done
  systemctl disable --now symbios-ow-bridge-dhcp.timer 2>/dev/null || true
  rm -f /etc/systemd/system/symbios-ow-bridge-dhcp.service \
    /etc/systemd/system/symbios-ow-bridge-dhcp.timer
  # The VM target is gone, so its local registration and remote-run markers
  # are stale. Keep this best-effort: bridge cleanup must not fail because of
  # a config file that is already absent.
  if [[ -x "${f_external_cleanup}" ]]
  then
    "${f_external_cleanup}" openwrt-vm || \
      g_echo_warn "Could not remove openwrt-vm external-system state"
  fi
}

f_openwrt_cleanup
