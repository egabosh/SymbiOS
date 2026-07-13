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
# base-system/symbios-ui.yml; missing/changed keys are rejected (fail-closed).
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
