#!/bin/bash
# SymbiOS - Install the host's SSH public key on an external system.
#
# One-time bootstrap: opens a single password-authenticated SSH connection to
# the target and appends the host's ed25519 public key to its authorized_keys,
# so every later connection (playbook runs, syncs, tests) is key-based.
#
# The authorized_keys location depends on the target's SSH server:
#   - OpenSSH            -> ~/.ssh/authorized_keys
#   - Dropbear (OpenWrt) -> /etc/dropbear/authorized_keys for root,
#                           ~/.ssh/authorized_keys otherwise
# The script detects a running Dropbear daemon (falling back to the installed
# binary when no OpenSSH daemon is present) and picks the file accordingly.
#
# The one-time password is read from stdin (never argv / audit log) and is only
# used for this first login - it is not stored anywhere.
#
# Usage:
#   echo '<password>' | symbios-remote-install-key.sh <target_id>

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <target_id>

Install the host's public SSH key (/root/.ssh/id_ed25519.pub) on an external
system so that later logins are key-based. The one-time password is read from
stdin (first line) and never appears on the command line or in the audit log.

Arguments:
  <target_id>      id of an entry in ${g_config_dir}/external-systems.yml

Options:
  -h, --help       Show this help and exit

Examples:
  echo 'secret' | $(basename "$0") openwrt1

Exit codes:
  0  key installed (or already present)
  1  technical error (target unknown, SSH failed, ...)
  2  usage error
EOF
}

function f_fail {
  g_echo_error "$1"
  exit "${2:-1}"
}

# --- arguments --------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

g_target="${1:-}"
if [[ -z "${g_target}" ]]
then
  f_usage >&2
  exit 2
fi

# --- resolve target ---------------------------------------------------------
if ! f_external_target "${g_target}"
then
  f_fail "Unknown external system: ${g_target} (see ${g_config_dir}/external-systems.yml)"
fi

# --- read the one-time password from stdin ----------------------------------
# Read all of stdin and drop a single trailing newline so the secret is exact.
g_password="$(cat /dev/stdin)"
g_password="${g_password%$'\n'}"
if [[ -z "${g_password}" ]]
then
  f_fail "No password received on stdin"
fi

# --- host public key --------------------------------------------------------
g_pubkey="/root/.ssh/id_ed25519.pub"
if [[ ! -r "${g_pubkey}" ]]
then
  f_fail "Host public key not found: ${g_pubkey} (run ssh-keygen first)"
fi
# Base64 (single line) so the key survives both shell layers unquoted.
g_key_b64="$(base64 -w0 "${g_pubkey}")"

if ! command -v sshpass > /dev/null
then
  f_fail "sshpass is not installed on the host"
fi

# --- install the key on the target ------------------------------------------
# SSHPASS env + sshpass -e keeps the password out of argv. The remote command
# detects the SSH server, picks the right authorized_keys file, decodes the key,
# appends it idempotently and tightens permissions.
#
# Build the remote command as one string: single-quoted segments are literal
# (their $ variables expand on the target), while the double-quoted segment
# expands ${g_key_b64} here so the key is embedded before the transfer.
g_remote_cmd='keyfile="$HOME/.ssh/authorized_keys"
if ps 2>/dev/null | grep -qw dropbear; then
  is_dropbear=1
elif { command -v dropbear >/dev/null 2>&1 || [ -x /usr/sbin/dropbear ]; } && ! ps 2>/dev/null | grep -qw sshd; then
  is_dropbear=1
else
  is_dropbear=0
fi
if [ "$is_dropbear" = "1" ] && [ "$(id -un)" = "root" ]; then
  keyfile=/etc/dropbear/authorized_keys
fi
mkdir -p "$(dirname "$keyfile")"
[ "$(dirname "$keyfile")" = "$HOME/.ssh" ] && chmod 700 "$HOME/.ssh"
echo '"${g_key_b64}"' | base64 -d > /tmp/.symbios_key
if ! grep -qxF "$(cat /tmp/.symbios_key)" "$keyfile" 2>/dev/null; then cat /tmp/.symbios_key >> "$keyfile"; fi
chmod 600 "$keyfile"
rm -f /tmp/.symbios_key'

g_echo_note "Installing SSH key on ${g_target} (${g_ext_user}@${g_ext_host}:${g_ext_port})"
SSHPASS="${g_password}" sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=10 \
  -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}" \
  "${g_remote_cmd}"
g_rc=$?

# Wipe the secret from memory as soon as it is no longer needed.
unset g_password

if (( g_rc != 0 ))
then
  f_fail "SSH login failed (wrong password, host unreachable or sshd rejects password auth)" "${g_rc}"
fi

g_echo_note "SSH key installed on ${g_target}."
