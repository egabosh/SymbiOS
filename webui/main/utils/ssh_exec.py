import os
import sys
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


def run_command(cmd, timeout=300):
    client = _get_ssh_client()
    try:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            _ssh_client = None
            client = _get_ssh_client()

        channel = client.get_transport().open_session(timeout=SSH_CONNECT_TIMEOUT)
        channel.settimeout(timeout)
        channel.exec_command(cmd)
        exit_status = channel.recv_exit_status()
        stdout = channel.makefile('r', -1).read()
        stderr = channel.makefile_stderr('r', -1).read()
        if isinstance(stdout, bytes):
            stdout = stdout.decode('utf-8', errors='replace')
        if isinstance(stderr, bytes):
            stderr = stderr.decode('utf-8', errors='replace')
        return exit_status == 0, stdout, stderr
    except Exception as e:
        logger.exception('SSH command failed: ' + cmd)
        try:
            _ssh_client.close()
        except Exception:
            pass
        _ssh_client = None
        return False, '', str(e)


def run_playbook(playbook, timeout=300):
    cmd = 'playbook ' + playbook
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_docker(service_name, action, timeout=120):
    cmd = 'docker-compose ' + service_name + ' ' + action
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_systemctl(subcommand, unit, timeout=120):
    cmd = 'exec systemctl ' + subcommand + ' ' + unit
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_cron(subcommand, file, timeout=120):
    cmd = 'cron ' + subcommand + ' ' + file
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_ufw(subcommand, timeout=120):
    cmd = 'ufw ' + subcommand
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    output = stdout
    if stderr and not ok:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_service_logs(playbook, lines=200, timeout=120):
    cmd = 'service logs ' + playbook + ' ' + str(lines)
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    # Prefer stdout (the JSON payload); only fall back to stderr if empty,
    # so a stray warning on stderr can never corrupt the JSON we parse.
    if stdout and stdout.strip():
        return ok, stdout
    output = stdout
    if stderr:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


def run_service_source(playbook, timeout=60):
    """Fetch the raw playbook source for display via the exec gateway.

    Only playbooks under base-services/ or services/ are permitted by the
    gateway, so this cannot be abused to read arbitrary host files.
    """
    cmd = 'service source ' + playbook
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    if stdout and stdout.strip():
        return ok, stdout
    output = stdout
    if stderr:
        output = output + '\n--- STDERR ---\n' + stderr
    return ok, output


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
        channel.exec_command(cmd)
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
        channel.exec_command(cmd)
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
