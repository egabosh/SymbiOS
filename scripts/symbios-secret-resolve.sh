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
# symbios-secret-resolve.sh - Resolve several store secrets into one 0600 JSON
# file for Ansible. The values never appear in argv or on stdout: only the path
# of the generated file is printed. The caller removes it with
# `symbios-secret.sh cleanup <path>`.
#
# Usage: symbios-secret-resolve.sh <name> [<name> ...]
#
# Output: one path to a 0600 JSON file: {"name": "value", ...}
# Exit codes: 0 ok, 1 technical error, 2 usage error.

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
Usage: $(basename "$0") <name> [<name> ...]

Resolve store secrets into a transient 0600 JSON file. Only the file path is
printed on stdout; the JSON holds {"<name>": "<value>"} for every name.

The caller must remove the file after use:
  symbios-secret.sh cleanup "\$(symbios-secret-resolve.sh <name>)"

Exit codes: 0 ok, 1 technical error, 2 usage error.
EOF
}

# Scratch files (plaintext values and JSON pieces) are shredded on exit.
declare -ag g_scratch_files=()

function f_cleanup_scratch {
  local f_file
  for f_file in "${g_scratch_files[@]:-}"
  do
    [[ -f "${f_file}" ]] && { shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"; }
  done
  g_scratch_files=()
}

# Return a path only. Registration must happen in the CALLER: this function is
# invoked in $(...), where an array change would stay in the subshell.
function f_scratch_path {
  local f_path
  f_path=$(mktemp "${g_config_dir}/.secret-resolve-XXXXXX") || return 1
  chmod 0600 "${f_path}" || return 1
  printf '%s' "${f_path}"
}

function f_scratch_register {
  g_scratch_files+=("$1")
}

# shellcheck disable=SC2317
trap f_cleanup_scratch EXIT

function f_fail {
  g_echo_error "$*"
  exit 1
}

function f_usage_error {
  g_echo_error "$*"
  f_usage >&2
  exit 2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

[[ $# -gt 0 ]] || f_usage_error "at least one secret name is required"
command -v jq >/dev/null 2>&1 || f_fail "jq is not installed"
[[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || f_fail "config directory not available"
[[ -x "${g_script_dir}/symbios-secret.sh" ]] || f_fail "symbios-secret.sh not found"

declare -ag g_pieces=()
for f_name in "$@"
do
  f_value_file=$(f_scratch_path) || f_fail "cannot create value file"
  f_scratch_register "${f_value_file}"
  if ! "${g_script_dir}/symbios-secret.sh" get "${f_name}" --path "${f_value_file}" >/dev/null 2>&1
  then
    # Migration safety net: on an existing host the store may still be empty
    # while inventory holds the original plaintext value. Keep that value so a
    # staged rollout cannot silently blank a working credential. A `secret:`
    # reference is never a credential - leave those empty with a warning.
    f_fallback=$(f_symbios_var "${f_name}" "")
    if [[ -n "${f_fallback}" && "${f_fallback}" != secret:* ]]
    then
      printf '%s' "${f_fallback}" > "${f_value_file}"
      g_echo_error "warning: ${f_name} resolved from legacy inventory (store not seeded)"
    else
      g_echo_error "warning: secret not in store, leaving empty: ${f_name}"
      : > "${f_value_file}"
    fi
  fi
  f_piece=$(f_scratch_path) || f_fail "cannot create JSON piece"
  f_scratch_register "${f_piece}"
  jq -n --arg f_name "${f_name}" --rawfile f_value "${f_value_file}" \
    '{($f_name): $f_value}' > "${f_piece}" || f_fail "cannot build JSON for ${f_name}"
  g_pieces+=("${f_piece}")
done

# The output file is deliberately NOT scratch: the caller (Ansible) reads it
# and removes it afterwards with symbios-secret.sh cleanup.
f_output=$(mktemp "${g_config_dir}/.secret-resolve-XXXXXX") || f_fail "cannot create output file"
chmod 0600 "${f_output}" || f_fail "cannot chmod output file"
jq -s 'add' "${g_pieces[@]}" > "${f_output}" || f_fail "cannot merge resolved secrets"
f_cleanup_scratch
trap - EXIT
printf '%s\n' "${f_output}"
