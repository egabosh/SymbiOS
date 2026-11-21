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
  f_ss_playbooks_for_vars <var>...
                             print consuming host playbooks (ordered)
  f_ss_apply <var>...
                             run consuming playbooks in order, abort on error
  f_ss_apply_cmd             implements 'apply [--dry-run]' from the
                             caller's f_managed_vars (space-separated keys)
  f_ss_finish                finish the set subcommand: apply consuming
                             playbooks once when inventory really changed;
                             callers set f_managed_vars before invoking it

Options:
  -h, --help  Show this help and exit

Domain scripts also accept --no-apply (set by each script's option parser
into g_ss_no_apply): it skips the automatic apply after a real change, so
smoke tests can exercise set against a scratch inventory without running
playbooks.
EOF
    exit 0
  fi
  echo "$(basename "$0") is a library and cannot be run directly - source it instead." >&2
  exit 1
fi

# Directory of this library (= scripts/), independent of PATH.
g_ss_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Set to yes by f_ss_result for a real (non-check, non-unchanged) inventory
# write; f_ss_finish uses it to apply exactly once at the end of `set`.
g_ss_changed="no"
# Set to yes by a script's --no-apply option; smoke tests use it to exercise
# set against a scratch inventory without running any playbook.
g_ss_no_apply="no"

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

# Store a secret in the central store and append a `secret:<name>` reference
# to the pending inventory merge. This makes the store the single source of
# truth: inventory keeps only the reference, never the plaintext. The value is
# piped to symbios-secret.sh on stdin, so it never appears in argv. An empty
# value deletes the store entry and clears the inventory key. In --check mode
# nothing is written; only the intent is reported.
#
# Arguments: <name> <value> <given(yes|no)> <check(yes|no)>.
# Uses the caller's f_merge / f_merge_first globals via f_ss_merge_add.
function f_ss_secret_merge_add {
  local f_name="$1" f_value="$2" f_given="$3" f_check="$4"
  [[ "${f_given}" == "yes" ]] || return 0
  if [[ "${f_check}" == "yes" ]]
  then
    if [[ -n "${f_value}" ]]
    then
      g_echo_note "would store secret ${f_name}"
    else
      g_echo_note "would delete secret ${f_name}"
    fi
  else
    if [[ -n "${f_value}" ]]
    then
      printf '%s' "${f_value}" | "${g_ss_dir}/symbios-secret.sh" put "${f_name}" >/dev/null \
        || f_ss_fail_technical "cannot store secret ${f_name}"
    else
      "${g_ss_dir}/symbios-secret.sh" delete "${f_name}" >/dev/null 2>&1 || true
    fi
  fi
  # The reference is not a secret; f_ss_merge_add handles the JSON quoting.
  f_ss_merge_add "${f_name}" "${f_value:+secret:${f_name}}" "yes"
}

# Resolve host playbooks consuming inventory vars (stdout, one per line;
# stderr carries skip notes). Thin wrapper over symbios-playbooks-for-vars.sh.
function f_ss_playbooks_for_vars {
  "$g_ss_dir/symbios-playbooks-for-vars.sh" "$@"
}

# Apply inventory changes: resolve consumers for the given vars and run
# each playbook in order via symbios-run-playbook.sh. Aborts on the first
# failure (same && semantics as chained reapply jobs) and propagates its
# exit code. Empty var lists, or lists resolving to nothing, print
# "Nothing to apply." and exit 0 - by design (e.g. live-script vars).
function f_ss_apply {
  local f_v f_vars=() f_pbs="" f_pb
  for f_v in "$@"
  do
    [[ -n "${f_v}" ]] || continue
    f_vars+=("${f_v}")
  done
  if [[ "${#f_vars[@]}" -eq 0 ]]
  then
    g_echo "Nothing to apply."
    return 0
  fi
  # Keep the resolver's stderr: its "skip: ..." notes are part of the job
  # output and tell the user why a declared consumer was not run.
  f_pbs="$("$g_ss_dir/symbios-playbooks-for-vars.sh" "${f_vars[@]}")" \
    || return 1
  if [[ -z "${f_pbs}" ]]
  then
    g_echo "Nothing to apply."
    return 0
  fi
  while read -r f_pb
  do
    [[ -n "${f_pb}" ]] || continue
    "$g_ss_dir/symbios-run-playbook.sh" "${f_pb}" || return 1
  done <<< "${f_pbs}"
  return 0
}

# Implements the `apply` subcommand for settings scripts. Caller sets
# f_managed_vars (space-separated inventory keys, may be empty) and shifts
# past 'apply'; remaining args: [--dry-run]. Dry-run prints what would run.
# Rule: list only keys that playbooks bake into state (declared in their
# docs uses_vars). Keys read live at runtime (scripts, WebUI) and one-shot
# markers (*_configured, mode flags no playbook reads) stay out - an empty
# list is valid and apply then reports nothing to do.
function f_ss_apply_cmd {
  local f_dry="no"
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --dry-run)
        f_dry="yes"
        ;;
      -h|--help)
        f_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        f_ss_fail_usage
        ;;
    esac
    shift
  done
  # An empty f_managed_vars is valid (runtime-only settings). The resolver
  # would reject an empty argument list, so short-circuit before calling it.
  if [[ -z "${f_managed_vars// /}" ]]
  then
    g_echo "Nothing to apply."
    return 0
  fi
  # shellcheck disable=SC2086
  if [[ "${f_dry}" == "yes" ]]
  then
    f_ss_playbooks_for_vars ${f_managed_vars}
    return $?
  fi
  # shellcheck disable=SC2086
  f_ss_apply ${f_managed_vars}
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
  # Remember a real change for the final f_ss_finish call. Check mode and
  # "unchanged" writes must not trigger an apply.
  if [[ "${f_check}" != "yes" && "${f_first}" != "unchanged" ]]
  then
    g_ss_changed="yes"
  fi
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

# Finish a write subcommand: run consuming playbooks once after all
# inventory writes, using the caller's f_managed_vars. Check mode, an
# unchanged write and --no-apply all return 0 without applying. The last
# command propagates the apply exit code (0 ok / 1 technical error).
function f_ss_finish {
  if [[ "${g_ss_no_apply}" == "yes" ]]
  then
    g_echo "Nothing to apply (--no-apply)."
    return 0
  fi
  if [[ "${g_ss_changed}" != "yes" ]]
  then
    g_echo "Nothing to apply (unchanged)."
    return 0
  fi
  # shellcheck disable=SC2086
  f_ss_apply ${f_managed_vars}
}
