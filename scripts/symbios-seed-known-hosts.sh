#!/bin/bash
# SymbiOS - Seed the pinned SSH known_hosts for the WebUI exec gateway.
#
# Pin the host key used by the WebUI's SSH exec path. The WebUI connects
# to the symbios_base_services network gateway (192.168.41.1:33); we record
# the real host key under that IP and localhost so the fingerprint policy
# can match. Called from base-services/symbios-ui.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [config_dir]

Seed the pinned SSH known_hosts for the WebUI exec gateway from a live
ssh-keyscan of 127.0.0.1. config_dir defaults to <config> (symbios-lib.sh).

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_seed_known_hosts {
  local f_kh="${1}/.ssh/known_hosts" f_tmp f_line f_keytype f_key
  local f_tokens="192.168.41.1,localhost,127.0.0.1"
  f_tmp=$(mktemp)
  ssh-keyscan -t ed25519,ecdsa,rsa -p 22 127.0.0.1 > "${f_tmp}" 2>/dev/null || true
  if [[ ! -s "${f_tmp}" ]]
  then
    echo "ssh-keyscan failed" >&2
    rm -f "${f_tmp}"
    return 1
  fi
  : > "${f_kh}"
  while read -r f_line
  do
    case "${f_line}" in \#*) continue;; esac
    f_keytype=$(echo "${f_line}" | awk '{print $2}')
    f_key=$(echo "${f_line}" | awk '{print $3}')
    [[ -z "${f_keytype}" ]] && continue
    echo "${f_tokens} ${f_keytype} ${f_key}" >> "${f_kh}"
  done < "${f_tmp}"
  chmod 644 "${f_kh}"
  chown root:10000 "${f_kh}"
  rm -f "${f_tmp}"
}

f_seed_known_hosts "${1:-${g_config_dir}}"
