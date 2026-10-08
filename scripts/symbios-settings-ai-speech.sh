#!/bin/bash
# SymbiOS - Manage AI speech settings (STT/TTS URLs, keys, models).
#
# Settings CLI-first architecture: the WebUI page /settings/ai-speech/ is
# a thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction). Empty values delete the
# key (same as the WebUI before); empty keys fall back to ai_apikey.
#
# Secrets (ai_stt_key, ai_tts_key) MUST come via --json-stdin, never as
# argv (visible in ps). There are deliberately no --stt-key/--tts-key flags.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS AI speech settings (speech-to-text and text-to-speech).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json; secret
                                  values are never printed, only whether
                                  they are set)
  set [--stt-url URL --stt-model M --tts-url URL --tts-model M
       | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads {"ai_stt_url":..,
                                  "ai_stt_key":.., "ai_stt_model":..,
                                  "ai_tts_url":.., "ai_tts_key":..,
                                  "ai_tts_model":..} from stdin (REQUIRED
                                  for the keys). Empty values delete the
                                  key. --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (ai-speech-changed / ai-speech-unchanged).

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

# Field names of this domain (order kept for get/schema output).
f_fields="ai_stt_url ai_stt_key ai_stt_model ai_tts_url ai_tts_key ai_tts_model"

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
  {"name": "ai_stt_url", "type": "url", "label": "STT server URL",
   "required": false, "default": "", "secret": false},
  {"name": "ai_stt_key", "type": "password", "label": "STT API key",
   "required": false, "default": "", "secret": true},
  {"name": "ai_stt_model", "type": "text", "label": "STT model",
   "required": false, "default": "", "secret": false},
  {"name": "ai_tts_url", "type": "url", "label": "TTS server URL",
   "required": false, "default": "", "secret": false},
  {"name": "ai_tts_key", "type": "password", "label": "TTS API key",
   "required": false, "default": "", "secret": true},
  {"name": "ai_tts_model", "type": "text", "label": "TTS model",
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
      if [[ "${f_field}" == *"_key" ]]
      then
        if [[ -n "$(f_symbios_var "${f_field}" "")" ]]
        then
          f_json="${f_json}\"${f_field}_set\": true"
        else
          f_json="${f_json}\"${f_field}_set\": false"
        fi
      else
        # Assign first: command substitution strips the trailing newline
        # that the raw pipe would carry into the JSON string.
        f_val="$(f_symbios_var "${f_field}" "")"
        f_json="${f_json}\"${f_field}\": $(printf '%s' "${f_val}" | f_json_escape)"
      fi
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
    if [[ "${f_field}" == *"_key" ]]
    then
      if [[ -n "$(f_symbios_var "${f_field}" "")" ]]
      then
        echo "${f_field}_set=yes"
      else
        echo "${f_field}_set=no"
      fi
    else
      echo "${f_field}=$(f_symbios_var "${f_field}" "")"
    fi
  done
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_stt_url=""
f_stt_model=""
f_tts_url=""
f_tts_model=""
f_given_stt_url="no"
f_given_stt_model="no"
f_given_tts_url="no"
f_given_tts_model="no"
f_given_stt_key="no"
f_given_tts_key="no"
f_new_stt_key=""
f_new_tts_key=""
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --stt-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_stt_url="$2"
      f_given_stt_url="yes"
      shift 2
      ;;
    --stt-model)
      [[ $# -ge 2 ]] || f_fail_usage
      f_stt_model="$2"
      f_given_stt_model="yes"
      shift 2
      ;;
    --tts-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_tts_url="$2"
      f_given_tts_url="yes"
      shift 2
      ;;
    --tts-model)
      [[ $# -ge 2 ]] || f_fail_usage
      f_tts_model="$2"
      f_given_tts_model="yes"
      shift 2
      ;;
    --stt-key=*|--tts-key=*|--stt-key|--tts-key)
      f_fail_validation "STT/TTS keys are secrets and must be passed via --json-stdin, never as argv"
      ;;
    --json-stdin)
      f_json_stdin="yes"
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

if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  for f_field in ${f_fields}
  do
    if [[ "${f_json}" != *'"'"${f_field}"'"'* ]]
    then
      continue
    fi
    f_val="$(f_json_get "${f_json}" "${f_field}")" || f_val=""
    case "${f_field}" in
      ai_stt_url)
        f_stt_url="${f_val}"
        f_given_stt_url="yes"
        ;;
      ai_stt_model)
        f_stt_model="${f_val}"
        f_given_stt_model="yes"
        ;;
      ai_tts_url)
        f_tts_url="${f_val}"
        f_given_tts_url="yes"
        ;;
      ai_tts_model)
        f_tts_model="${f_val}"
        f_given_tts_model="yes"
        ;;
      ai_stt_key)
        f_new_stt_key="${f_val}"
        f_given_stt_key="yes"
        ;;
      ai_tts_key)
        f_new_tts_key="${f_val}"
        f_given_tts_key="yes"
        ;;
    esac
  done
fi

if [[ "${f_given_stt_url}" == "no" && "${f_given_stt_model}" == "no" \
   && "${f_given_tts_url}" == "no" && "${f_given_tts_model}" == "no" \
   && "${f_given_stt_key}" == "no" && "${f_given_tts_key}" == "no" ]]
then
  f_fail_validation "Nothing to set - pass field options and/or --json-stdin"
fi

# URLs must be single-line without whitespace; models and keys must be
# single-line. Empty values are allowed (they delete the key).
for f_pair_name in ai_stt_url ai_tts_url
do
  case "${f_pair_name}" in
    ai_stt_url) f_val="${f_stt_url}" ;;
    ai_tts_url) f_val="${f_tts_url}" ;;
  esac
  if [[ -n "${f_val}" ]] \
    && { [[ "${f_val}" == *$'\n'* ]] || [[ "${f_val}" =~ [[:space:]] ]]; }
  then
    f_fail_validation "Invalid ${f_pair_name}: must be a single line without whitespace"
  fi
done
for f_pair_name in ai_stt_model ai_tts_model ai_stt_key ai_tts_key
do
  case "${f_pair_name}" in
    ai_stt_model) f_val="${f_stt_model}" ;;
    ai_tts_model) f_val="${f_tts_model}" ;;
    ai_stt_key) f_val="${f_new_stt_key}" ;;
    ai_tts_key) f_val="${f_new_tts_key}" ;;
  esac
  if [[ -n "${f_val}" && "${f_val}" == *$'\n'* ]]
  then
    f_fail_validation "Invalid ${f_pair_name}: must be a single line"
  fi
done

# --- transactional write (empty values delete the key) -------------------------

# Append one key to the merge JSON: globals f_merge_first/f_merge.
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
f_merge_add "ai_stt_url" "${f_stt_url}" "${f_given_stt_url}"
f_merge_add "ai_stt_model" "${f_stt_model}" "${f_given_stt_model}"
f_merge_add "ai_tts_url" "${f_tts_url}" "${f_given_tts_url}"
f_merge_add "ai_tts_model" "${f_tts_model}" "${f_given_tts_model}"
f_merge_add "ai_stt_key" "${f_new_stt_key}" "${f_given_stt_key}"
f_merge_add "ai_tts_key" "${f_new_tts_key}" "${f_given_tts_key}"
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
  g_echo_note "ai-speech-unchanged"
else
  g_echo_note "ai-speech-changed"
fi
exit 0
