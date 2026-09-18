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

import os
import shlex
import threading
import logging

import paramiko

logger = logging.getLogger(__name__)

SSH_KEY_PATH = '/config/.ssh/id_symbios'
SSH_HOST = '192.168.41.1'
SSH_USER = 'root'
SSH_PORT = 33
SSH_CONNECT_TIMEOUT = 15
# Pinned host keys for the exec gateway. The file is seeded by
# base-services/symbios-ui.yml; missing/changed keys are rejected (fail-closed).
SSH_KNOWN_HOSTS = '/config/.ssh/known_hosts'

# The webui's SSH key is a normal root key (no command= restriction): trusted
# admins operate the host. Every command is sent to the trivial executor
# symbios-exec.sh, which audit-logs and runs it. The host key is still pinned
# (fail-closed). Commands are shell-quoted so the remote shell does not
# interpret metacharacters (|, ;, &&) before the executor runs them.
SSH_GATEWAY_WRAP = 'bash /symbios/git/SymbiOS/scripts/symbios-exec.sh '

_ssh_client = None
_client_lock = threading.Lock()


class _FingerprintPolicy(paramiko.MissingHostKeyPolicy):
    """Accept host if its key fingerprint matches any entry in known_hosts.

    This avoids hostname/IP mismatches when the container's default gateway
    changes (e.g. Docker network recreation).
    """

    def __init__(self, known_hosts_path):
        self._fingerprints = set()
        if not os.path.exists(known_hosts_path):
            return
        from paramiko import HostKeys
        hk = HostKeys(known_hosts_path)
        for _hostname, keys in hk.items():
            for key_type, key in keys.items():
                self._fingerprints.add(key.get_fingerprint().hex())

    def missing_host_key(self, client, hostname, key):
        fp = key.get_fingerprint().hex()
        if fp in self._fingerprints:
            return
        raise paramiko.SSHException(
            'Host key {} not matching any known fingerprint'.format(hostname)
        )


def _load_key(path):
    from paramiko import Ed25519Key, RSAKey, ECDSAKey
    for key_cls in (Ed25519Key, RSAKey, ECDSAKey):
        try:
            return key_cls.from_private_key_file(path)
        except Exception:
            continue
    raise ValueError('Could not load SSH key: ' + path)


def _connect_client():
    """Open a fresh, independent SSH client (no lock, no cache)."""
    if not os.path.exists(SSH_KEY_PATH):
        raise FileNotFoundError(
            'SSH key not found at ' + SSH_KEY_PATH + '. '
            'SymbiOS cannot execute remote commands.'
        )

    key = _load_key(SSH_KEY_PATH)
    client = paramiko.SSHClient()
    try:
        client.load_host_keys(SSH_KNOWN_HOSTS)
    except Exception:
        logger.warning(
            'No known_hosts at %s; host key verification will reject.',
            SSH_KNOWN_HOSTS,
        )
    # Reject unknown/changed host keys instead of trusting on first use.
    # _FingerprintPolicy matches by key fingerprint, not hostname/IP.
    client.set_missing_host_key_policy(
        _FingerprintPolicy(SSH_KNOWN_HOSTS))
    client.connect(
        SSH_HOST, port=SSH_PORT, username=SSH_USER,
        pkey=key, timeout=SSH_CONNECT_TIMEOUT,
        allow_agent=False, look_for_keys=False,
    )
    return client


def _get_ssh_client_locked():
    """Return the shared client; expects ``_client_lock`` to be held.

    The lock serializes every use of the shared transport. Paramiko transports
    are not thread-safe: with uvicorn running sync views in a thread pool,
    concurrent requests sharing one transport corrupt it ("Socket is closed").
    Streams (downloads/SSE/log tails) therefore use their OWN dedicated
    connection via :func:`_connect_client` instead of this shared one.
    """
    global _ssh_client
    if _ssh_client is not None:
        try:
            transport = _ssh_client.get_transport()
            if transport and transport.is_active():
                # is_active() only checks a flag, not socket health.
                # Send an SSH ignore packet to verify the connection is
                # actually alive; a dead socket raises OSError/EOFError.
                transport.send_ignore()
                return _ssh_client
        except Exception:
            pass
        try:
            _ssh_client.close()
        except Exception:
            pass
        _ssh_client = None
    _ssh_client = _connect_client()
    return _ssh_client


def _wrap(cmd):
    """Quote a command so the remote shell passes it verbatim to the executor."""
    return SSH_GATEWAY_WRAP + shlex.quote(cmd)


def _exec(cmd, timeout=300, stdin_data=None):
    """Run a gateway command, returning (exit_code, stdout, stderr).

    If *stdin_data* is provided it is written to the remote process's stdin
    before reading stdout/stderr (useful for piping data to scripts).

    The whole channel lifecycle runs under ``_client_lock``: the shared
    paramiko transport is unsafe for concurrent channel use (uvicorn runs sync
    views in a thread pool), so every short command is serialized.
    """
    global _ssh_client
    with _client_lock:
        try:
            client = _get_ssh_client_locked()
            transport = client.get_transport()
            if not transport or not transport.is_active():
                _ssh_client = None
                client = _get_ssh_client_locked()

            channel = client.get_transport().open_session(timeout=SSH_CONNECT_TIMEOUT)
            channel.settimeout(timeout)
            try:
                channel.exec_command(_wrap(cmd))
                # Write stdin data if provided (e.g. SSH keys for
                # write-authorized-keys.sh). Small payloads; closing the single
                # writer signals EOF so the remote process can proceed.
                if stdin_data is not None:
                    writer = channel.makefile('w')
                    writer.write(stdin_data)
                    writer.close()
                # Always signal EOF on stdin: scripts like symbios-run-detached.sh
                # start read stdin (`cat > .input`) until EOF, and a still-open
                # channel would block them until the command timeout.
                channel.shutdown_write()
                exit_status = channel.recv_exit_status()
                stdout = channel.makefile('r', -1).read()
                stderr = channel.makefile_stderr('r', -1).read()
            finally:
                # Explicitly close the channel: without this, channels linger on
                # the shared transport until GC and pile up against sshd's
                # MaxSessions limit once pages poll frequently.
                try:
                    channel.close()
                except Exception:
                    pass
            if isinstance(stdout, bytes):
                stdout = stdout.decode('utf-8', errors='replace')
            if isinstance(stderr, bytes):
                stderr = stderr.decode('utf-8', errors='replace')
            return exit_status, stdout, stderr
        except Exception as e:
            logger.exception('SSH command failed: ' + cmd)
            try:
                _ssh_client.close()
            except Exception:
                pass
            _ssh_client = None
            return -1, '', str(e)


def run_command(cmd, timeout=300, stdin_data=None):
    rc, stdout, stderr = _exec(cmd, timeout=timeout, stdin_data=stdin_data)
    return rc == 0, stdout, stderr


def run_command_bytes(cmd, timeout=300):
    """Like :func:`run_command` but returns stdout as raw bytes.

    Used for binary payload transfers that must not be force-decoded as UTF-8.
    Mirrors ``_exec`` but skips the text decoding.
    """
    global _ssh_client
    with _client_lock:
        try:
            client = _get_ssh_client_locked()
            transport = client.get_transport()
            if not transport or not transport.is_active():
                _ssh_client = None
                client = _get_ssh_client_locked()
            channel = client.get_transport().open_session(timeout=SSH_CONNECT_TIMEOUT)
            channel.settimeout(timeout)
            try:
                channel.exec_command(_wrap(cmd))
                channel.shutdown_write()
                channel.recv_exit_status()
                stdout = channel.makefile('r', -1).read()
                stderr = channel.makefile_stderr('r', -1).read()
            finally:
                try:
                    channel.close()
                except Exception:
                    pass
            if isinstance(stdout, str):
                stdout = stdout.encode('utf-8', errors='replace')
            if isinstance(stderr, bytes):
                stderr = stderr.decode('utf-8', errors='replace')
            return 0, stdout, stderr
        except Exception as e:
            logger.exception('SSH bytes command failed: ' + cmd)
            try:
                _ssh_client.close()
            except Exception:
                pass
            _ssh_client = None
            return -1, b'', str(e)


class _SSHStream:
    """Incremental SSH gateway command result (chunked binary streaming).

    Iterating over the object yields stdout byte blocks as they arrive over the
    SSH channel, so a download is never buffered in full inside the WebUI
    container - its memory footprint stays bounded by *chunk_size*. After the
    generator is exhausted the channel is closed and ``exit_status``/``stderr``/
    ``error`` are populated on this object. A cancelled/failed iteration also
    closes the channel and resets the shared client.
    """

    def __init__(self, cmd, timeout, chunk_size):
        self.cmd = cmd
        self.timeout = timeout
        self.chunk_size = chunk_size
        self.exit_status = None
        self.stderr = ''
        self.error = None

    def __iter__(self):
        # A download stream gets its own dedicated connection: it runs for a
        # long time and must not block (or race) the shared client serialized
        # under _client_lock for short control commands.
        client = None
        channel = None
        try:
            client = _connect_client()
            transport = client.get_transport()
            channel = transport.open_session(timeout=SSH_CONNECT_TIMEOUT)
            channel.settimeout(self.timeout)
            channel.exec_command(_wrap(self.cmd))
            channel.shutdown_write()
            while True:
                block = channel.recv(self.chunk_size)
                if not block:
                    break
                yield block
            stderr_b = channel.recv_stderr(1 << 20)
            self.exit_status = channel.recv_exit_status()
            if isinstance(stderr_b, bytes):
                stderr_b = stderr_b.decode('utf-8', errors='replace')
            self.stderr = stderr_b
        except Exception as e:
            logger.exception('SSH stream command failed: ' + self.cmd)
            self.error = str(e)
        finally:
            if channel is not None:
                try:
                    channel.close()
                except Exception:
                    pass
            if client is not None:
                try:
                    client.close()
                except Exception:
                    pass


def run_command_bytes_stream(cmd, timeout=900, chunk_size=65536):
    """Run a gateway command, streaming stdout as binary chunks.

    Used for file downloads whose size is only bounded by the host disk:
    stdout is drained from the SSH channel in ``chunk_size`` blocks instead of
    being buffered in full (unlike :func:`run_command_bytes`). The returned
    object is iterable; once exhausted, its ``exit_status``/``stderr``/``error``
    attributes describe the remote execution.
    """
    return _SSHStream(cmd, timeout, chunk_size)


def run_playbook(playbook, timeout=300):
    """Run a service's Ansible playbook on the host (idempotent install)."""
    cmd = build_action_command(playbook, '__playbook__')
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


# ---------------------------------------------------------------------------
# Command resolution from the local playbook catalog.
# The WebUI parses the '# docs:' blocks itself, so only concrete commands are
# shipped to the host executor (no host-side verb dispatch remains).
# ---------------------------------------------------------------------------

def _item(playbook):
    from ..playbook_catalog import get_playbook
    return get_playbook(playbook)


def _status_command(playbook, name):
    item = _item(playbook)
    if not item:
        return None
    services = (item['docs'].get('service_control', {}) or {}).get('services', []) or []
    for s in services:
        if s.get('name') == name:
            return s.get('status')
    return None


def _action_command(playbook, action):
    item = _item(playbook)
    if not item:
        return None
    return (item['docs'].get('actions') or {}).get(action)


def _log_command(playbook, unit):
    item = _item(playbook)
    if not item:
        return None
    logs = (item['docs'].get('service_control', {}) or {}).get('logs', []) or []
    for l in logs:
        if l.get('name') == unit:
            return l.get('command')
    return None


def _playbook_command(playbook):
    if playbook.startswith("user-playbooks/"):
        path = "/symbios/base-services/symbios-ui/config/user-playbooks/" + playbook.split("/", 1)[-1]
    else:
        path = "/symbios/git/SymbiOS/" + playbook
    return (
        "ansible-playbook --connection=local "
        "--inventory /symbios/base-services/symbios-ui/config/inventory.yml "
        "--limit localhost "
        "-e ansible_python_interpreter=/usr/bin/python3 "
        + path
    )


def build_action_command(playbook, action):
    """Resolve the concrete host command for an action (or the playbook run)."""
    if action == '__playbook__':
        return _playbook_command(playbook)
    # The three uninstall modes are handled by symbios-uninstall.sh, which
    # reads the # docs: block via yq and deletes paths accordingly.
    if action in ('uninstall-full', 'uninstall-program', 'uninstall-reset'):
        mode = action.replace('uninstall-', '')
        return 'symbios-uninstall.sh {} {}'.format(playbook, mode)
    return _action_command(playbook, action)


def build_log_command(playbook, unit):
    """Resolve the concrete host command that streams one log unit.

    The follow command is wrapped with ``stdbuf -oL -eL`` so output is flushed
    line-by-line even when the command is piped (e.g. ``tail | grep``), which
    would otherwise block-buffer ~4 KB and only appear once the buffer fills.
    """
    cmd = _log_command(playbook, unit)
    if not cmd:
        return None
    return "stdbuf -oL -eL " + cmd


def run_service_status(playbook, name, timeout=120):
    """Run a playbook's declared `status:` command on the host.

    Returns the raw (exit_code, stdout, stderr) so the caller can classify the
    service state by exit code (0=running, 2/4=not-installed, else=stopped).
    """
    cmd = _status_command(playbook, name)
    if not cmd:
        return 1, '', 'status command not defined for ' + str(name)
    return _exec(cmd, timeout=timeout)


def stream_command(cmd, timeout=600, stdin_data=None):
    """Run a gateway command and yield ('out'|'err'|'rc', text) incrementally.

    Used by the WebUI SSE endpoint to show live output (e.g. ansible tasks as
    they execute). Blocks reading the SSH channel until the remote process ends.

    If stdin_data is provided, it is sent to the remote command's stdin
    before closing the channel.

    Runs on its own dedicated SSH connection: the stream's lifetime is
    unbounded (ansible, docker compose push, ...), so it must not be tied to
    the shared client serialized under ``_client_lock``.
    """
    import time
    channel = None
    client = None
    try:
        client = _connect_client()
        transport = client.get_transport()
        channel = transport.open_session(timeout=SSH_CONNECT_TIMEOUT)
        channel.settimeout(timeout)
        # Allocate a PTY so commands (docker compose logs, ansible-playbook, ...)
        # detect a terminal and emit ANSI colors. ansiToHtml() renders them; the
        # lone '\r' that a PTY adds is already stripped there. Without a PTY the
        # output is colorless, which is why only sources that force ANSI (traefik)
        # showed colors. This is intentionally uniform across all services.
        #
        # NEVER allocate a PTY when stdin_data is provided: a PTY enables
        # line-discipline echo, so the bytes we send to the remote process's
        # stdin (e.g. SSH keys) are echoed back into the job output immediately
        # on arrival - before the remote script's `read -s` can switch ECHO
        # off. Without a TTY the data flows straight to the process and can
        # never be echoed.
        if not stdin_data:
            try:
                channel.get_pty(term='xterm', width=220, height=60)
            except Exception:
                pass
        channel.exec_command(_wrap(cmd))
        # Send stdin data if provided, then close stdin
        if stdin_data:
            channel.sendall(stdin_data.encode('utf-8'))
            channel.shutdown_write()
        while True:
            if channel.recv_ready():
                data = channel.recv(4096)
                if data:
                    yield ('out', data.decode('utf-8', errors='replace'))
            if channel.recv_stderr_ready():
                data = channel.recv_stderr(4096)
                if data:
                    yield ('err', data.decode('utf-8', errors='replace'))
            if channel.exit_status_ready():
                while channel.recv_ready():
                    data = channel.recv(4096)
                    if data:
                        yield ('out', data.decode('utf-8', errors='replace'))
                while channel.recv_stderr_ready():
                    data = channel.recv_stderr(4096)
                    if data:
                        yield ('err', data.decode('utf-8', errors='replace'))
                break
            time.sleep(0.02)
        yield ('rc', channel.recv_exit_status())
    except Exception as e:
        logger.exception('SSH stream failed: ' + cmd)
        yield ('err', str(e))
        yield ('rc', 1)
    finally:
        if channel is not None:
            try:
                channel.close()
            except Exception:
                pass
        if client is not None:
            try:
                client.close()
            except Exception:
                pass


# Cap a follow job's accumulated output so a never-ending tail cannot exhaust
# memory. Keeps the most recent ~100 KB, mirroring a live `tail` view.
_LOG_MAX_CHARS = 100000


def _trim_log(job):
    out = job.get('output', '')
    if len(out) > _LOG_MAX_CHARS:
        dropped = len(out) - _LOG_MAX_CHARS
        job['output'] = out[-_LOG_MAX_CHARS:]
        job['dropped'] += dropped


def stream_log(cmd, job):
    """Run a follow command and append its output to ``job`` until stopped.

    Unlike :func:`stream_command` this keeps a reference to the SSH channel in
    ``job['channel']`` so the caller can terminate the (never-ending) follow
    stream via :func:`stop_log`. Intended for live log tails.

    The accumulated ``output`` is a rolling window capped at ``_LOG_MAX_CHARS``
    (so a never-ending tail cannot exhaust memory). To let the browser resume
    polling correctly after trims, we also track ``total`` (cumulative chars
    received) and ``dropped`` (chars evicted from the window). The tail endpoint
    maps the browser's absolute offset into the current window; if the browser
    fell behind past the window, it resyncs to the whole window (tail -f style).

    Works on its own dedicated SSH connection (never the shared client under
    ``_client_lock``) so a never-ending follow stays isolated from the short
    control commands the WebUI runs in parallel.
    """
    import time
    client = None
    channel = None
    try:
        client = _connect_client()
        transport = client.get_transport()
        channel = transport.open_session(timeout=SSH_CONNECT_TIMEOUT)
        # Allocate a PTY so commands (docker compose logs, etc.) detect a
        # terminal and emit ANSI colors. ansiToHtml() renders them; '\r' that
        # a PTY adds is already stripped there. Without a PTY the output is
        # colorless - this is intentionally uniform across all services.
        try:
            channel.get_pty(term='xterm', width=220, height=60)
        except Exception:
            pass
        channel.exec_command(_wrap(cmd))
        job['channel'] = channel
        while True:
            if channel.recv_ready():
                data = channel.recv(4096)
                if not data:
                    break
                text = data.decode('utf-8', errors='replace')
                with job['lock']:
                    job['output'] += text
                    job['total'] += len(text)
                    _trim_log(job)
            elif channel.exit_status_ready():
                while channel.recv_ready():
                    data = channel.recv(4096)
                    if not data:
                        break
                    text = data.decode('utf-8', errors='replace')
                    with job['lock']:
                        job['output'] += text
                        job['total'] += len(text)
                        _trim_log(job)
                break
            else:
                time.sleep(0.05)
    except Exception as e:
        logger.exception('SSH log stream failed: ' + cmd)
        with job['lock']:
            job['output'] += '\n[stream error] ' + str(e) + '\n'
            job['total'] += len(str(e)) + 18
    finally:
        if channel is not None:
            try:
                channel.close()
            except Exception:
                pass
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
        job['channel'] = None
        with job['lock']:
            job['done'] = True


def stop_log(job):
    """Terminate a follow stream started by :func:`stream_log`."""
    channel = job.get('channel')
    if channel is not None:
        try:
            channel.close()
        except Exception:
            pass
