#!/bin/bash
# SymbiOS - Manage root SSH authorized_keys (user keys).
#
# Settings CLI-first architecture: the WebUI page /settings/ssh-keys/ is a
# thin wrapper around this script, which owns validation and the write.
#
# NOTE: this domain manages a host FILE (/root/.ssh/authorized_keys), not
# inventory.yml (the documented SSH-key exception in AGENTS.md). The actual
# file write is delegated to symbios-write-authorized-keys.sh, which keeps
# the change atomic and always preserves the symbios-base-webui exec-gateway
# key. This script adds strict validation (key type + base64), index-based
# removal over user keys only, and machine-readable list output. The
# gateway key can never be edited or removed through this script: it is
# filtered from every user-key operation by construction.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage root SSH authorized_keys (user keys; the symbios-base-webui
exec-gateway key is always preserved and never listed as editable).

Commands:
  list [--json]                   Print user keys (one per line), then a
                                  "--- system keys (preserved) ---" section;
                                  with --json print
                                  {"user_keys": [...], "system_keys": [...]}
  validate [--stdin]              Check key lines from stdin (or remaining
                                  args) strictly: known type + valid base64.
                                  Comments (#...) and empty lines are
                                  skipped. Prints "valid: N" or the first
                                  bad line; exit 2 when any key is invalid.
  add --key "LINE" [--check]      Append one key to the user keys (skipped
                                  when already present). --check changes
                                  nothing.
  remove --index N [--check]      Remove the Nth user key (0-based, order of
                                  list). System keys are never indexed.
                                  --check changes nothing.
  set --stdin [--check]           Replace the user-key set with key lines
                                  from stdin (comments/empty lines allowed).
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (ssh-keys-changed / ssh-keys-unchanged).

Examples:
  $(basename "$0") list --json
  $(basename "$0") add --key "ssh-ed25519 AAAA... user@host"
  $(basename "$0") remove --index 0
  printf '%s\n' "ssh-ed25519 AAAA... user@host" | $(basename "$0") set --stdin

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (bad key, bad index, ...)
  1  technical error (file unreadable, writer failed, ...)
EOF
}

function f_fail_usage {
  f_usage >&2
  exit 2
}

function f_fail_validation {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 2
}

function f_fail_technical {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 1
}

# Strict check for one authorized_keys line: known type + base64 body.
# Comments and empty lines are skipped by the caller, never passed here.
function f_valid_key {
  local f_line="$1"
  local f_type="${f_line%% *}"
  local f_rest="${f_line#* }"
  local f_body="${f_rest%% *}"
  case "${f_type}" in
    ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)
      ;;
    *)
      return 1
      ;;
  esac
  [[ "${f_rest}" == *" "* || -n "${f_body}" ]] || return 1
  printf '%s' "${f_body}" | base64 -d >/dev/null 2>&1 || return 1
  return 0
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  list|validate|add|remove|set|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_fail_usage
    ;;
esac

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

f_keys_file="/root/.ssh/authorized_keys"

# --- read current state ---------------------------------------------------------

f_all_keys=()
if [[ -f "${f_keys_file}" ]]
then
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    f_line="${f_line#"${f_line%%[![:space:]]*}"}"
    f_line="${f_line%"${f_line##*[![:space:]]}"}"
    [[ -n "${f_line}" ]] && f_all_keys+=("${f_line}")
  done < "${f_keys_file}"
fi

f_user_keys=()
f_system_keys=()
for f_line in ${f_all_keys[@]+"${f_all_keys[@]}"}
do
  if [[ "${f_line}" == *"symbios-base-webui"* ]]
  then
    f_system_keys+=("${f_line}")
  else
    f_user_keys+=("${f_line}")
  fi
done

# --- subcommand: list ------------------------------------------------------------

if [[ "${f_command}" == "list" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    f_json='{"user_keys": ['
    f_first="yes"
    for f_line in ${f_user_keys[@]+"${f_user_keys[@]}"}
    do
      [[ "${f_first}" == "yes" ]] || f_json="${f_json}, "
      f_first="no"
      f_json="${f_json}$(printf '%s' "${f_line}" | f_json_escape)"
    done
    f_json="${f_json}], \"system_keys\": ["
    f_first="yes"
    for f_line in ${f_system_keys[@]+"${f_system_keys[@]}"}
    do
      [[ "${f_first}" == "yes" ]] || f_json="${f_json}, "
      f_first="no"
      f_json="${f_json}$(printf '%s' "${f_line}" | f_json_escape)"
    done
    echo "${f_json}]}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for list: $1" >&2
    f_fail_usage
  fi
  for f_line in ${f_user_keys[@]+"${f_user_keys[@]}"}
  do
    printf '%s\n' "${f_line}"
  done
  if [[ "${#f_system_keys[@]}" -gt 0 ]]
  then
    echo "--- system keys (preserved) ---"
    for f_line in ${f_system_keys[@]+"${f_system_keys[@]}"}
    do
      printf '%s\n' "${f_line}"
    done
  fi
  exit 0
fi

# --- subcommand: schema ------------------------------------------------------------

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
{
  "backend": "authorized_keys",
  "path": "/root/.ssh/authorized_keys",
  "fields": [
    {"name": "keys", "type": "multiline", "label": "SSH public keys",
     "required": false, "default": "", "secret": false,
     "note": "One key per line. The symbios-base-webui gateway key is preserved automatically."}
  ]
}
EOF
  exit 0
fi

# --- subcommand: validate ------------------------------------------------------------

if [[ "${f_command}" == "validate" ]]
then
  f_input=()
  if [[ "${1:-}" == "--stdin" ]]
  then
    shift
    while IFS= read -r f_line || [[ -n "${f_line}" ]]
    do
      f_input+=("${f_line}")
    done
  else
    while [[ $# -gt 0 ]]
    do
      f_input+=("$1")
      shift
    done
  fi
  f_count=0
  f_lineno=0
  for f_line in ${f_input[@]+"${f_input[@]}"}
  do
    f_lineno=$((f_lineno + 1))
    f_trimmed="${f_line#"${f_line%%[![:space:]]*}"}"
    f_trimmed="${f_trimmed%"${f_trimmed##*[![:space:]]}"}"
    [[ -z "${f_trimmed}" || "${f_trimmed}" == \#* ]] && continue
    if ! f_valid_key "${f_trimmed}"
    then
      f_fail_validation "Invalid SSH public key on input line ${f_lineno}: ${f_trimmed:0:60}"
    fi
    f_count=$((f_count + 1))
  done
  g_echo "valid: ${f_count} key(s)"
  exit 0
fi

# --- subcommands add/remove/set (parse options, then write once) ---------------------

f_new_key=""
f_index=""
f_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --key)
      [[ $# -ge 2 ]] || f_fail_usage
      [[ "${f_command}" == "add" ]] || f_fail_usage
      f_new_key="$2"
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || f_fail_usage
      [[ "${f_command}" == "remove" ]] || f_fail_usage
      f_index="$2"
      shift 2
      ;;
    --stdin)
      [[ "${f_command}" == "set" ]] || f_fail_usage
      f_stdin="yes"
      shift
      ;;
    --check)
      f_check="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      f_fail_usage
      ;;
  esac
done

f_result_user=("${f_user_keys[@]+"${f_user_keys[@]}"}")

if [[ "${f_command}" == "add" ]]
then
  [[ -n "${f_new_key}" ]] || f_fail_validation "Nothing to add - pass --key \"LINE\""
  f_trimmed="${f_new_key#"${f_new_key%%[![:space:]]*}"}"
  f_trimmed="${f_trimmed%"${f_trimmed##*[![:space:]]}"}"
  f_valid_key "${f_trimmed}" \
    || f_fail_validation "Invalid SSH public key format"
  f_dup="no"
  for f_line in ${f_result_user[@]+"${f_result_user[@]}"}
  do
    [[ "${f_line}" == "${f_trimmed}" ]] && f_dup="yes"
  done
  [[ "${f_dup}" == "yes" ]] || f_result_user+=("${f_trimmed}")
elif [[ "${f_command}" == "remove" ]]
then
  [[ "${f_index}" =~ ^[0-9]+$ ]] \
    || f_fail_validation "Invalid --index: ${f_index} (expected a number)"
  if [[ "${f_index}" -ge "${#f_result_user[@]}" ]]
  then
    f_fail_validation "Invalid --index: ${f_index} (only ${#f_result_user[@]} user key(s), system keys are never indexed)"
  fi
  f_kept=()
  f_i=0
  for f_line in ${f_result_user[@]+"${f_result_user[@]}"}
  do
    [[ "${f_i}" == "${f_index}" ]] || f_kept+=("${f_line}")
    f_i=$((f_i + 1))
  done
  f_result_user=("${f_kept[@]+"${f_kept[@]}"}")
elif [[ "${f_command}" == "set" ]]
then
  [[ "${f_stdin}" == "yes" ]] || f_fail_validation "Nothing to set - pass --stdin"
  f_result_user=()
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    f_trimmed="${f_line#"${f_line%%[![:space:]]*}"}"
    f_trimmed="${f_trimmed%"${f_trimmed##*[![:space:]]}"}"
    [[ -z "${f_trimmed}" ]] && continue
    # Comment lines are kept verbatim (same as the WebUI textarea before).
    if [[ "${f_trimmed}" == \#* ]]
    then
      f_result_user+=("${f_trimmed}")
      continue
    fi
    f_valid_key "${f_trimmed}" \
      || f_fail_validation "Invalid SSH public key format: ${f_trimmed:0:60}"
    f_result_user+=("${f_trimmed}")
  done
fi

# Compare desired user keys against current (system keys untouched either way).
f_same="yes"
if [[ "${#f_result_user[@]}" != "${#f_user_keys[@]}" ]]
then
  f_same="no"
else
  f_i=0
  for f_line in ${f_result_user[@]+"${f_result_user[@]}"}
  do
    [[ "${f_line}" == "${f_user_keys[$f_i]}" ]] || f_same="no"
    f_i=$((f_i + 1))
  done
fi

if [[ "${f_same}" == "yes" ]]
then
  g_echo "unchanged: ${#f_result_user[@]} user key(s)"
  g_echo_note "ssh-keys-unchanged"
  exit 0
fi

if [[ "${f_check}" == "yes" ]]
then
  g_echo "would write ${#f_result_user[@]} user key(s) (${#f_system_keys[@]} system key(s) preserved)"
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

# Delegate the write (atomic + gateway-key preservation live there).
f_payload="$(printf '%s\n' ${f_result_user[@]+"${f_result_user[@]}"})"
if ! f_out="$(printf '%s\n' "${f_payload}" \
  | "$g_symbios_dir/symbios-write-authorized-keys.sh" 2>&1)"
then
  f_fail_technical "Failed to write authorized_keys: ${f_out}"
fi

g_echo "${f_out}"
g_echo_note "ssh-keys-changed: ${#f_result_user[@]} user key(s)"
exit 0
