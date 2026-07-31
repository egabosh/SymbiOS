#!/bin/bash
# SymbiOS - Test SSH connectivity to a remote server
# Usage: symbios-test-ssh.sh <host> <port> <user> [path]
# Output: JSON with ok, message/error

source /etc/bash/gaboshlib.include
source symbios-lib.sh

g_host="${1:-}"
g_port="${2:-22}"
g_user="${3:-root}"
g_path="${4:-}"
g_key="${g_config_dir}/.ssh/id_symbios"

if [[ -z "$g_host" ]]
then
  echo '{"ok":false,"error":"Host is required"}'
  exit 1
fi

# Validate port
if ! [[ "$g_port" =~ ^[0-9]+$ ]] || (( g_port < 1 || g_port > 65535 ))
then
  echo '{"ok":false,"error":"Invalid port number"}'
  exit 1
fi

# Test SSH connection
g_output=$(ssh -i "$g_key" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  -o BatchMode=yes \
  -p "$g_port" \
  "${g_user}@${g_host}" \
  echo ok 2>&1)
g_rc=$?

if [[ $g_rc -eq 0 ]]
then
  # Connection successful, optionally test path
  if [[ -n "$g_path" ]]
  then
    g_path_output=$(ssh -i "$g_key" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      -p "$g_port" \
      "${g_user}@${g_host}" \
      "test -d ${g_path} && echo path_ok || echo path_missing" 2>&1)

    if [[ "$g_path_output" == *"path_ok"* ]]
    then
      g_msg="Connection successful. Directory ${g_path} exists."
      echo "{\"ok\":true,\"message\":$(echo "$g_msg" | f_json_escape)}"
    elif [[ "$g_path_output" == *"path_missing"* ]]
    then
      g_err="Connection successful, but directory ${g_path} does not exist on the remote host."
      echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
    else
      g_err="Connection successful, but could not verify path: ${g_path_output}"
      echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
    fi
  else
    echo '{"ok":true,"message":"Connection successful."}'
  fi
else
  # Classify error from stderr
  if [[ "$g_output" == *"Permission denied"* ]]
  then
    echo '{"ok":false,"error":"Connection failed: Permission denied. Check that the SSH key is authorized on the remote host."}'
  elif [[ "$g_output" == *"Connection refused"* ]]
  then
    g_err="Connection refused on port ${g_port}. Is SSH running?"
    echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
  elif [[ "${g_output,,}" == *"timed out"* ]] || [[ "${g_output,,}" == *"timeout"* ]]
  then
    g_err="Connection timed out. Is ${g_host} reachable?"
    echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
  elif [[ "$g_output" == *"No route to host"* ]]
  then
    g_err="No route to host ${g_host}. Is the host reachable?"
    echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
  else
    g_err="Connection failed: ${g_output}"
    echo "{\"ok\":false,\"error\":$(echo "$g_err" | f_json_escape)}"
  fi
  exit 1
fi
