#!/bin/bash

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

# SymbiOS Remote Execution - pure executor + audit logger.
# The webui's SSH key is a normal root key (no command= restriction): trusted
# admins operate the host. The WebUI resolves every high-level verb into a
# concrete command and sends it (shell-quoted) over SSH; this script only
# audit-logs the invocation and runs it. The WebUI already holds the playbook
# metadata, so no host-side parsing or verb dispatch remains.
# Logging uses the gaboshlib helpers (g_logger -> syslog, g_echo_error).

# Load shared bash helpers (g_echo_error, g_logger, ...).
# Redirect to stderr so helper messages don't corrupt JSON output on stdout.
source /etc/bash/gaboshlib.include 1>&2

# Client IP for the audit trail (from the SSH connection metadata).
g_client_ip="${SSH_CONNECTION%% *}"

# The command to run is the script arguments (the webui sends it shell-quoted,
# so it arrives as a single token). Fall back to the original command if set.
g_cmd="${SSH_ORIGINAL_COMMAND:-$*}"
g_cmd="${g_cmd#*symbios-exec.sh }"

# Nothing to do -> interactive shell was requested.
if [ -z "$g_cmd" ]
then
  echo "interactive"
  exit 0
fi

# Audit every invocation: syslog and a local log file.
g_logger "client=${g_client_ip} cmd=${g_cmd}"
echo "$(date -Iseconds) client=${g_client_ip} cmd=${g_cmd}" >> /var/log/symbios-exec.log 2>/dev/null || true

# Run the command as-is.
exec bash -c "${g_cmd}"
