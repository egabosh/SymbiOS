#!/bin/bash
# SymbiOS - Start host services that need /symbios after the data volume mount.
#
# Called once from /etc/rc.local (SymbiOS boot sequence block) after the LUKS
# boot-unlock + `mount /symbios`. Implements the systemd boot policy from
# AGENTS.md: units needing files below /symbios are `enabled: false` and are
# started here in a defined order. Every step is guarded so a single missing
# component never aborts the boot.
#
# Usage: symbios-after-mount.sh [-h | --help]
# Exit codes: 0 always (single failures only warn, the boot must continue).

g_script_name="$(basename "$0")"

if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi

function f_usage {
  cat << EOF
Usage: ${g_script_name} [-h | --help]

Start all /symbios-dependent host systemd units after the data volume was
mounted (LUKS boot-unlock). Called from /etc/rc.local, not by hand.

Order: container runtime (docker/containerd) -> network bridge assignments
-> libvirt default storage pool -> WoL watcher instances -> arpwatch
reconcile -> runchecks daemon + watchdog timer (delayed, backgrounded).

Exit code is always 0. Single failures only print a warning.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi
if [[ $# -gt 0 ]]
then
  f_usage >&2
  exit 1
fi

# Paths below /symbios (documented defaults, see inventory.yml git_root and
# the wol-suspend playbook power_config_dir default). No symbios-lib.sh here:
# this script lives on the rootfs and must also work the moment the mount
# just appeared.
g_git_root="/symbios/git/SymbiOS"
g_power_instances="/symbios/base-services/symbios-ui/config/power/instances"

# Log helper when gaboshlib is absent (minimal fallback).
if ! command -v g_echo_note >/dev/null 2>&1
then
  function g_echo_note {
    echo "NOTE: $*"
  }
  function g_echo_warn {
    echo "WARN: $*" >&2
  }
fi

# 1. Container runtime. Mounts below /symbios are its data-root, so the
# daemon must not autostart at boot (disabled, see symbios-ui.yml).
if systemctl start containerd docker 2>/dev/null
then
  g_echo_note "container runtime started"
else
  g_echo_warn "container runtime start failed"
fi

# 1b. Base-service containers always come back after boot. `docker stop`
# (e.g. by the data-disk migration for a consistent copy) marks them
# stopped, which unless-stopped policies then keep stopped forever.
# Platform services (traefik, authelia, ldap, webui, ...) must not stay
# down - user services keep their stopped state and are untouched.
if command -v docker >/dev/null 2>&1
then
  for f_i in $(seq 1 30)
  do
    docker ps >/dev/null 2>&1 && break
    sleep 2
  done
  f_base_stopped=$(docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null | \
    awk '$1 ~ /^symbios-base-/ && $2 != "running" {print $1}' || true)
  for f_c in ${f_base_stopped}
  do
    if docker start "${f_c}" >/dev/null 2>&1
    then
      g_echo_note "base container started: ${f_c}"
    else
      g_echo_warn "base container start failed: ${f_c}"
    fi
  done
fi

# 2. Network bridge assignments. The unit ExecStart lives below /symbios
# (git_root), so it is disabled at boot and only started here. It retries
# internally until late bridges (openwrt-*) exist.
if [[ -f /etc/systemd/system/symbios-bridge-assign.service ]]
then
  if systemctl start symbios-bridge-assign.service 2>/dev/null
  then
    g_echo_note "bridge assignments applied"
  else
    g_echo_warn "bridge assignment start failed"
  fi
fi

# 3. Libvirt default storage pool. The pool path is below /symbios and cannot
# be active before the mount (pool-autostart at libvirtd start silently
# fails). VM restore in rc.local needs the pool up.
if command -v virsh >/dev/null 2>&1
then
  virsh pool-start default 2>/dev/null || true
fi

# 4. WoL watcher instances. Unit files ExecStart below /symbios (git_root),
# so instances are disabled at boot and (re)started here from the instances
# file written by wol-suspend.yml.
if [[ -s "${g_power_instances}" ]]
then
  while read -r f_instance f_rest
  do
    [[ -z "${f_instance}" ]] && continue
    [[ "${f_instance}" == \#* ]] && continue
    systemctl start "${f_instance}" 2>/dev/null || \
      g_echo_warn "WoL instance start failed: ${f_instance}"
  done < "${g_power_instances}"
fi

# 5. Arpwatch reconcile. Tunnel/bridge interfaces (iot0, ...) exist only now
# (rc.local created them). Instances are start-only by policy, never enabled.
if [[ -x "${g_git_root}/scripts/symbios-arpwatch.sh" ]]
then
  "${g_git_root}/scripts/symbios-arpwatch.sh" 2>/dev/null || \
    g_echo_warn "arpwatch reconcile failed"
fi

# 6. Host nslcd (LDAP NSS lookups). /home and /root are symlinks below
# /symbios, so its mount namespace (InaccessibleDirectories=/home) fails
# before the mount - and its server is a container that needs docker first.
# Wait for slapd on the loopback port, then start. Deferred work MUST be a
# detached systemd-run unit, never `( ... ) &`: gaboshlib kills all
# background jobs in its EXIT trap (g_kill_all_background_jobs).
if systemctl cat nslcd.service >/dev/null 2>&1
then
  systemd-run --unit=symbios-nslcd-wait --collect /bin/bash -c 'for i in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/389) 2>/dev/null && break; sleep 10; done; exec /bin/systemctl start nslcd.service' 2>/dev/null || \
    g_echo_warn "nslcd wait unit failed to schedule"
fi

# 7. Health daemon + watchdog timer, delayed so post-mount starters
# (OpenVPN, hostapd, VM restore blocks later in rc.local) settle first.
# Same detachment rule as above: transient timer unit, not a background sleep.
systemd-run --unit=symbios-runchecks-delayed --collect --on-active=30s /bin/systemctl start runchecks.service runchecks-watchdog.timer 2>/dev/null || \
  g_echo_warn "runchecks delayed start failed to schedule"

g_echo_note "after-mount dispatch done"
exit 0
