import os
import sys
import shlex
import threading
import time
import logging

logger = logging.getLogger(__name__)

SSH_KEY_PATH = '/config/.ssh/id_symbios'
SSH_HOST = 'host.docker.internal'
SSH_USER = 'root'
SSH_PORT = 22
SSH_CONNECT_TIMEOUT = 15
# Pinned host keys for the exec gateway. The file is seeded by
# base-services/symbios-ui.yml; missing/changed keys are rejected (fail-closed).
SSH_KNOWN_HOSTS = '/config/.ssh/known_hosts'

# The webui's SSH key is a normal root key (no command= restriction): trusted
# admins operate the host. Every command is sent to the trivial executor
# symbios-exec.sh, which audit-logs and runs it. The host key is still pinned
# (fail-closed). Commands are shell-quoted so the remote shell does not
# interpret metacharacters (|, ;, &&) before the executor runs them.
SSH_GATEWAY_WRAP = 'bash /home/SymbiOS/symbios-exec.sh '

_ssh_client = None
_client_lock = threading.Lock()


def _load_key(path):
    from paramiko import Ed25519Key, RSAKey, ECDSAKey
    for key_cls in (Ed25519Key, RSAKey, ECDSAKey):
        try:
            return key_cls.from_private_key_file(path)
        except Exception:
            continue
    raise ValueError('Could not load SSH key: ' + path)


def _get_ssh_client():
    global _ssh_client
    with _client_lock:
        if _ssh_client is not None:
            try:
                transport = _ssh_client.get_transport()
                if transport and transport.is_active():
                    return _ssh_client
            except Exception:
                pass
            try:
                _ssh_client.close()
            except Exception:
                pass
            _ssh_client = None

        if not os.path.exists(SSH_KEY_PATH):
            raise FileNotFoundError(
                'SSH key not found at ' + SSH_KEY_PATH + '. '
                'SymbiOS cannot execute remote commands.'
            )

        key = _load_key(SSH_KEY_PATH)
        import paramiko
        client = paramiko.SSHClient()
        try:
            client.load_host_keys(SSH_KNOWN_HOSTS)
        except Exception:
            logger.warning(
                'No known_hosts at %s; host key verification will reject.',
                SSH_KNOWN_HOSTS,
            )
        # Reject unknown/changed host keys instead of trusting on first use.
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        client.connect(
            SSH_HOST, port=SSH_PORT, username=SSH_USER,
            pkey=key, timeout=SSH_CONNECT_TIMEOUT,
            allow_agent=False, look_for_keys=False,
        )
        _ssh_client = client
        return _ssh_client


def _wrap(cmd):
    """Quote a command so the remote shell passes it verbatim to the executor."""
    return SSH_GATEWAY_WRAP + shlex.quote(cmd)


def _exec(cmd, timeout=300):
    """Run a gateway command, returning (exit_code, stdout, stderr)."""
    client = _get_ssh_client()
    try:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            global _ssh_client
            _ssh_client = None
            client = _get_ssh_client()

        channel = client.get_transport().open_session(timeout=SSH_CONNECT_TIMEOUT)
        channel.settimeout(timeout)
        channel.exec_command(_wrap(cmd))
        exit_status = channel.recv_exit_status()
        stdout = channel.makefile('r', -1).read()
        stderr = channel.makefile_stderr('r', -1).read()
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


def run_command(cmd, timeout=300):
    rc, stdout, stderr = _exec(cmd, timeout=timeout)
    return rc == 0, stdout, stderr


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
    return (
        "ansible-playbook --connection=local "
        "--inventory /home/docker/symbios-ui/config/inventory.yml "
        "--limit localhost "
        "-e ansible_python_interpreter=/usr/bin/python3 "
        "/home/SymbiOS/" + playbook
    )


def build_action_command(playbook, action):
    """Resolve the concrete host command for an action (or the playbook run)."""
    if action == '__playbook__':
        return _playbook_command(playbook)
    return _action_command(playbook, action)


def build_log_command(playbook, unit):
    """Resolve the concrete host command that streams one log unit."""
    return _log_command(playbook, unit)


def run_service_status(playbook, name, timeout=120):
    """Run a playbook's declared `status:` command on the host.

    Returns the raw (exit_code, stdout, stderr) so the caller can classify the
    service state by exit code (0=running, 2/4=not-installed, else=stopped).
    """
    cmd = _status_command(playbook, name)
    if not cmd:
        return 1, '', 'status command not defined for ' + str(name)
    return _exec(cmd, timeout=timeout)


def stream_command(cmd, timeout=600):
    """Run a gateway command and yield ('out'|'err'|'rc', text) incrementally.

    Used by the WebUI SSE endpoint to show live output (e.g. ansible tasks as
    they execute). Blocks reading the SSH channel until the remote process ends.
    """
    import time
    global _ssh_client
    client = _get_ssh_client()
    try:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            raise RuntimeError('SSH transport not active')
        channel = transport.open_session(timeout=SSH_CONNECT_TIMEOUT)
        channel.settimeout(timeout)
        # Allocate a PTY so commands (docker compose logs, ansible-playbook, ...)
        # detect a terminal and emit ANSI colors. ansiToHtml() renders them; the
        # lone '\r' that a PTY adds is already stripped there. Without a PTY the
        # output is colorless, which is why only sources that force ANSI (traefik)
        # showed colors. This is intentionally uniform across all services.
        try:
            channel.get_pty(term='xterm', width=220, height=60)
        except Exception:
            pass
        channel.exec_command(_wrap(cmd))
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
        try:
            _ssh_client.close()
        except Exception:
            pass
        _ssh_client = None


# Cap a follow job's accumulated output so a never-ending tail cannot exhaust
# memory. Keeps the most recent ~100 KB, mirroring a live `tail` view.
_LOG_MAX_CHARS = 100000


def _trim_log(job):
    out = job.get('output', '')
    if len(out) > _LOG_MAX_CHARS:
        job['output'] = out[-_LOG_MAX_CHARS:]


def stream_log(cmd, job):
    """Run a follow command and append its output to ``job`` until stopped.

    Unlike :func:`stream_command` this keeps a reference to the SSH channel in
    ``job['channel']`` so the caller can terminate the (never-ending) follow
    stream via :func:`stop_log`. Intended for live log tails.
    """
    import time
    global _ssh_client
    client = _get_ssh_client()
    try:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            raise RuntimeError('SSH transport not active')
        channel = transport.open_session(timeout=SSH_CONNECT_TIMEOUT)
        # Allocate a PTY so commands detect a terminal and emit ANSI colors
        # (uniform across all services; ansiToHtml renders them, '\r' stripped).
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
                    _trim_log(job)
            elif channel.exit_status_ready():
                while channel.recv_ready():
                    data = channel.recv(4096)
                    if not data:
                        break
                    text = data.decode('utf-8', errors='replace')
                    with job['lock']:
                        job['output'] += text
                        _trim_log(job)
                break
            else:
                time.sleep(0.05)
    except Exception as e:
        logger.exception('SSH log stream failed: ' + cmd)
        with job['lock']:
            job['output'] += '\n[stream error] ' + str(e) + '\n'
    finally:
        try:
            channel.close()
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
