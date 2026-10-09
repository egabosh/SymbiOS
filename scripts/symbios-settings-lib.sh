#!/bin/bash
# SymbiOS - Shared plumbing for symbios-settings-*.sh CLI scripts.
#
# This is a library: source it, do not execute it. Sourcing order in the
# calling script is gaboshlib.include, symbios-lib.sh, then this file:
#
#   source /etc/bash/gaboshlib.include
#   g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
#   source "$g_symbios_dir/symbios-lib.sh"
#   source "$g_symbios_dir/symbios-settings-lib.sh"
#
# The settings CLI contract (exit 0 ok, 2 validation, 1 technical;
# human lines plus a <domain>-changed / <domain>-unchanged token) is
# implemented here once, so the twenty domain scripts keep only their
# usage text, option parsing, domain validation and JSON building.
#
# Inventory access always goes through symbios-inventory.py, resolved from
# this library's own directory (robust against PATH sanitizing).

# ---------------------------------------------------------------------------
# Direct invocation (not sourced): this is a library, so running it directly
# only makes sense to read its documentation. The guard below also keeps
# --help working without executing anything.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
  then
    cat << EOF
$(basename "$0") - Shared plumbing for symbios-settings-*.sh scripts.

This is a library and must be sourced, not executed (see header for the
sourcing order). Provided functions:

  f_ss_fail_usage            print the caller's f_usage to stderr, exit 2
  f_ss_fail_validation <msg> print an error, exit 2
  f_ss_fail_technical <msg>  print an error, exit 1
  f_ss_parse_bool <word>     print true/false for boolean words, else exit 1
  f_ss_require_url <n> <v>   exit 2 unless v is a single line w/o whitespace
  f_ss_require_single_line <n> <v>
                             exit 2 unless v holds no newline
  f_ss_merge_add <k> <v> <given>
                             append to f_merge under construction (empty=null)
  f_ss_merge <json> <t> [c] [d]
                             merge JSON via symbios-inventory.py and emit the
                             <t>-changed / <t>-unchanged token (c=yes enables
                             --check, d appends ': <detail>' to changed)
  f_ss_result <out> <t> [c] [d]
                             emit output + token for a custom inventory call
                             (dict-merge, file writers, ...)

Options:
  -h, --help  Show this help and exit
EOF
    exit 0
  fi
  echo "$(basename "$0") is a library and cannot be run directly - source it instead." >&2
  exit 1
fi

# Directory of this library (= scripts/), independent of PATH.
g_ss_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

function f_ss_fail_usage {
  f_usage >&2
  exit 2
}

function f_ss_fail_validation {
  local f_msg="$1"
  g_echo_error "${f_msg}" || echo "Error: ${f_msg}" >&2
  exit 2
}

function f_ss_fail_technical {
  local f_msg="$1"
  g_echo_error "${f_msg}" || echo "Error: ${f_msg}" >&2
  exit 1
}

# Normalize a boolean word; prints true/false, returns 1 otherwise. The
# caller reports its own field-specific error message on failure.
function f_ss_parse_bool {
  case "${1,,}" in
    true|1|yes|on)
      echo "true"
      ;;
    false|0|no|off)
      echo "false"
      ;;
    *)
      return 1
      ;;
  esac
}

# Require a URL-ish value: single line without whitespace. Empty values
# are the caller's decision (gate with [[ -n ... ]] when optional).
function f_ss_require_url {
  local f_name="$1" f_value="$2"
  if [[ "${f_value}" == *$'\n'* ]] || [[ "${f_value}" =~ [[:space:]] ]]
  then
    f_ss_fail_validation "Invalid ${f_name}: must be a single line without whitespace"
  fi
}

# Require a single-line value (no newlines). Empty values are the
# caller's decision (gate with [[ -n ... ]] when optional).
function f_ss_require_single_line {
  local f_name="$1" f_value="$2"
  if [[ "${f_value}" == *$'\n'* ]]
  then
    f_ss_fail_validation "Invalid ${f_name}: must be a single line"
  fi
}

# Append one key to a merge JSON under construction. Convention (shared
# by all callers): f_merge holds the open object, f_merge_first tracks the
# separator. Empty values become null (delete the key); missing options
# (given=no) are skipped so stored values are kept.
# Usage:
#   f_merge="{"; f_merge_first="yes"
#   f_ss_merge_add "timezone" "${f_new_timezone}" "${f_given_timezone}"
#   f_merge="${f_merge}}"
function f_ss_merge_add {
  local f_k="$1" f_v="$2" f_given="$3"
  [[ "${f_given}" == "yes" ]] || return 0
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge_first="no"
  if [[ -z "${f_v}" ]]
  then
    f_merge="${f_merge}\"${f_k}\": null"
  else
    f_merge="${f_merge}\"${f_k}\": $(printf '%s' "${f_v}" | f_json_escape)"
  fi
}

# Merge one JSON object transactionally and emit output + state token.
# Arguments: <merge-json> <token-base> [check=yes|no] [detail].
function f_ss_merge {
  local f_json="$1" f_token="$2" f_check="${3:-no}" f_detail="${4:-}"
  local f_flag="" f_out=""
  [[ "${f_check}" == "yes" ]] && f_flag="--check"
  if ! f_out="$(printf '%s' "${f_json}" \
    | "${g_ss_dir}/symbios-inventory.py" --inventory "${g_inventory}" merge ${f_flag} 2>&1)"
  then
    f_ss_fail_technical "Failed to write inventory: ${f_out}"
  fi
  f_ss_result "${f_out}" "${f_token}" "${f_check}" "${f_detail}"
}

# Emit captured inventory output plus the state token. Shared tail for
# custom inventory calls (dict-merge, file writers, ...) that cannot use
# f_ss_merge directly. Arguments: <output> <token-base> [check] [detail].
# The changed decision reads the FIRST status line only, so callers may
# append secondary output (e.g. a follow-up flag merge) without flipping
# an already reported change back to unchanged.
function f_ss_result {
  local f_out="$1" f_token="$2" f_check="${3:-no}" f_detail="${4:-}"
  local f_first=""
  f_first="$(head -n 1 <<< "${f_out}")"
  g_echo "${f_out}"
  if [[ "${f_check}" == "yes" ]]
  then
    g_echo_note "Check mode - nothing was changed"
    return 0
  fi
  if [[ "${f_first}" == "unchanged" ]]
  then
    if [[ -n "${f_detail}" ]]
    then
      g_echo_note "${f_token}-unchanged: ${f_detail}"
    else
      g_echo_note "${f_token}-unchanged"
    fi
  elif [[ -n "${f_detail}" ]]
  then
    g_echo_note "${f_token}-changed: ${f_detail}"
  else
    g_echo_note "${f_token}-changed"
  fi
}
