#!/bin/bash

# SymbiOS - Debian-based server management platform
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

# symbios-run-detached.sh - Run a command as a detached host process whose
# output the WebUI can poll incrementally.
#
# Jobs are decoupled from the WebUI's SSH session: they run via `setsid`, so
# closing the SSH channel (browser close, WebUI restart, gunicorn worker
# recycle, container restart) can never SIGHUP the long-running command. The
# migration of /symbios to a new disk swaps the /symbios filesystem, so the
# job files live in /var/log/symbios/jobs/ on the root filesystem - never on
# /symbios itself.
#
# Usage:
#   symbios-run-detached.sh start <job-id> '<command>'
#       Reads stdin (passphrase / keys) into a 0600 input file, then starts
#       the command detached. Prints {"ok":true,"job":"<id>"} immediately.
#   symbios-run-detached.sh poll <job-id> <byte-offset>
#       Prints {"ok":true,"status":"running|done","rc":"N","size":<bytes>,
#               "output":"<new text since byte-offset>"}.
#
# Job files (created/owned by root):
#   /var/log/symbios/jobs/<id>.input   stdin payload (chmod 600, deleted on exit)
#   /var/log/symbios/jobs/<id>.log     stdout/stderr of the command
#   /var/log/symbios/jobs/<id>.done    exit code, written when the command ends
#   /var/log/symbios/jobs/<id>.pid     PID of the detached command

g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_jobs_dir="/var/log/symbios/jobs"
g_action="${1:-}"
g_job_id="${2:-}"

f_json_error() {
  printf '{"ok":false,"error":%s}\n' "$(echo "$1" | f_json_escape)"
  exit 1
}

f_json_ok() {
  printf '{"ok":true,%s}\n' "$1"
}

f_start() {
  local f_cmd="${3:-}"
  [[ -z "$g_job_id" ]] && f_json_error "No job id"
  [[ -z "$f_cmd" ]] && f_json_error "No command"

  mkdir -p "${g_jobs_dir}" 2>/dev/null || f_json_error "Cannot create ${g_jobs_dir}"
  [[ -w "${g_jobs_dir}" ]] || f_json_error "${g_jobs_dir} is not writable"

  # Capture the stdin payload (LUKS passphrase, SSH keys) before detaching.
  # Written by the WebUI's SSH call; nothing ever reaches the command line.
  rm -f "${g_jobs_dir}/${g_job_id}.input" "${g_jobs_dir}/${g_job_id}.log" \
    "${g_jobs_dir}/${g_job_id}.done" "${g_jobs_dir}/${g_job_id}.pid" 2>/dev/null || true
  cat > "${g_jobs_dir}/${g_job_id}.input" 2>/dev/null
  chmod 600 "${g_jobs_dir}/${g_job_id}.input" 2>/dev/null || true

  # Detach: new session (setsid) so the SSH channel can close without SIGHUP.
  # stdin/stdout/stderr point at the input/log files, never at the terminal.
  # The wrapper writes the exit code into the .done file once the command ends.
  # CRITICAL: redirect FDs 0/1/2 when backgrounding, not only inside the inner
  # eval. The setsid shell would otherwise inherit the SSH channel pipes from
  # the parent (symbios-exec.sh), keeping the WebUI's SSH call blocked until
  # the whole (long-running) job exits.
  #
  # The redirection only covers FDs 0-2: any other open file descriptor of the
  # SSH session (bash's temporary redirection fds, e.g. fd 8) is inherited by
  # the detached job and keeps sshd waiting for the channel, so the caller's
  # start command still blocks until the job ends. Close every FD >= 3 inside
  # the detached shell before launching the job.
  setsid bash -c '
    for f_fd in {3..255}
    do
      eval "exec ${f_fd}>&-" 2>/dev/null || true
    done
    f_rc=0
    eval "$1" < "$2" > "$3" 2>&1 || f_rc=$?
    echo "$f_rc" > "$4"
  ' _ "$f_cmd" "${g_jobs_dir}/${g_job_id}.input" \
    "${g_jobs_dir}/${g_job_id}.log" "${g_jobs_dir}/${g_job_id}.done" \
    < /dev/null > /dev/null 2>&1 &
  f_pid=$!
  echo "$f_pid" > "${g_jobs_dir}/${g_job_id}.pid"
  # Keep the parent shell alive long enough for the setsid child to start;
  # the child is in a new session so it survives the parent exiting.
  sleep 0.1

  # The input file is kept until the job ends (the command may read it
  # lazily); poll() prunes it when the .done marker appears.
  f_json_ok "\"job\":\"${g_job_id}\""
}

f_poll() {
  local f_offset="${3:-0}"
  local f_log="${g_jobs_dir}/${g_job_id}.log"
  local f_done="${g_jobs_dir}/${g_job_id}.done"
  local f_pidfile="${g_jobs_dir}/${g_job_id}.pid"
  local f_size=0 f_new="" f_status="running" f_rc="" f_pid=""

  [[ -z "$g_job_id" ]] && f_json_error "No job id"
  [[ -f "$f_log" ]] && f_size=$(wc -c < "$f_log")

  if [[ -n "$f_offset" ]] && [[ "$f_offset" -lt "$f_size" ]]
  then
    f_new=$(tail -c +$((f_offset + 1)) "$f_log")
  fi

  if [[ -f "$f_done" ]]
  then
    f_status="done"
    f_rc=$(cat "$f_done" 2>/dev/null)
    rm -f "${g_jobs_dir}/${g_job_id}.input" "${g_jobs_dir}/${g_job_id}.pid" 2>/dev/null || true
  else
    # No .done marker yet: if the recorded PID is gone, the process died
    # without writing its exit code (e.g. the host rebooted mid-job).
    f_pid=$(cat "$f_pidfile" 2>/dev/null || true)
    if [[ -n "$f_pid" ]] && ! kill -0 "$f_pid" 2>/dev/null
    then
      f_status="done"
      f_rc="127"
      echo "127" > "$f_done"
      rm -f "${g_jobs_dir}/${g_job_id}.input" 2>/dev/null || true
    fi
  fi

  printf '{"ok":true,"status":"%s","rc":"%s","size":%s,"output":%s}' \
    "$f_status" "$f_rc" "$f_size" "$(printf '%s' "$f_new" | f_json_escape)"
}

case "$g_action" in
  start)
    f_start "$@"
    ;;
  poll)
    f_poll "$@"
    ;;
  *)
    f_json_error "Usage: $0 {start|poll}"
    ;;
esac
