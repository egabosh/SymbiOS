#!/bin/bash
# SymbiOS - Manage AI image settings (generation/edit URLs and models).
#
# Settings CLI-first architecture: the WebUI page /settings/ai-image/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction). Empty values delete the
# key (same as the WebUI before). This domain carries no secrets, so plain
# flags are sufficient (no --json-stdin needed).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS AI image settings (image generation and editing).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--image-url URL --image-model M --image-edit-url URL
       --image-edit-model M] [--check]
                                  Validate and write to inventory.yml.
                                  Empty values delete the key.
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (ai-image-changed / ai-image-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
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

f_fields="ai_image_url ai_image_model ai_image_edit_url ai_image_edit_model"

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema)
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

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "ai_image_url", "type": "url", "label": "Image server URL",
   "required": false, "default": "", "secret": false},
  {"name": "ai_image_model", "type": "text", "label": "Image model",
   "required": false, "default": "", "secret": false},
  {"name": "ai_image_edit_url", "type": "url", "label": "Image edit server URL",
   "required": false, "default": "", "secret": false},
  {"name": "ai_image_edit_model", "type": "text", "label": "Image edit model",
   "required": false, "default": "", "secret": false}
]
EOF
  exit 0
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    f_json="{"
    f_first="yes"
    for f_field in ${f_fields}
    do
      [[ "${f_first}" == "yes" ]] || f_json="${f_json}, "
      f_first="no"
      f_val="$(f_symbios_var "${f_field}" "")"
      f_json="${f_json}\"${f_field}\": $(printf '%s' "${f_val}" | f_json_escape)"
    done
    echo "${f_json}}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  for f_field in ${f_fields}
  do
    echo "${f_field}=$(f_symbios_var "${f_field}" "")"
  done
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_image_url=""
f_image_model=""
f_image_edit_url=""
f_image_edit_model=""
f_given_image_url="no"
f_given_image_model="no"
f_given_image_edit_url="no"
f_given_image_edit_model="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --image-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_image_url="$2"
      f_given_image_url="yes"
      shift 2
      ;;
    --image-model)
      [[ $# -ge 2 ]] || f_fail_usage
      f_image_model="$2"
      f_given_image_model="yes"
      shift 2
      ;;
    --image-edit-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_image_edit_url="$2"
      f_given_image_edit_url="yes"
      shift 2
      ;;
    --image-edit-model)
      [[ $# -ge 2 ]] || f_fail_usage
      f_image_edit_model="$2"
      f_given_image_edit_model="yes"
      shift 2
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

if [[ "${f_given_image_url}" == "no" && "${f_given_image_model}" == "no" \
   && "${f_given_image_edit_url}" == "no" \
   && "${f_given_image_edit_model}" == "no" ]]
then
  f_fail_validation "Nothing to set - pass at least one field option"
fi

# URLs must be single-line without whitespace (the WebUI test probe adds
# https:// itself when the scheme is missing, so no scheme is required);
# models must be single-line. Empty values are allowed (delete the key).
for f_pair_name in ai_image_url ai_image_edit_url
do
  case "${f_pair_name}" in
    ai_image_url) f_val="${f_image_url}" ;;
    ai_image_edit_url) f_val="${f_image_edit_url}" ;;
  esac
  if [[ -n "${f_val}" ]] \
    && { [[ "${f_val}" == *$'\n'* ]] || [[ "${f_val}" =~ [[:space:]] ]]; }
  then
    f_fail_validation "Invalid ${f_pair_name}: must be a single line without whitespace"
  fi
done
for f_pair_name in ai_image_model ai_image_edit_model
do
  case "${f_pair_name}" in
    ai_image_model) f_val="${f_image_model}" ;;
    ai_image_edit_model) f_val="${f_image_edit_model}" ;;
  esac
  if [[ -n "${f_val}" && "${f_val}" == *$'\n'* ]]
  then
    f_fail_validation "Invalid ${f_pair_name}: must be a single line"
  fi
done

# --- transactional write (empty values delete the key) -------------------------

f_merge_add() {
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

f_merge="{"
f_merge_first="yes"
f_merge_add "ai_image_url" "${f_image_url}" "${f_given_image_url}"
f_merge_add "ai_image_model" "${f_image_model}" "${f_given_image_model}"
f_merge_add "ai_image_edit_url" "${f_image_edit_url}" "${f_given_image_edit_url}"
f_merge_add "ai_image_edit_model" "${f_image_edit_model}" "${f_given_image_edit_model}"
f_merge="${f_merge}}"

f_check_flag=""
[[ "${f_check}" == "yes" ]] && f_check_flag="--check"

if ! f_out="$(printf '%s' "${f_merge}" \
  | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge ${f_check_flag} 2>&1)"
then
  f_fail_technical "Failed to write inventory: ${f_out}"
fi

g_echo "${f_out}"

if [[ "${f_check}" == "yes" ]]
then
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

if grep -q "^unchanged$" <<< "${f_out}"
then
  g_echo_note "ai-image-unchanged"
else
  g_echo_note "ai-image-changed"
fi
exit 0
