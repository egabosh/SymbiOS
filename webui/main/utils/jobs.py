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
"""

import threading
import uuid
from .ssh_exec import stream_command

_JOBS = {}
_JOBS_LOCK = threading.Lock()


def create_job(cmd, timeout=900):
    """Start a command as a background job and return its id.

    The command is executed via the SSH exec gateway; output is captured
    incrementally. Returns the job id string for the browser to poll via
    :func:`get_job_output`.
    """
    job_id = uuid.uuid4().hex
    job = {'output': '', 'done': False, 'success': False, 'lock': threading.Lock()}
    with _JOBS_LOCK:
        # Keep the job table small: drop finished jobs before adding a new one.
        for old in [k for k, v in _JOBS.items() if v['done']]:
            _JOBS.pop(old, None)
        _JOBS[job_id] = job
    threading.Thread(target=_run_job, args=(job, cmd), daemon=True).start()
    return job_id


def get_job_output(job_id):
    """Return (output, done, success) for a job, or None if unknown."""
    job = _JOBS.get(job_id)
    if job is None:
        return None
    with job['lock']:
        return job['output'], job['done'], job['success']


def _run_job(job, cmd):
    """Run a command via the SSH exec gateway, appending output as it arrives."""
    overall_ok = True
    try:
        for kind, text in stream_command(cmd, timeout=900):
            if kind == 'rc':
                if text != 0:
                    overall_ok = False
                continue
            with job['lock']:
                job['output'] += text
    except Exception as e:
        overall_ok = False
        with job['lock']:
            job['output'] += '\n[ERROR] ' + str(e) + '\n'
    with job['lock']:
        job['done'] = True
        job['success'] = overall_ok
