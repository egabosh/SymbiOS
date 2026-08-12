# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

"""Shared in-memory job registry for background command execution.

The WebUI runs a single gunicorn worker, so this dict is shared across all
requests within the process. Jobs capture live command output for the browser
to poll. Not suitable for multi-worker scaling.

Jobs are decoupled from the WebUI process and the SSH session: the command is
started on the host by scripts/symbios-run-detached.sh via `setsid`, and this
module polls the resulting log file over the SSH gateway. A WebUI restart,
gunicorn worker recycle or SSH connection drop can therefore never abort the
remote command (e.g. a long /symbios disk migration). It keeps running on the
host and writes its progress to /var/log/symbios/jobs/.
"""

import json
import shlex
import threading
import uuid

from .ssh_exec import run_command

_JOBS = {}
_JOBS_LOCK = threading.Lock()

# Host wrapper that starts commands detached and serves their log output.
# Polling is done via short SSH calls (never a long-lived channel).
DETACHED_SCRIPT = 'symbios-run-detached.sh'


def create_job(cmd, timeout=900, stdin_data=None):
    """Start a command as a background job and return its id.

    The command is executed on the host by scripts/symbios-run-detached.sh,
    detached from the SSH session, so it survives WebUI restarts, SSH drops
    and gunicorn worker recycles. A poller thread fetches the incremental
    log output from the host. Returns the job id string for the browser to
    poll via :func:`get_job_output`.

    If stdin_data is provided, it is sent to the remote command's stdin
    before the command starts (never on the command line).
    """
    job_id = uuid.uuid4().hex
    job = {'output': '', 'done': False, 'success': False, 'lock': threading.Lock(),
           'command': cmd}
    with _JOBS_LOCK:
        # Keep the job table small: drop finished jobs before adding a new one.
        for old in [k for k, v in _JOBS.items() if v['done']]:
            _JOBS.pop(old, None)
        _JOBS[job_id] = job

    start_cmd = '{} start {} {}'.format(
        DETACHED_SCRIPT, job_id, shlex.quote(cmd))
    try:
        ok, stdout, stderr = run_command(start_cmd, timeout=60,
                                         stdin_data=stdin_data)
    except Exception as e:
        ok, stderr = False, str(e)
    if not ok:
        with job['lock']:
            job['output'] = '[ERROR] Could not start detached job: {}\n'.format(stderr)
            job['done'] = True
        return job_id

    threading.Thread(target=_poll_job, args=(job, job_id), daemon=True).start()
    return job_id


def get_job_output(job_id):
    """Return (output, done, success, command) for a job, or None if unknown."""
    job = _JOBS.get(job_id)
    if job is None:
        return None
    with job['lock']:
        return job['output'], job['done'], job['success'], job['command']


def _poll_job(job, job_id):
    """Poll the host log file of a detached job, appending output as it arrives."""
    offset = 0
    consecutive_failures = 0
    while True:
        try:
            ok, stdout, stderr = run_command(
                '{} poll {} {}'.format(DETACHED_SCRIPT, job_id, offset),
                timeout=60)
            if not ok:
                raise RuntimeError(stderr or 'poll failed')
            data = json.loads(stdout)
        except Exception:
            # Transient SSH/gateway trouble: retry, but give up after a while
            # so a permanently lost host does not leak a poller thread.
            consecutive_failures += 1
            if consecutive_failures >= 20:
                with job['lock']:
                    job['output'] += '\n[ERROR] Host stopped answering; job continues on the host.\n'
                    job['done'] = True
                return
            threading.Event().wait(3)
            continue
        consecutive_failures = 0

        text = data.get('output', '')
        if text:
            with job['lock']:
                job['output'] += text
        offset = int(data.get('size', offset))

        if data.get('status') == 'done':
            rc = int(data.get('rc') or 0)
            with job['lock']:
                job['done'] = True
                job['success'] = (rc == 0)
            return
        threading.Event().wait(1)
