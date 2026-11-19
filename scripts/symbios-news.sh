#!/bin/bash
# SymbiOS - Refresh and acknowledge the WebUI news feed snapshot.
#
# Reads news_enabled, news_feed_url and news_severity_markers from
# inventory.yml (live, no playbook reapply needed), fetches the feed with
# curl, parses it with symbios-news.py and writes <log>/news.json atomically.
# The WebUI and the news healthcheck only read that snapshot.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Refresh or acknowledge the SymbiOS news feed.

Commands:
  refresh                 Fetch the configured feed and refresh <log>/news.json.
                          A failed fetch keeps the previous items and marks the
                          snapshot status as "error".
  ack <id|all>            Mark one alert item (or all current ones) as read.
  get                     Print the current snapshot JSON.
  -h, --help              Show this help and exit

Output: status lines for refresh/ack, JSON for get.
Exit codes: 0 ok, 2 usage error, 1 technical error.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_lockfile

g_news_snapshot="${g_log_dir}/news.json"
g_news_seen="${g_config_dir}/news/seen.json"
g_news_url_default="https://github.com/egabosh/SymbiOS/releases.atom"
g_news_markers_default="security,critical"

function f_now {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Create a valid seen-state file on first run (and repair a corrupt one).
function f_ensure_seen {
  mkdir -p "$(dirname "$g_news_seen")"
  if [[ ! -s "$g_news_seen" ]] || ! jq -e . "$g_news_seen" >/dev/null 2>&1
  then
    printf '{"acked_ids":[],"updated":"","initialized":false}\n' > "${g_news_seen}.tmp"
    mv -f "${g_news_seen}.tmp" "$g_news_seen"
  fi
}

# Rebuild the snapshot from its items plus the current seen state. Both the
# WebUI and the healthcheck read the derived unread list, so it is computed
# in one place instead of twice.
function f_write_snapshot {
  local f_status="$1" f_error="$2" f_items="$3" f_url="$4" f_updated="$5"
  local f_existing f_checked
  f_existing="$(cat "$g_news_snapshot" 2>/dev/null)"
  [[ -n "$f_existing" ]] || f_existing='{}'
  f_checked="$(f_now)"
  if [[ -z "$f_updated" ]]
  then
    f_updated="$(jq -r '.updated // ""' <<< "$f_existing")"
    [[ -n "$f_updated" ]] || f_updated="$f_checked"
  fi
  f_ensure_seen
  jq -n \
    --argjson items "$f_items" \
    --argjson seen "$(cat "$g_news_seen")" \
    --arg status "$f_status" \
    --arg error "$f_error" \
    --arg url "$f_url" \
    --arg updated "$f_updated" \
    --arg checked "$f_checked" \
    '($seen.acked_ids // []) as $acked
     | ($items | map(select(.severity == "alert"))) as $alerts
     | ($alerts | map(.id as $id | select(($acked | index($id)) == null))) as $unread
     | {status: $status, error: $error, feed_url: $url, updated: $updated,
        checked: $checked, items: $items, unread: ($unread | length),
        unread_alerts: ($unread | map({id: .id, title: .title, link: .link}))}' \
    > "${g_news_snapshot}.tmp" || return 1
  mv -f "${g_news_snapshot}.tmp" "$g_news_snapshot"
}

# Fetch and parse the configured feed. Fetch errors are reported in the
# snapshot only: the healthcheck owns notifications, so an hourly cron run
# never sends a message by itself.
function f_refresh {
  local f_enabled f_url f_markers f_feed_tmp f_items_tmp f_error f_items f_ids
  f_enabled="$(f_symbios_var news_enabled "false")"
  if [[ "${f_enabled}" == "True" || "${f_enabled}" == "true" ]]
  then
    f_enabled="true"
  else
    f_enabled="false"
  fi
  f_url="$(f_symbios_var news_feed_url "")"
  # A cleared or missing URL still uses the built-in releases feed, so a
  # settings save that only flips the switch cannot disable the feed by accident.
  [[ -n "${f_url}" ]] || f_url="${g_news_url_default}"

  if [[ "${f_enabled}" != "true" || -z "${f_url}" ]]
  then
    f_write_snapshot "disabled" "" "[]" "" "$(f_now)" || return 1
    g_echo "News feed is disabled - snapshot cleared."
    return 0
  fi

  f_markers="$(f_symbios_var news_severity_markers "${g_news_markers_default}")"
  f_feed_tmp="$(mktemp)"
  f_items_tmp="$(mktemp)"

  if ! curl -fsSL --connect-timeout 10 --max-time 30 \
      -o "$f_feed_tmp" "$f_url" 2>"${f_feed_tmp}.err"
  then
    f_error="Feed fetch failed: $(head -c 200 "${f_feed_tmp}.err" 2>/dev/null)"
    f_items="$(jq -c '.items // []' "$g_news_snapshot" 2>/dev/null || printf '[]')"
    f_write_snapshot "error" "$f_error" "$f_items" "$f_url" "" || return 1
    g_echo "$f_error"
    rm -f "$f_feed_tmp" "$f_feed_tmp.err" "$f_items_tmp" "$f_items_tmp.err"
    return 0
  fi

  if ! python3 "${g_symbios_dir}/symbios-news.py" "$f_feed_tmp" \
      --markers "$f_markers" --limit 50 > "$f_items_tmp" 2>"${f_items_tmp}.err"
  then
    f_error="Feed parse failed: $(head -c 200 "${f_items_tmp}.err" 2>/dev/null)"
    f_items="$(jq -c '.items // []' "$g_news_snapshot" 2>/dev/null || printf '[]')"
    f_write_snapshot "error" "$f_error" "$f_items" "$f_url" "" || return 1
    g_echo "$f_error"
    rm -f "$f_feed_tmp" "$f_feed_tmp.err" "$f_items_tmp" "$f_items_tmp.err"
    return 0
  fi

  f_items="$(jq -c '.items // []' "$f_items_tmp")" || return 1

  # First successful fetch: accept everything already in the feed as seen,
  # so historical security posts do not raise an alert. Only newer items
  # (or ones added later) count as unread.
  f_ensure_seen
  if [[ "$(jq -r '.initialized // false' "$g_news_seen")" != "true" ]]
  then
    f_ids="$(jq -c '[.[].id]' <<< "$f_items")" || return 1
    jq -n --argjson ids "$f_ids" --arg now "$(f_now)" \
      '{acked_ids: $ids, updated: $now, initialized: true}' \
      > "${g_news_seen}.tmp" || return 1
    mv -f "${g_news_seen}.tmp" "$g_news_seen"
  fi

  f_write_snapshot "ok" "" "$f_items" "$f_url" "$(f_now)" || return 1
  g_echo "News feed refreshed: $(jq -r '.items | length' "$g_news_snapshot") items, $(jq -r '.unread' "$g_news_snapshot") unread alert(s)."
  rm -f "$f_feed_tmp" "$f_feed_tmp.err" "$f_items_tmp" "$f_items_tmp.err"
}

# Add ids to the seen state and rebuild the derived unread list.
function f_ack {
  local f_target="${1:-}" f_ids f_snapshot f_status f_error f_url f_items
  if [[ -z "$f_target" ]]
  then
    g_echo_error "ack needs an item id or 'all'"
    f_usage >&2
    exit 2
  fi
  if [[ ! -s "$g_news_snapshot" ]]
  then
    g_echo_error "No news snapshot yet."
    exit 1
  fi
  f_snapshot="$(cat "$g_news_snapshot")"
  if [[ "$f_target" == "all" ]]
  then
    f_ids="$(jq -c '[.items[] | select(.severity == "alert") | .id]' <<< "$f_snapshot")"
  else
    f_ids="$(jq -nc --arg id "$f_target" '[$id]')"
  fi
  f_ensure_seen
  jq -n \
    --argjson old "$(cat "$g_news_seen")" \
    --argjson add "$f_ids" \
    --arg now "$(f_now)" \
    '{acked_ids: ((($old.acked_ids // []) + $add) | unique | .[-200:]),
      updated: $now, initialized: ($old.initialized // true)}' > "${g_news_seen}.tmp" || return 1
  mv -f "${g_news_seen}.tmp" "$g_news_seen"

  f_status="$(jq -r '.status // "ok"' <<< "$f_snapshot")"
  f_error="$(jq -r '.error // ""' <<< "$f_snapshot")"
  f_url="$(jq -r '.feed_url // ""' <<< "$f_snapshot")"
  f_items="$(jq -c '.items // []' <<< "$f_snapshot")"
  f_write_snapshot "$f_status" "$f_error" "$f_items" "$f_url" "" || return 1
  g_echo "Marked ${f_target} as read."
}

case "${1:-}" in
  refresh)
    f_refresh
    ;;
  ack)
    shift
    f_ack "$@"
    ;;
  get)
    cat "$g_news_snapshot" 2>/dev/null || printf '{}\n'
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac
