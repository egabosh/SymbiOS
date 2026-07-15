#!/bin/bash
# SymbiOS Remote Execution - minimal audit-logging shim.
# The webui's SSH key is a normal root key (no command= restriction): trusted
# admins operate the host. Every high-level verb is resolved and executed by
# the companion helper symbios-docs.py; this script only logs the invocation
# and delegates. The helper's output is streamed straight to the SSH channel.
# Logging uses the gaboshlib helpers (g_logger -> syslog, g_echo_error).

# Load shared bash helpers (g_echo_error, g_logger, ...).
source /etc/bash/gaboshlib.include

# Client IP for the audit trail (from the SSH connection metadata).
g_client_ip="unknown"
if [ -n "$SSH_CONNECTION" ]
then
  g_client_ip="${SSH_CONNECTION%% *}"
fi

# Build the command tokens (forced command or explicit arguments).
set -f
set -- ${SSH_ORIGINAL_COMMAND:-$*}
set +f

# Nothing to do -> interactive shell was requested.
if [ -z "$1" ]
then
  echo "interactive"
  exit 0
fi

# Audit every invocation: syslog and a local log file.
g_logger "client=${g_client_ip} action=$1 cmd=$*"
echo "$(date -Iseconds) client=${g_client_ip} action=$1 cmd=$*" >> /var/log/symbios-exec.log 2>/dev/null || true

# Delegate everything to the helper.
exec python3 /home/SymbiOS/symbios-docs.py run "$@"
