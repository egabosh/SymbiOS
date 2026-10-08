#!/bin/bash
# SymbiOS - Manage AI search/RAG settings (Tika and SearXNG URLs).
#
# Settings CLI-first architecture: the WebUI page /settings/ai-search/ is
# a thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction). Empty values delete the
# key (same as the WebUI before). This domain carries no secrets, so plain
# flags are sufficient (no --json-stdin needed).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS AI search settings (Tika text extraction, SearXNG search).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--tika-url URL --searxng-url URL] [--check]
                                  Validate and write to inventory.yml.
                                  Empty values delete the key.
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (ai-search-changed / ai-search-unchanged).

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

f_fields="ai_tika_url ai_searxng_url"

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
  {"name": "ai_tika_url", "type": "url", "label": "Tika server URL",
   "required": false, "default": "", "secret": false},
  {"name": "ai_searxng_url", "type": "url", "label": "SearXNG URL",
   "required": false, "default": "", "secret": false,
   "placeholder": "https://search.example.com/search?q=<query>"}
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

f_tika_url=""
f_searxng_url=""
f_given_tika_url="no"
f_given_searxng_url="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --tika-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_tika_url="$2"
      f_given_tika_url="yes"
      shift 2
      ;;
    --searxng-url)
      [[ $# -ge 2 ]] || f_fail_usage
      f_searxng_url="$2"
      f_given_searxng_url="yes"
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

if [[ "${f_given_tika_url}" == "no" && "${f_given_searxng_url}" == "no" ]]
then
  f_fail_validation "Nothing to set - pass --tika-url and/or --searxng-url"
fi

# URLs must be single-line. The SearXNG URL may carry a <query> placeholder
# (no whitespace check beyond the newline rule); other whitespace is
# rejected. Empty values are allowed (they delete the key).
for f_val in "${f_tika_url}" "${f_searxng_url}"
do
  if [[ -n "${f_val}" && "${f_val}" == *$'\n'* ]]
  then
    f_fail_validation "URL values must be a single line"
  fi
done
if [[ -n "${f_tika_url}" && "${f_tika_url}" =~ [[:space:]] ]]
then
  f_fail_validation "Invalid ai_tika_url: must not contain whitespace"
fi

# --- transactional write (empty values delete the key) -------------------------

f_merge="{"
f_merge_first="yes"
for f_name in ${f_fields}
do
  case "${f_name}" in
    ai_tika_url)
      f_val="${f_tika_url}"
      f_given="${f_given_tika_url}"
      ;;
    ai_searxng_url)
      f_val="${f_searxng_url}"
      f_given="${f_given_searxng_url}"
      ;;
  esac
  [[ "${f_given}" == "yes" ]] || continue
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge_first="no"
  if [[ -z "${f_val}" ]]
  then
    f_merge="${f_merge}\"${f_name}\": null"
  else
    f_merge="${f_merge}\"${f_name}\": $(printf '%s' "${f_val}" | f_json_escape)"
  fi
done
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
  g_echo_note "ai-search-unchanged"
else
  g_echo_note "ai-search-changed"
fi
exit 0
