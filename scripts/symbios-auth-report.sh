#!/bin/bash
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# symbios-auth-report.sh - Central auth-failure reporter for SymbiOS.
#
# fail2ban calls this from its report-only action, the auth healthchecks call
# it with --audit-only. Both paths write to the single audit trail; only the
# fail2ban path sends a notification, because the healthchecks already have
# their own flap-protected notify path in runchecks.sh. No firewall action,
# no secrets and no raw log lines are ever passed on.
#
# Deployed twice: in git/scripts (runchecks PATH) and as a real rootfs copy at
# /usr/local/sbin/symbios-auth-report.sh for fail2ban, which is boot-enabled
# and must not depend on the /symbios mount being present.

g_script_name="$(basename "$0")"

if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi

# Minimal fallback for the boot phase before gaboshlib is available.
if ! command -v g_echo_note >/dev/null 2>&1
then
  function g_echo_note {
    printf 'NOTE: %s\n' "$*"
  }
  function g_echo_warn {
    printf 'WARN: %s\n' "$*" >&2
  }
fi

function f_usage {
  cat << EOF
Usage: ${g_script_name} [--audit-only] <source> <ip> <failures> [user]

Report an authentication failure pattern to the central audit trail and,
unless --audit-only is given, to the configured notification targets.

Arguments:
  source        Jail or check name, e.g. sshd, sftp-auth, traefik-auth
  ip            Offending address, or '-' when several sources are involved
  failures      Number of failed attempts in the detection window
  user          Optional account name (sanitized before it is recorded)

Options:
  --audit-only  Write the audit event only; the caller notifies (healthchecks)
  -h, --help    Show this help and exit

Output: one short status line. Exit codes: 0 ok, 2 usage error. No credentials,
tokens, cookies or complete log lines are ever accepted or emitted.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

f_audit_only=0
if [[ "${1:-}" == "--audit-only" ]]
then
  f_audit_only=1
  shift
fi
if [[ $# -lt 3 || $# -gt 4 ]]
then
  f_usage >&2
  exit 2
fi

f_source="$1"
f_ip="$2"
f_failures="$3"
f_user="${4:--}"

# Strict validation: at least one arg is always attacker-controlled (fail2ban
# passes the log match, the check passes parsed log fields).
if [[ ! "$f_source" =~ ^[A-Za-z0-9_-]+$ ]] \
  || [[ ! "$f_ip" =~ ^[0-9A-Fa-f:.-]+$ ]] \
  || [[ ! "$f_failures" =~ ^[0-9]+$ ]]
then
  f_usage >&2
  exit 2
fi
f_user="${f_user//[^A-Za-z0-9._@-]/_}"
[[ -n "$f_user" ]] || f_user="-"
f_detail="source=${f_source} ip=${f_ip} failures=${f_failures} user=${f_user}"

# symbios-lib.sh owns the audit path and the audit helper. It may be missing
# before the data volume is mounted; then syslog and notify still work.
f_lib=""
if command -v symbios-lib.sh >/dev/null 2>&1
then
  f_lib="$(command -v symbios-lib.sh)"
elif [[ -r /symbios/git/SymbiOS/scripts/symbios-lib.sh ]]
then
  f_lib="/symbios/git/SymbiOS/scripts/symbios-lib.sh"
fi
if [[ -n "$f_lib" ]]
then
  # shellcheck source=/dev/null
  . "$f_lib"
fi

if declare -F f_audit_event >/dev/null 2>&1
then
  f_audit_event security auth-failure "$f_detail"
else
  g_echo_warn "audit helper unavailable - auth event is only logged"
fi
logger -t symbios-auth "$f_detail"

# Notification suppression is per source and address, 15 minutes. /run is
# rootfs-local and cleared on boot, so no state below /symbios is needed.
if [[ "$f_audit_only" -eq 0 && -x /usr/local/bin/notify.sh ]]
then
  f_state_dir="/run/symbios-auth-report"
  mkdir -p "$f_state_dir"
  chmod 0700 "$f_state_dir"
  # fd 8 is used because gaboshlib reserves fd 9 for its stderr colour trap.
  exec 8>"${f_state_dir}/lock"
  flock -x 8
  f_key="${f_source}_${f_ip}"
  f_key="${f_key//[^A-Za-z0-9_.-]/_}"
  f_state="${f_state_dir}/${f_key}"
  f_now=$(date +%s)
  f_last=0
  [[ -r "$f_state" ]] && f_last="$(<"$f_state")"
  [[ "$f_last" =~ ^[0-9]+$ ]] || f_last=0
  if (( f_now - f_last >= 900 ))
  then
    printf '%s\n' "Auth failure pattern: ${f_detail}" \
      | /usr/local/bin/notify.sh -s "Auth alert: ${f_source} from ${f_ip}" >/dev/null 2>&1 || true
    printf '%s' "$f_now" > "$f_state"
  fi
  flock -u 8
fi

g_echo_note "auth event recorded: ${f_detail}"
