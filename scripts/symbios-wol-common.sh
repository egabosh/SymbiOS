#!/bin/bash
# SymbiOS - Shared helpers for the WoL watchers (wol-watch-tail.sh,
# wol-watch-idle.sh). Sourced, not executed.
#
# A target lives in ${g_config_dir}/power/targets.yml (WebUI source of
# truth); the playbook renders ${g_config_dir}/power/live/<name>.conf
# (KEY="value" lines) from it. Everything referenced here - scripts, SSH
# key, access log - lives under /symbios, which may unlock late after a
# reboot. Callers must call f_wol_wait_ready first; it blocks until all
# paths exist instead of failing at boot.

# Load the live config of target $1 into WOL_* globals. Returns 1 when the
# config file does not exist (yet).
function f_wol_load_conf {
  local f_name="$1"
  local f_conf="${g_config_dir}/power/live/${f_name}.conf"
  if ! [[ -f "${f_conf}" ]]
  then
    return 1
  fi
  # Reset globals so a re-read never inherits stale values.
  WOL_NAME=""
  WOL_SSH_KEY=""
  WOL_WAKE_ENABLED="false"
  WOL_WAKE_MAC=""
  WOL_WAKE_HOST=""
  WOL_WAKE_PATTERNS=""
  WOL_LOG_PATH=""
  WOL_SUSPEND_ENABLED="false"
  WOL_SUSPEND_HOST=""
  WOL_SUSPEND_IF=""
  WOL_IDLE_TIMEOUT="900"
  WOL_GRACE_AFTER_WOL="300"
  WOL_TCP_PORTS=""
  WOL_LAN_SUBNET=""
  WOL_EXTRA_LOCAL_B64=""
  WOL_EXTRA_REMOTE_B64=""
  # shellcheck disable=SC1090
  . "${f_conf}"
  WOL_NAME="${TARGET_NAME:-$1}"
  WOL_SSH_KEY="${SSH_KEY:-}"
  WOL_WAKE_ENABLED="${WAKE_ENABLED:-false}"
  WOL_WAKE_MAC="${WAKE_MAC:-}"
  WOL_WAKE_HOST="${WAKE_HOST:-}"
  WOL_WAKE_PATTERNS="${WAKE_PATTERNS:-}"
  if [[ -n "${LOG_PATH:-}" ]]
  then
    WOL_LOG_PATH="${LOG_PATH}"
  else
    WOL_LOG_PATH="${g_base_services_root}/traefik/log/access.log"
  fi
  WOL_SUSPEND_ENABLED="${SUSPEND_ENABLED:-false}"
  WOL_SUSPEND_HOST="${SUSPEND_HOST:-}"
  WOL_SUSPEND_IF="${SUSPEND_IF:-}"
  WOL_IDLE_TIMEOUT="${IDLE_TIMEOUT:-900}"
  WOL_GRACE_AFTER_WOL="${GRACE_AFTER_WOL:-300}"
  WOL_TCP_PORTS="${TCP_PORTS:-}"
  WOL_LAN_SUBNET="${LAN_SUBNET:-}"
  WOL_EXTRA_LOCAL_B64="${EXTRA_LOCAL_CMD_B64:-}"
  WOL_EXTRA_REMOTE_B64="${EXTRA_REMOTE_CMD_B64:-}"
  WOL_SSHOPTS="-i ${WOL_SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2"
  WOL_PINGFILE="/tmp/wol-${WOL_NAME}-last-ping"
  WOL_LAST_WOL_FILE="/tmp/wol-${WOL_NAME}-last-wol"
  # Dots in FQDN patterns are literals, not regex wildcards.
  WOL_WAKE_RE="$(echo "${WOL_WAKE_PATTERNS}" | sed 's/\./\\./g')"
  return 0
}

# Block until the target config, the SSH key and (for tail mode) the access
# log exist. Survives arbitrarily late /symbios unlocks after reboot.
function f_wol_wait_ready {
  local f_need_log="$1"
  while true
  do
    if f_wol_load_conf "${WOL_NAME}"
    then
      if [[ -n "${WOL_SSH_KEY}" ]] && [[ -r "${WOL_SSH_KEY}" ]]
      then
        if [[ "${f_need_log}" != "log" || -r "${WOL_LOG_PATH}" ]]
        then
          return 0
        fi
      fi
    fi
    sleep 60
  done
}

# Send a magic packet and stamp the wake time (grace period source).
function f_wol_send {
  wakeonlan -i 255.255.255.255 "${WOL_WAKE_MAC}" &>/dev/null
  echo "${EPOCHSECONDS}" > "${WOL_LAST_WOL_FILE}"
}

# Check helpers for the idle evaluation. Each prints a human reason to
# stdout and returns 0 when the target counts as BUSY (do not suspend),
# 1 when the check passes (may suspend).
function f_wol_check_log_idle {
  local f_last
  f_last="$(grep -a -E "${WOL_WAKE_RE}" "${WOL_LOG_PATH}" 2>/dev/null | grep -v '"RequestPath":"/"' | tail -1 | sed 's/.*"StartLocal":"\([^"]*\)".*/\1/')"
  local f_idle
  if [[ -n "${f_last}" ]]
  then
    local f_epoch
    f_epoch="$(date -d "$(echo "${f_last}" | sed 's/T/ /; s/+.*//')" +%s 2>/dev/null)"
    if [[ -n "${f_epoch}" ]]
    then
      f_idle=$(( EPOCHSECONDS - f_epoch ))
    else
      f_idle=$(( WOL_IDLE_TIMEOUT + 1 ))
    fi
  else
    f_idle=$(( WOL_IDLE_TIMEOUT + 1 ))
  fi
  if [[ "${f_idle}" -lt "${WOL_IDLE_TIMEOUT}" ]]
  then
    echo "recent request ${f_idle}s ago (< ${WOL_IDLE_TIMEOUT}s)"
    return 0
  fi
  echo "no request for ${f_idle}s"
  return 1
}

function f_wol_check_ping {
  if ping -c1 -W2 "${WOL_SUSPEND_HOST}" &>/dev/null
  then
    echo "target pingable"
    return 1
  fi
  echo "target not pingable (already down)"
  return 0
}

function f_wol_check_grace {
  if [[ -f "${WOL_LAST_WOL_FILE}" ]]
  then
    local f_age=$(( EPOCHSECONDS - $(cat "${WOL_LAST_WOL_FILE}") ))
    if [[ "${f_age}" -lt "${WOL_GRACE_AFTER_WOL}" ]]
    then
      echo "woke ${f_age}s ago (< ${WOL_GRACE_AFTER_WOL}s grace)"
      return 0
    fi
  fi
  echo "no grace period active"
  return 1
}

function f_wol_check_tcp {
  if [[ -z "${WOL_TCP_PORTS}" ]]
  then
    echo "no TCP ports configured"
    return 1
  fi
  if ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" "ss -tn" 2>/dev/null | grep -qE "^ESTAB .*:(${WOL_TCP_PORTS})\\b"
  then
    echo "active TCP connection to monitored ports"
    return 0
  fi
  echo "no active TCP connections to monitored ports"
  return 1
}

function f_wol_check_extra_local {
  if [[ -z "${WOL_EXTRA_LOCAL_B64}" ]]
  then
    echo "no extra local check"
    return 1
  fi
  local f_cmd
  f_cmd="$(echo "${WOL_EXTRA_LOCAL_B64}" | base64 -d 2>/dev/null)"
  if [[ -z "${f_cmd}" ]]
  then
    echo "extra local check undecodable"
    return 1
  fi
  if bash -c "${f_cmd}" &>/dev/null
  then
    echo "extra local check reports busy"
    return 0
  fi
  echo "extra local check clear"
  return 1
}

function f_wol_check_extra_remote {
  if [[ -z "${WOL_EXTRA_REMOTE_B64}" ]]
  then
    echo "no extra remote check"
    return 1
  fi
  local f_cmd
  f_cmd="$(echo "${WOL_EXTRA_REMOTE_B64}" | base64 -d 2>/dev/null)"
  if [[ -z "${f_cmd}" ]]
  then
    echo "extra remote check undecodable"
    return 1
  fi
  if ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" "${f_cmd}" &>/dev/null
  then
    echo "extra remote check reports busy"
    return 0
  fi
  echo "extra remote check clear"
  return 1
}

function f_wol_check_nosuspend {
  if [[ -s /tmp/no-suspend ]]
  then
    echo "local /tmp/no-suspend is set"
    return 0
  fi
  if ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" '[[ -s /tmp/no-suspend ]]' &>/dev/null
  then
    echo "remote /tmp/no-suspend is set"
    return 0
  fi
  echo "no suspend block flag"
  return 1
}

function f_wol_check_ssh_sessions {
  if [[ -z "${WOL_LAN_SUBNET}" ]]
  then
    echo "no LAN subnet configured"
    return 1
  fi
  local f_count
  f_count="$(ssh ${WOL_SSHOPTS} "root@${WOL_SUSPEND_HOST}" "who" 2>/dev/null | grep -c "${WOL_LAN_SUBNET}" || true)"
  if [[ "${f_count}" -ge 1 ]]
  then
    echo "${f_count} interactive SSH session(s) from LAN"
    return 0
  fi
  echo "no interactive SSH sessions"
  return 1
}
