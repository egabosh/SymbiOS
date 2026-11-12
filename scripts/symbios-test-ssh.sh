#!/bin/bash
# SymbiOS - Test SSH connectivity to a remote server

function f_usage {
  cat << EOF
Usage: $(basename "$0") <host> <port> <user> [path]

Test SSH connectivity to a remote server (used by the WebUI backup page).
It uses the same identity as the backup run itself, the host root key
(override with backup_ssh_key in inventory.yml), so a successful test
means the backup will authenticate too. Shell targets are tested with an
exec channel, SFTP-only endpoints (ForceCommand internal-sftp, e.g. the
SymbiOS sftp-share) with an SFTP batch. Output: JSON with ok/message
or error.

Arguments:
  host      remote host (hostname or IP)
  port      SSH port (default: 22 when empty)
  user      SSH user (default: root)
  path      optional remote path to test (SFTP read test)

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Output: JSON with ok, message/error

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_host="${1:-}"
g_port="${2:-22}"
g_user="${3:-root}"
g_path="${4:-}"
g_key="$(f_symbios_var backup_ssh_key "/root/.ssh/id_ed25519")"

if [[ -z "$g_host" ]]
then
  echo '{"ok":false,"error":"Host is required"}'
  exit 1
fi

# Report an unusable key here rather than letting ssh fall back to the agent
# or to the default key files, which would test a different identity than the
# one the backup actually uses.
f_why="$(f_symbios_ssh_key_usable "$g_key")" || {
  echo "{\"ok\":false,\"error\":\"Backup key ${g_key} ${f_why}.\"}"
  exit 1
}

# Validate port
if ! [[ "$g_port" =~ ^[0-9]+$ ]] || (( g_port < 1 || g_port > 65535 ))
then
  echo '{"ok":false,"error":"Invalid port number"}'
  exit 1
fi

# Identity handling identical to the backup run: one explicit key, no agent
# keys (a target with MaxAuthTries like the sftp-share counts every offer).
g_opts=(-i "$g_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
        -o ConnectTimeout=10 -o BatchMode=yes)

# First attempt: shell channel. Shell targets answer the path probe directly;
# an SFTP-only daemon (ForceCommand internal-sftp, e.g. the SymbiOS sftp-share
# on port 28) refuses every exec request - the SFTP fallback below covers it.
g_output=$(ssh "${g_opts[@]}" -p "$g_port" "${g_user}@${g_host}" echo ok 2>&1)
g_rc=$?

if [[ $g_rc -eq 0 ]]
then
  # Shell channel works: authenticate the user we are talking to.
  if [[ -z "$g_path" ]]
  then
    echo '{"ok":true,"message":"Connection successful."}'
    exit 0
  fi
  # Verify the target directory over the same session.
  g_path_output=$(ssh "${g_opts[@]}" -p "$g_port" "${g_user}@${g_host}" \
    "test -d ${g_path} && echo path_ok || echo path_missing" 2>&1)
  if [[ "$g_path_output" == *"path_ok"* ]]
  then
    g_msg="Connection successful. Directory ${g_path} exists."
    echo "{\"ok\":true,\"message\":$(printf '%s' "$g_msg" | f_json_escape)}"
    exit 0
  fi
  if [[ "$g_path_output" == *"path_missing"* ]]
  then
    g_err="Connection successful, but directory ${g_path} does not exist on the remote host."
  else
    g_err="Connection successful, but could not verify path: ${g_path_output}"
  fi
  echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
  exit 1
fi

# Second attempt: SFTP subsystem. A refused exec channel is not an
# authentication failure, so the same key may still open an SFTP session.
# The batch aborts on the first failing command, which makes the exit status
# of "cd <path>" the path check.
if [[ "$g_output" != *"Permission denied"* ]] \
   && [[ "$g_output" != *"Too many authentication failures"* ]]
then
  g_sftp_output=$(printf 'cd %s\n' "${g_path:-/}" | \
    sftp -b - -P "$g_port" "${g_opts[@]}" "${g_user}@${g_host}" 2>&1)
  if [[ $? -eq 0 ]]
  then
    if [[ -n "$g_path" ]]
    then
      g_msg="Connection successful (SFTP endpoint, no shell access). Directory ${g_path} exists."
    else
      g_msg="Connection successful (SFTP endpoint, no shell access)."
    fi
    echo "{\"ok\":true,\"message\":$(printf '%s' "$g_msg" | f_json_escape)}"
    exit 0
  fi
  # The endpoint accepted the key but the configured path is missing: report
  # that instead of a generic failure, it is the common misconfiguration.
  if [[ "$g_sftp_output" == *"No such file or directory"* ]] \
     || [[ "$g_sftp_output" == *"not found"* ]]
  then
    g_err="Connection successful (SFTP endpoint), but directory ${g_path} does not exist on the remote host."
    echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
    exit 1
  fi
fi

# Neither channel worked: classify the failure of the shell attempt.
if [[ "$g_output" == *"Permission denied"* ]]
then
  echo '{"ok":false,"error":"Connection failed: Permission denied. Check that the SSH key is authorized on the remote host."}'
elif [[ "$g_output" == *"Connection refused"* ]]
then
  g_err="Connection refused on port ${g_port}. Is SSH running?"
  echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
elif [[ "${g_output,,}" == *"timed out"* ]] || [[ "${g_output,,}" == *"timeout"* ]]
then
  g_err="Connection timed out. Is ${g_host} reachable?"
  echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
elif [[ "$g_output" == *"No route to host"* ]]
then
  g_err="No route to host ${g_host}. Is the host reachable?"
  echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
else
  g_err="Connection failed: ${g_output}"
  echo "{\"ok\":false,\"error\":$(printf '%s' "$g_err" | f_json_escape)}"
fi
exit 1
