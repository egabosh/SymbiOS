#!/bin/bash
# SymbiOS - End-to-end self-test for the WebUI settings pages.
#
# Walks every registry settings page (/settings/<slug>/): GET must render
# (HTTP 200), POSTing the current values back must succeed (job or
# redirect answer, never an error), and an invalid value must answer 400.
# Secrets are never sent (empty secrets mean "keep stored").
#
# SAFE BY CONSTRUCTION: writes only ever store the already-stored values
# (read first, post back unchanged), so the inventory must be byte-identical
# afterwards - verified at the end against a snapshot. Run on the SymbiOS
# host (needs the WebUI on localhost:8080 and the inventory path).
#
# Usage: symbios-webui-selftest.sh [--base URL] [--slug slug]
#   --base URL   WebUI base URL (default http://localhost:8080)
#   --slug slug  test only one registry slug (default: all)
#
# Exit codes: 0 all green, 1 at least one failure (details on stderr).

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--base URL] [--slug slug]

End-to-end self-test for the WebUI settings pages (generic renderer).

For every registry slug: GET renders HTTP 200, POSTing current values
succeeds, invalid input answers 400. Only idempotent writes (current
values back); the inventory must be byte-identical afterwards.

Options:
  --base URL   WebUI base URL (default: http://localhost:8080)
  --slug slug  Test only one registry slug (default: all)
  -h, --help   Show this help and exit

Exit codes:
  0  all green
  1  at least one failure
EOF
}

f_base="http://localhost:8080"
f_only=""

while [[ $# -gt 0 ]]
do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { f_usage >&2; exit 1; }
      f_base="$2"
      shift 2
      ;;
    --slug)
      [[ $# -ge 2 ]] || { f_usage >&2; exit 1; }
      f_only="$2"
      shift 2
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      f_usage >&2
      exit 1
      ;;
  esac
done

source /etc/bash/gaboshlib.include 2>/dev/null || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh" 2>/dev/null || true
# Inventory location (same derivation as symbios-lib.sh).
g_inventory="${CONFIG_PATH:-${g_symbios_dir}/../../base-services/symbios-ui/config/inventory.yml}"
if [[ ! -f "${g_inventory}" ]]
then
  g_inventory="/symbios/base-services/symbios-ui/config/inventory.yml"
fi

f_failures=0

function f_pass {
  g_echo "SELFTEST PASS: $1" 2>/dev/null || echo "SELFTEST PASS: $1"
}

function f_fail {
  g_echo_error "SELFTEST FAIL: $1" 2>/dev/null || echo "SELFTEST FAIL: $1" >&2
  f_failures=$((f_failures + 1))
}

# Registry slugs with their scripts (mirrors settings_registry.py; the
# self-test stays independent of Django so it also runs pre-deploy).
# Only generically rendered pages: dedicated rich pages (backup, dns,
# mailserver, ...) have custom field handling the uniform POST cannot
# reproduce.
f_slugs="localization ai ai-speech ai-image ai-search auth acme security media matrix notifications"
f_scripts="symbios-settings-localization.sh symbios-settings-ai.sh symbios-settings-ai-speech.sh symbios-settings-ai-image.sh symbios-settings-ai-search.sh symbios-settings-auth.sh symbios-settings-acme.sh symbios-settings-security.sh symbios-settings-media.sh symbios-settings-matrix.sh symbios-settings-notifications.sh"

# Snapshot the inventory for the final byte-identical check.
f_snapshot="$(mktemp /tmp/symbios-selftest-inv.XXXXXX)"
cp "${g_inventory}" "${f_snapshot}" 2>/dev/null || {
  echo "Cannot read inventory at ${g_inventory}" >&2
  exit 1
}
trap 'rm -f "${f_snapshot}" "${f_cookies}"' EXIT

f_cookies="$(mktemp /tmp/symbios-selftest-cookies.XXXXXX)"
f_idx=0
for f_slug in ${f_slugs}
do
  f_idx=$((f_idx + 1))
  f_script="$(echo "${f_scripts}" | cut -d' ' -f"${f_idx}")"
  if [[ -n "${f_only}" && "${f_slug}" != "${f_only}" ]]
  then
    continue
  fi

  # 1. GET renders (one retry: the first call warms caches/SSH).
  f_code=""
  for f_try in 1 2
  do
    f_code="$(curl -s -c "${f_cookies}" -o /dev/null -w '%{http_code}' \
      "${f_base}/settings/${f_slug}/" --max-time 60)"
    [[ "${f_code}" == "200" ]] && break
    sleep 5
  done
  if [[ "${f_code}" == "200" ]]
  then
    f_pass "${f_slug} GET 200"
  else
    f_fail "${f_slug} GET returned ${f_code}"
    continue
  fi

  # CSRF token for the POSTs below.
  f_token="$(awk '/csrftoken/ {print $NF}' "${f_cookies}" | tail -1)"
  if [[ -z "${f_token}" ]]
  then
    f_fail "${f_slug} no CSRF token"
    continue
  fi

  # 2. POST current values back (idempotent by construction).
  f_values="$("${f_script}" get --json 2>/dev/null)" || f_values=""
  if [[ -z "${f_values}" ]]
  then
    f_fail "${f_slug} get --json failed"
    continue
  fi
  # Drop secret values (empty means keep stored); drop *_set hints.
  # The generic view reads one form field per schema name, so expand the
  # JSON object into a curl config file (avoids all shell quoting issues
  # with values holding spaces or quotes).
  f_cfg="$(mktemp /tmp/symbios-selftest-curl.XXXXXX)"
  printf '%s' "${f_values}" | python3 -c "
import json, sys
try:
    values = json.load(sys.stdin)
except Exception:
    values = {}
for k, v in values.items():
    if k.endswith('_set'):
        continue
    if isinstance(v, bool):
        v = 'true' if v else 'false'
    elif not isinstance(v, str):
        v = json.dumps(v)
    if v == '' and any(s in k for s in ('key', 'pass', 'token', 'secret')):
        continue
    safe = v.replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')
    print('data-urlencode = \"%s=%s\"' % (k, safe))
" > "${f_cfg}"
  f_resp="$(curl -s -b "${f_cookies}" -H "X-CSRFToken: ${f_token}" \
    -H 'X-Requested-With: XMLHttpRequest' \
    -K "${f_cfg}" \
    "${f_base}/settings/${f_slug}/" --max-time 120)"
  rm -f "${f_cfg}"
  if [[ "${f_resp}" == *'"ok": true'* ]] || [[ "${f_resp}" == *'"ok":true'* ]]
  then
    f_pass "${f_slug} POST idempotent ok"
  else
    f_fail "${f_slug} POST idempotent: ${f_resp:0:200}"
  fi
done

# 3. Invalid input must answer 400 without writing (localization locale).
f_locale_resp="$(curl -s -b "${f_cookies}" -H "X-CSRFToken: $(awk '/csrftoken/ {print $NF}' "${f_cookies}" | tail -1)" \
  -H 'X-Requested-With: XMLHttpRequest' \
  --data-urlencode 'timezone=Europe/Berlin' \
  --data-urlencode 'keyboard=de' \
  --data-urlencode 'locale=BAD LOCALE!' \
  "${f_base}/settings/localization/" --max-time 60)"
if [[ "${f_locale_resp}" == *'"ok": false'* ]]
then
  f_pass "localization POST invalid -> ok:false"
else
  f_fail "localization POST invalid: ${f_locale_resp:0:200}"
fi

# 4. Inventory must be byte-identical (all writes were no-ops). If a
# POST added missing default keys or removed an empty default, restore
# the snapshot so testing never leaves drift behind - but still fail,
# because a truly idempotent round-trip writes nothing at all.
if cmp -s "${f_snapshot}" "${g_inventory}"
then
  f_pass "inventory byte-identical"
else
  f_fail "inventory changed during self-test (restoring snapshot):"
  diff "${f_snapshot}" "${g_inventory}" | head -10 >&2
  if cp "${f_snapshot}" "${g_inventory}" \
    && cmp -s "${f_snapshot}" "${g_inventory}"
  then
    g_echo_note "snapshot restored" 2>/dev/null || echo "snapshot restored"
  else
    g_echo_error "FAILED TO RESTORE inventory snapshot!" 2>/dev/null \
      || echo "FAILED TO RESTORE inventory snapshot!" >&2
  fi
fi

if [[ "${f_failures}" -gt 0 ]]
then
  echo "${f_failures} self-test check(s) failed" >&2
  echo "${f_failures} self-test check(s) failed (see errors above)"
  exit 1
fi
echo "WebUI self-test: all green"
exit 0
