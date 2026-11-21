#!/bin/bash
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
#
# symbios-secret-migrate-inventory.sh - One-time/idempotent migration of the
# known plaintext inventory secrets into the central store. Each migrated key
# is replaced in inventory.yml with a `secret:<name>` reference, so the store
# becomes the single source of truth. Re-running is safe: an already migrated
# reference or an existing store entry is left alone.
#
# Usage: symbios-secret-migrate-inventory.sh [--help]
# No arguments. Exit codes: 0 ok, 1 technical error, 2 usage error.

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
if ! declare -F g_echo_note >/dev/null 2>&1
then
  function g_echo_note { printf '%s\n' "$*"; }
  function g_echo_error { printf '%s\n' "$*" >&2; }
fi
# shellcheck source=symbios-lib.sh
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

Move the known plaintext secrets in inventory.yml into the central age store
and leave a \`secret:<name>\` reference behind. Idempotent: references and
existing store entries are never overwritten.

Options:
  -h, --help  Show this help and exit

No arguments.

Exit codes: 0 ok, 1 technical error, 2 usage error.
EOF
}

function f_fail {
  g_echo_error "$*"
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi
if [[ $# -gt 0 ]]
then
  g_echo_error "no arguments expected"
  f_usage >&2
  exit 2
fi

[[ -x "${g_script_dir}/symbios-secret.sh" ]] || f_fail "symbios-secret.sh not found"
[[ -x "${g_script_dir}/symbios-inventory.py" ]] || f_fail "symbios-inventory.py not found"
[[ -n "${g_inventory:-}" && -f "${g_inventory}" ]] || f_fail "inventory not available: ${g_inventory:-unset}"

# Known inventory-backed secrets (see AGENTS.md secret-key inventory).
declare -ag g_secret_keys=(
  ddns_apikey
  smtp_password
  matrix_password
  matrix_token
  ai_apikey
  ai_stt_key
  ai_tts_key
  ap_passphrase
  router_upnp_password
)

# Scratch value files are shredded on exit so no plaintext survives.
declare -ag g_scratch_files=()
function f_cleanup_scratch {
  local f_file
  for f_file in "${g_scratch_files[@]:-}"
  do
    [[ -f "${f_file}" ]] && { shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"; }
  done
  g_scratch_files=()
}
trap f_cleanup_scratch EXIT

for f_key in "${g_secret_keys[@]}"
do
  # Read the current value into a 0600 file: it never enters argv.
  f_value_file=$(mktemp "${g_config_dir}/.value-XXXXXX") || f_fail "cannot create value file"
  chmod 0600 "${f_value_file}" || f_fail "cannot chmod value file"
  g_scratch_files+=("${f_value_file}")
  "${g_script_dir}/symbios-inventory.py" --inventory "${g_inventory}" get "${f_key}" > "${f_value_file}" 2>/dev/null \
    || : > "${f_value_file}"
  f_value=$(<"${f_value_file}")

  # Already a reference or empty: nothing to migrate.
  if [[ -z "${f_value}" || "${f_value}" == secret:* ]]
  then
    continue
  fi

  if [[ ! -f "${g_config_dir}/secrets/${f_key}.age" ]]
  then
    "${g_script_dir}/symbios-secret.sh" put "${f_key}" --file "${f_value_file}" >/dev/null \
      || f_fail "cannot store ${f_key}"
  fi

  # The reference itself is not a secret, so passing it as argv is safe.
  "${g_script_dir}/symbios-inventory.py" --inventory "${g_inventory}" set "${f_key}" "secret:${f_key}" >/dev/null \
    || f_fail "cannot set reference for ${f_key}"
  g_echo_note "migrated: ${f_key}"
done

g_echo_note "inventory secret migration complete"
