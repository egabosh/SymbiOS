#!/bin/bash
# SymbiOS - Start hd-idle only for real rotating disks.
#
# Called by symbios-after-mount.sh after the LUKS data volume was mounted.
# The Debian hd-idle.service stays disabled (boot policy, AGENTS.md); this
# helper starts a transient unit with explicit per-disk rules instead.
#
# Detection uses udev's ID_ATA_ROTATION_RATE_RPM: sysfs queue/rotational and
# lsblk ROTA report 1 even for SSDs behind USB bridges, while udev reports
# 0 for those SSDs and the real RPM for HDDs. Unknown disks are never touched.
#
# Usage: symbios-hd-idle.sh [-h | --help | --dry-run]
# Exit codes: 0 = ok, 1 = start failed, 2 = usage error.

g_script_name="$(basename "$0")"

if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi

# Minimal output helpers when gaboshlib is unavailable (rootfs boot helper).
if ! command -v g_echo_note >/dev/null 2>&1
then
  function g_echo {
    echo "$*"
  }
  function g_echo_note {
    echo "NOTE: $*"
  }
  function g_echo_warn {
    echo "WARN: $*" >&2
  }
fi

g_idle_seconds=900
g_log_file="/var/log/hd-idle.log"
g_unit_name="symbios-hd-idle.service"

function f_usage {
  cat << EOF
Usage: ${g_script_name} [-h | --help | --dry-run]

Start hd-idle via a transient systemd unit for udev-detected rotating disks
only. SSDs (including USB bridges reporting ROTA=1), the disk hosting / and
disks with an unknown rotation rate are never included. Without arguments the
unit is (re)started; --dry-run only prints the disks and generated options.

Exit codes: 0 ok, 1 start failed, 2 usage error.
EOF
}

f_dry_run=false
case "${1:-}" in
  -h|--help)
    f_usage
    exit 0
    ;;
  --dry-run)
    f_dry_run=true
    ;;
  "")
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac
if [[ $# -gt 1 ]]
then
  f_usage >&2
  exit 2
fi

# Resolve the top-level block device that carries / so a spinning system disk
# is never spun down. Walk the PKNAME chain to get past LUKS/LVM/partitions.
function f_root_disk {
  local f_current f_parent f_i
  f_current="$(findmnt -n -o SOURCE / 2>/dev/null)" || return 0
  [[ -n "${f_current}" ]] || return 0
  for f_i in $(seq 1 10)
  do
    f_parent="$(lsblk -no PKNAME "${f_current}" 2>/dev/null | head -1)"
    [[ -n "${f_parent}" ]] || break
    f_current="/dev/${f_parent}"
  done
  printf '%s\n' "${f_current##*/}"
}

# Emit kernel names of physical disks with a positive ATA rotation rate.
function f_rotating_disks {
  local f_path f_name f_prop f_rpm f_root
  f_root="$(f_root_disk)"
  for f_path in /sys/block/*
  do
    f_name="${f_path##*/}"
    case "${f_name}" in
      loop*|ram*|dm-*|md*|zram*|sr*|scd*|nbd*|rbd*)
        continue
        ;;
    esac
    [[ -e "/dev/${f_name}" ]] || continue
    [[ "${f_name}" == "${f_root}" ]] && continue
    f_prop="$(udevadm info --query=property --name="/dev/${f_name}" 2>/dev/null | grep '^ID_ATA_ROTATION_RATE_RPM=' || true)"
    [[ -n "${f_prop}" ]] || continue
    f_rpm="${f_prop#*=}"
    [[ "${f_rpm}" =~ ^[1-9][0-9]*$ ]] || continue
    printf '%s\n' "${f_name}"
  done
}

# Default idle 0 means "never spin down"; only named disks get a timeout.
function f_build_options {
  local f_disk f_opts="-i 0"
  for f_disk in ${g_disks}
  do
    f_opts="${f_opts} -a ${f_disk} -i ${g_idle_seconds}"
  done
  printf '%s -l %s\n' "${f_opts}" "${g_log_file}"
}

g_disks="$(f_rotating_disks)"
g_options="$(f_build_options)"

if [[ -z "${g_disks}" ]]
then
  systemctl stop "${g_unit_name}" >/dev/null 2>&1 || true
  g_echo_note "no rotating disks detected - hd-idle not started"
  exit 0
fi

g_echo_note "rotating disks detected: ${g_disks//$'\n'/ }"
if [[ "${f_dry_run}" == true ]]
then
  g_echo "hd-idle options: ${g_options}"
  exit 0
fi

systemctl stop "${g_unit_name}" >/dev/null 2>&1 || true
if systemd-run --unit="${g_unit_name%.service}" --collect --property=Restart=always --property=RestartSec=10s /usr/sbin/hd-idle ${g_options}
then
  g_echo_note "hd-idle started for ${g_disks//$'\n'/ }"
else
  g_echo_warn "hd-idle start failed"
  exit 1
fi
exit 0
