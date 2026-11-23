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
# symbios-secrets-list.sh - JSON inventory of the central secret store for
# the WebUI. Names and metadata only; values are never read or printed.
#
# Usage:
#   symbios-secrets-list.sh [--json]
#   symbios-secrets-list.sh -h | --help
#
# Output: {"initialized":bool,"secrets":[{name,type,policy,consumers,
#          last_rotated,hook,previous,rotatable}]}. Exit codes: 0 ok,
# 1 technical error, 2 usage error.

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
Usage: $(basename "$0") [--json]

List central secret store entries as JSON for the WebUI. Names and metadata
only - secret values are never read, logged or printed.

Options:
  --json      Output JSON (default)
  -h, --help  Show this help and exit

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
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--json" ) ]]
then
  g_echo_error "unknown argument: ${1:-}"
  f_usage >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || f_fail "jq is not installed"
[[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || f_fail "config directory not available"

g_key_file="${g_data_root}/.keys/symbios-secret.age.key"
g_secret_dir="${g_config_dir}/secrets"

function f_status_field {
  local f_status="$1" f_key="$2" f_line
  while IFS= read -r f_line
  do
    [[ "$f_line" == "${f_key}="* ]] || continue
    printf '%s' "${f_line#*=}"
    return 0
  done <<< "${f_status}"
}

function f_build_json {
  local f_name f_status f_type f_policy f_consumers f_last f_hook f_prev
  local f_previous_json f_rotatable_json f_entry f_json="[]"

  while IFS= read -r f_name
  do
    [[ -n "${f_name}" ]] || continue
    f_status="$("${g_script_dir}/symbios-secret.sh" status "${f_name}" 2>/dev/null || true)"
    f_type="$(f_status_field "${f_status}" type)"
    [[ -n "${f_type}" ]] || f_type="generated"
    f_policy="$(f_status_field "${f_status}" policy)"
    [[ -n "${f_policy}" ]] || f_policy="manual"
    f_consumers="$(f_status_field "${f_status}" consumers)"
    f_last="$(f_status_field "${f_status}" last_rotated)"
    f_hook="$(f_status_field "${f_status}" hook)"
    [[ -n "${f_hook}" ]] || f_hook="none"
    f_prev="$(f_status_field "${f_status}" previous-ciphertext)"

    if [[ "${f_prev}" == "none" || -z "${f_prev}" ]]
    then
      f_previous_json="false"
    else
      f_previous_json="true"
    fi
    if [[ "${f_type}" == "generated" ]]
    then
      f_rotatable_json="true"
    else
      f_rotatable_json="false"
    fi

    f_entry="$(jq -n \
      --arg name "${f_name}" \
      --arg type "${f_type}" \
      --arg policy "${f_policy}" \
      --arg consumers "${f_consumers}" \
      --arg last_rotated "${f_last}" \
      --arg hook "${f_hook}" \
      --argjson previous "${f_previous_json}" \
      --argjson rotatable "${f_rotatable_json}" \
      '{name:$name, type:$type, policy:$policy, consumers:$consumers,
        last_rotated:$last_rotated, hook:$hook, previous:$previous,
        rotatable:$rotatable}')" || f_fail "cannot build secret JSON"
    f_json="$(jq -c --argjson entry "${f_entry}" '. + [$entry]' <<< "${f_json}")" \
      || f_fail "cannot accumulate secret JSON"
  done < <("${g_script_dir}/symbios-secret.sh" list 2>/dev/null || true)

  jq -n --argjson secrets "${f_json}" '{initialized:true, secrets:$secrets}'
}

if [[ ! -r "${g_key_file}" ]]
then
  jq -n '{initialized:false, secrets:[]}'
  exit 0
fi

if [[ ! -d "${g_secret_dir}" ]]
then
  jq -n '{initialized:true, secrets:[]}'
  exit 0
fi

f_build_json
