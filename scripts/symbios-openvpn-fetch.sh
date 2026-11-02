#!/bin/bash
# SymbiOS - Refresh OpenVPN client tunnel configs (fetch mode) on demand.
#
# A fetch-mode tunnel pulls its config from a remote source (e.g. the router
# re-issues leaf certificates daily). The refresh must only restart the
# tunnel when the config actually changed - restarting every cron tick would
# drop the VPN link for seconds, many times a day, for nothing.
#
# This script is the single place that knows how to do that: it runs the
# tunnel's fetch command (the helper file deployed by
# base-services/openvpn-client.yml when present, otherwise the fetch_cmd
# from inventory), compares the config before and after, and then:
#   - restarts openvpn@<name> when it is active and the config changed
#   - starts openvpn@<name> when it should run (enabled) but is down
#   - does nothing otherwise
# The refresh cron in root's crontab and the WebUI "fetch" button both call
# into here, so they behave identically.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [args]

Refresh OpenVPN client tunnel configs (fetch mode) and restart the tunnel
only when the config actually changed. Invoked by the per-tunnel refresh
cron (every N minutes, see the tunnel's cron field) and by the WebUI
"fetch" button (symbios-openvpn-client.sh fetch <name>).

Commands:
  run <name>          Fetch the config of one fetch-mode tunnel and apply
                      it: restart openvpn@<name> when active and changed,
                      start it when enabled but down, otherwise no-op.
                      A per-tunnel lock skips a tick when the previous
                      fetch is still running (slow source). The fetch
                      itself is bounded by a 2 minute timeout.
  list                Print the names of all fetch-mode tunnels, one per
                      line (read from inventory).

Output: human status lines, then one machine-readable JSON line
{"ok":true,"name":"<name>","state":"changed|unchanged","action":"restarted|started|none"}.

Exit codes:
  0  ok (including "unchanged" and skipped-by-lock)
  2  validation or usage error (unknown tunnel, not fetch mode, ...)
  1  technical error (fetch command failed, inventory unreadable, ...)

Examples:
  $(basename "$0") run homeassistant-iot
  $(basename "$0") list
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Encrypted tunnel config directory (0700, on the LUKS volume).
g_ovpn_dir="${g_base_services_root}/openvpn"

# Check that a tunnel name is safe for use in paths and unit names.
function f_valid_name {
  local f_name="$1"
  [[ -n "${f_name}" ]] && [[ "${f_name}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Hash of the tunnel config openvpn would read (empty when none exists yet).
# The encrypted volume is the source of truth; /etc/openvpn is its bind.
function f_conf_hash {
  local f_name="$1"
  local f_path
  for f_path in "${g_ovpn_dir}/${f_name}.conf" "/etc/openvpn/${f_name}.conf"
  do
    if [[ -s "${f_path}" ]]
    then
      sha256sum "${f_path}" | awk '{print $1}'
      return 0
    fi
  done
  echo ""
}

# Read the JSON entry of one tunnel from inventory (empty when missing).
# All inventory access goes through the single host-side YAML reader.
function f_tunnel_entry {
  local f_name="$1"
  "${g_symbios_dir}/symbios-inventory.py" \
    --inventory "${g_inventory}" dict-get openvpn_clients "${f_name}" 2>/dev/null || echo ""
}

# Read one string field of a tunnel entry (empty when missing).
function f_tunnel_field {
  local f_name="$1"
  local f_field="$2"
  local f_entry
  f_entry="$(f_tunnel_entry "${f_name}")"
  [[ -n "${f_entry}" ]] || return 0
  f_json_get "${f_entry}" "${f_field}"
}

# Is the tunnel supposed to run at all (enabled flag in inventory)?
function f_tunnel_enabled {
  local f_name="$1"
  local f_entry
  f_entry="$(f_tunnel_entry "${f_name}")"
  [[ -n "${f_entry}" ]] || return 0
  [[ "${f_entry}" =~ \"enabled\"[[:space:]]*:[[:space:]]*true ]]
}

# Bind-mount the encrypted config into /etc/openvpn (no-op when done).
# A bind mount is bound to the source inode: a fetch that replaces the file
# (mv) leaves a stale mount, so re-bind when the inodes differ. Returns 1
# when no config exists (e.g. data volume not mounted).
function f_ensure_bind {
  local f_name="$1"
  local f_src="${g_ovpn_dir}/${f_name}.conf"
  local f_dst="/etc/openvpn/${f_name}.conf"
  [[ -f "${f_src}" ]] || return 1
  if mountpoint -q "${f_dst}" 2>/dev/null
  then
    if [[ "$(stat -c %i "${f_src}" 2>/dev/null)" == "$(stat -c %i "${f_dst}" 2>/dev/null)" ]]
    then
      return 0
    fi
    umount "${f_dst}" 2>/dev/null || return 1
  fi
  mkdir -p /etc/openvpn 2>/dev/null || return 1
  touch "${f_dst}" 2>/dev/null || return 1
  chmod 600 "${f_dst}" 2>/dev/null || true
  mount --bind "${f_src}" "${f_dst}" 2>/dev/null
}

# Execute the tunnel's fetch: the helper file deployed by the playbook wins
# (it is regenerated on every save), the inventory fetch_cmd is the fallback.
function f_run_fetch {
  local f_name="$1"
  local f_helper="${g_ovpn_dir}/fetch-${f_name}.sh"
  if [[ -x "${f_helper}" ]]
  then
    timeout -k 10 120 bash "${f_helper}"
  else
    local f_cmd
    f_cmd="$(f_tunnel_field "${f_name}" fetch_cmd)"
    [[ -n "${f_cmd}" ]] || return 1
    # shellcheck disable=SC2086
    timeout -k 10 120 bash -c "${f_cmd}"
  fi
}

g_cmd="${1:-run}"

case "${g_cmd}" in
  list)
    # Names of all fetch-mode tunnels, straight from inventory (one per line).
    g_names="$( "${g_symbios_dir}/symbios-inventory.py" \
      --inventory "${g_inventory}" dict-keys openvpn_clients 2>/dev/null )" || exit 0
    while IFS= read -r g_name
    do
      [[ -n "${g_name}" ]] || continue
      if [[ "$(f_tunnel_field "${g_name}" mode)" == "fetch" ]]
      then
        echo "${g_name}"
      fi
    done <<< "${g_names}"
    exit 0
    ;;
  run)
    g_name="${2:-}"
    if ! f_valid_name "${g_name}"
    then
      g_echo_error "Invalid tunnel name: ${g_name}"
      exit 2
    fi

    # The tunnel must exist in inventory and be a fetch-mode tunnel.
    g_mode="$(f_tunnel_field "${g_name}" mode)"
    if [[ -z "${g_mode}" ]]
    then
      g_echo_error "Unknown tunnel: ${g_name} (not in inventory openvpn_clients)"
      exit 2
    fi
    if [[ "${g_mode}" != "fetch" ]]
    then
      g_echo_error "Tunnel ${g_name} is not in fetch mode (mode=${g_mode})"
      exit 2
    fi

    # Per-tunnel lock: a slow source must never pile up overlapping fetches.
    # Not g_lockfile (that locks the whole script and would serialize
    # unrelated tunnels); flock on an fd keeps this to one tunnel at a time.
    g_lock="/tmp/symbios-openvpn-fetch-${g_name}.lock"
    exec 9>"${g_lock}" || { g_echo_error "Cannot open lock file: ${g_lock}"; exit 1; }
    if ! flock -n 9
    then
      # Previous tick still running - skip quietly, the next tick retries.
      printf '{"ok":true,"name":"%s","state":"skipped","action":"none"}\n' "${g_name}"
      exit 0
    fi

    # Config hash before the fetch (empty when no config exists yet).
    g_hash_before="$(f_conf_hash "${g_name}")"

    if ! f_run_fetch "${g_name}"
    then
      # Keep the old config, do not touch the running tunnel.
      g_echo_error "Fetch failed for tunnel ${g_name} - keeping current config"
      printf '{"ok":false,"name":"%s","state":"error","action":"none"}\n' "${g_name}"
      exit 1
    fi

    # Config hash after the fetch - only a real difference matters.
    g_hash_after="$(f_conf_hash "${g_name}")"
    if [[ "${g_hash_before}" == "${g_hash_after}" ]]
    then
      g_state="unchanged"
    else
      g_state="changed"
    fi

    # Apply the result: an active tunnel picks up new material on restart;
    # a tunnel that should run but is down gets started (also the watchdog
    # for enabled tunnels stopped out of band); disabled ones stay down.
    g_action="none"
    if systemctl is-active "openvpn@${g_name}" >/dev/null 2>&1
    then
      if [[ "${g_state}" == "changed" ]]
      then
        # Re-bind the (possibly rewritten) config before the restart.
        f_ensure_bind "${g_name}" || true
        if systemctl restart "openvpn@${g_name}" 2>/dev/null
        then
          g_action="restarted"
        else
          g_echo_error "Restart of openvpn@${g_name} failed"
          printf '{"ok":false,"name":"%s","state":"%s","action":"none"}\n' "${g_name}" "${g_state}"
          exit 1
        fi
      fi
    elif [[ "$(f_tunnel_enabled "${g_name}")" == "true" ]] && [[ -s "${g_ovpn_dir}/${g_name}.conf" || -s "/etc/openvpn/${g_name}.conf" ]]
    then
      # The unit reads /etc/openvpn/<name>.conf - bind it first.
      f_ensure_bind "${g_name}" || true
      if systemctl start "openvpn@${g_name}" 2>/dev/null
      then
        g_action="started"
      else
        g_echo_error "Start of openvpn@${g_name} failed"
        printf '{"ok":false,"name":"%s","state":"%s","action":"none"}\n' "${g_name}" "${g_state}"
        exit 1
      fi
    fi

    if [[ "${g_action}" == "none" && "${g_state}" == "unchanged" ]]
    then
      g_echo "Tunnel ${g_name}: config unchanged, nothing to do"
    elif [[ "${g_action}" == "restarted" ]]
    then
      g_echo "Tunnel ${g_name}: config changed, tunnel restarted"
    elif [[ "${g_action}" == "started" ]]
    then
      g_echo "Tunnel ${g_name}: tunnel was down, started it"
    else
      g_echo "Tunnel ${g_name}: config changed but tunnel is disabled, left it down"
    fi

    # Machine-readable result as the final line (cron logs, WebUI modal).
    printf '{"ok":true,"name":"%s","state":"%s","action":"%s"}\n' "${g_name}" "${g_state}" "${g_action}"
    exit 0
    ;;
  *)
    g_echo_error "Unknown command: ${g_cmd}"
    f_usage >&2
    exit 2
    ;;
esac
