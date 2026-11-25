#!/bin/bash
# SymbiOS - read-only overview of active SFTP sessions and the files they hold
# open. Replaces the legacy sftp-status helper from the pre-SymbiOS share.
#
# The SFTP sshd runs inside the sftp-share container, but the host sees its
# processes and file descriptors with the real media_root paths. Filter the
# share paths from the inventory instead of hardcoding a host layout.
#
# Usage: symbios-sftp-status.sh

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Show active SFTP sessions of the sftp-share container and the files below
media_root that those sessions currently hold open. Read-only support action:
no configuration is changed and no secret is printed.

No arguments.

Options:
  -h, --help            Show this help and exit

Output: plain text sections "Connected" and "Open files"; "none" when empty.
Requires host tools ps and lsof (both installed by basics.yml).

Exit codes: 0 = ok, 1 = runtime error (container not running), 2 = usage error.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi
f_no_args "$@"

function f_sftp_status {
  local f_root f_sessions f_pids f_open

  f_root="$(f_symbios_var media_root /symbios/media)"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sftp-share
  then
    g_echo_error "SFTP container sftp-share is not running"
    return 1
  fi

  printf 'Share root: %s\n\n' "${f_root}"

  # The bracket pattern keeps the grep process itself out of the listing.
  printf 'Connected:\n'
  f_sessions="$(ps -eo user,pid,etime,args --no-headers | grep '[i]nternal-sftp')"
  if [[ -z "${f_sessions}" ]]
  then
    printf 'none\n'
  else
    printf '%s\n' "${f_sessions}"
  fi

  printf '\nOpen files:\n'
  if [[ -z "${f_sessions}" ]]
  then
    printf 'none (no active sessions)\n'
    return 0
  fi

  # lsof of the session PIDs only: a full system scan over a multi-TB share
  # is slow, and the NAME column carries the host-side media_root path.
  f_pids="$(printf '%s\n' "${f_sessions}" | awk '{print $2}' | paste -sd, -)"
  f_open="$(lsof -nP -p "${f_pids}" 2>/dev/null \
    | awk -v f_root="${f_root}" '$9 ~ "^" f_root "/" && $5 != "DIR"')"
  if [[ -z "${f_open}" ]]
  then
    printf 'none\n'
  else
    printf '%s\n' "${f_open}"
  fi
}

f_sftp_status
