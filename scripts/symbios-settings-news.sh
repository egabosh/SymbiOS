#!/bin/bash
# SymbiOS - Manage the WebUI news feed (release notes, security notices).
#
# Settings CLI-first architecture: /settings/news/ is a thin wrapper around
# this script. The feed values are read live by symbios-news.sh (cron and
# healthcheck), so no playbook bakes them into state and f_managed_vars is
# intentionally empty.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage the SymbiOS news feed.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--enabled true|false --url URL --markers LIST | --json-stdin]
        [--check] [--no-apply]
                                  Validate and write to inventory.yml, then
                                  apply consuming playbooks unless --no-apply
                                  is given. Options left out keep their current
                                  value. An empty --url restores the default
                                  releases feed. --markers is a comma-separated
                                  list of severity markers (security, critical,
                                  ...). --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  apply [--dry-run]               Nothing to apply: the feed scripts read the
                                  values live from inventory.yml.
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (news-changed / news-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

# Inventory keys read live by the feed scripts (no playbook consumer).
f_managed_vars=""
g_news_url_default="https://github.com/egabosh/SymbiOS/releases.atom"
g_news_markers_default="security,critical"

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema|apply)
    shift
    ;;
  *)
    g_echo_error "Unknown command: ${f_command}"
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "apply" ]]
then
  f_ss_apply_cmd "$@"
  exit $?
fi

if [[ "${f_command}" == "schema" ]]
then
  cat << EOF
[
  {"name": "news_enabled", "type": "bool", "label": "Show SymbiOS news",
   "required": false, "default": false, "secret": false},
  {"name": "news_feed_url", "type": "text", "label": "RSS/Atom feed URL",
   "required": false, "default": "${g_news_url_default}", "secret": false,
   "note": "RSS 2.0 or Atom. Leave empty to use the default. GitHub releases, commits and tags all provide an Atom feed."},
  {"name": "news_severity_markers", "type": "text", "label": "Severity markers",
   "required": false, "default": "${g_news_markers_default}", "secret": false,
   "note": "Comma-separated. A feed category or title containing one of these words (case-insensitive) is highlighted and raises a health warning until marked as read."}
]
EOF
  exit 0
fi

f_cur_enabled="$(f_symbios_var news_enabled "")"
if [[ "${f_cur_enabled}" == "True" || "${f_cur_enabled}" == "true" ]]
then
  f_cur_enabled="true"
else
  f_cur_enabled="false"
fi
f_cur_url="$(f_symbios_var news_feed_url "")"
[[ -n "${f_cur_url}" ]] || f_cur_url="${g_news_url_default}"
f_cur_markers="$(f_symbios_var news_severity_markers "")"
[[ -n "${f_cur_markers}" ]] || f_cur_markers="${g_news_markers_default}"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"news_enabled": %s, "news_feed_url": %s, "news_severity_markers": %s}\n' \
      "${f_cur_enabled}" \
      "$(printf '%s' "${f_cur_url}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_markers}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    g_echo_error "Unknown option for get: $1"
    f_ss_fail_usage
  fi
  echo "news_enabled=${f_cur_enabled}"
  echo "news_feed_url=${f_cur_url}"
  echo "news_severity_markers=${f_cur_markers}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_enabled=""
f_given_enabled="no"
f_new_url=""
f_given_url="no"
f_new_markers=""
f_given_markers="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --enabled)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_enabled="$2"
      f_given_enabled="yes"
      shift 2
      ;;
    --enabled=*)
      f_new_enabled="${1#--enabled=}"
      f_given_enabled="yes"
      shift
      ;;
    --url)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_url="$2"
      f_given_url="yes"
      shift 2
      ;;
    --url=*)
      f_new_url="${1#--url=}"
      f_given_url="yes"
      shift
      ;;
    --markers)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_markers="$2"
      f_given_markers="yes"
      shift 2
      ;;
    --markers=*)
      f_new_markers="${1#--markers=}"
      f_given_markers="yes"
      shift
      ;;
    --json-stdin)
      f_json="$(cat)"
      if [[ "${f_json}" == *'"news_enabled"'* ]]
      then
        f_new_enabled="$(printf '%s' "${f_json}" | jq -r 'if has("news_enabled") then (.news_enabled | tostring) else empty end')"
        f_given_enabled="yes"
      fi
      if [[ "${f_json}" == *'"news_feed_url"'* ]]
      then
        f_new_url="$(f_json_get "${f_json}" "news_feed_url")" || f_new_url=""
        f_given_url="yes"
      fi
      if [[ "${f_json}" == *'"news_severity_markers"'* ]]
      then
        f_new_markers="$(f_json_get "${f_json}" "news_severity_markers")" || f_new_markers=""
        f_given_markers="yes"
      fi
      shift
      ;;
    --check)
      f_check="yes"
      shift
      ;;
    --no-apply)
      g_ss_no_apply="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_ss_fail_usage
      ;;
  esac
done

if [[ "${f_given_enabled}" == "no" && "${f_given_url}" == "no" && "${f_given_markers}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass --enabled, --url or --markers"
fi

if [[ "${f_given_enabled}" == "yes" ]]
then
  if ! f_parsed_enabled="$(f_ss_parse_bool "${f_new_enabled}")"
  then
    f_ss_fail_validation "Invalid --enabled value: ${f_new_enabled} (expected true|false)"
  fi
  f_new_enabled="${f_parsed_enabled}"
fi

if [[ "${f_given_url}" == "yes" && -n "${f_new_url}" ]]
then
  f_ss_require_url "news_feed_url" "${f_new_url}"
  case "${f_new_url}" in
    http://*|https://*)
      ;;
    *)
      f_ss_fail_validation "Invalid news_feed_url: must start with http:// or https://"
      ;;
  esac
fi

# --- transactional write -------------------------------------------------------

f_merge="{"
f_merge_first="yes"
if [[ "${f_given_enabled}" == "yes" ]]
then
  f_merge="${f_merge}\"news_enabled\": ${f_new_enabled}"
  f_merge_first="no"
fi
if [[ "${f_given_url}" == "yes" ]]
then
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge="${f_merge}\"news_feed_url\": $(printf '%s' "${f_new_url}" | f_json_escape)"
  f_merge_first="no"
fi
if [[ "${f_given_markers}" == "yes" ]]
then
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge="${f_merge}\"news_severity_markers\": $(printf '%s' "${f_new_markers}" | f_json_escape)"
fi
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "news" "${f_check}"
f_ss_finish
exit $?
