#!/bin/bash
# SymbiOS - Convention checks for the settings CLI-first architecture.
#
# Two modes (see AGENTS.md, Scaffolding/lint/tests):
#   symbios-settings-check.sh --static [ROOT]  repo-level greps, runs
#     anywhere (CI-safe, no host needed)
#   symbios-settings-check.sh [slug]           live contract checks, runs
#     on the host (needs inventory + sibling scripts on PATH)
#
# Live checks per script: --help exits 0, get exits 0, schema is valid
# JSON, an unknown command exits 2. Static checks: no direct inventory
# writes in WebUI views, every settings script sources the shared lib
# and dispatches get/set/schema, no secret travels as argv.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--static [ROOT] | [slug]]

Convention checks for the settings CLI-first architecture.

  --static [ROOT]   Static repo checks (default ROOT: git repo auto-detect).
                    Fails on: direct inventory writes in webui views,
                    settings scripts without the shared lib, missing
                    get/set/schema dispatch, secrets as CLI flags.
  [slug]            Live contract check for one settings script
                    (symbios-settings-<slug>.sh), or all when omitted.
                    Fails on: --help/get non-zero, schema not JSON,
                    unknown command not exit 2.

Examples:
  $(basename "$0") --static
  $(basename "$0") dns
  $(basename "$0")

Exit codes:
  0  all checks pass
  1  at least one check failed (or technical error)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

source /etc/bash/gaboshlib.include 2>/dev/null || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"

f_failures=0

function f_check {
  local f_name="$1"
  shift
  if "$@" >/dev/null 2>&1
  then
    g_echo "PASS: ${f_name}" 2>/dev/null || echo "PASS: ${f_name}"
  else
    g_echo_error "FAIL: ${f_name}" 2>/dev/null || echo "FAIL: ${f_name}" >&2
    f_failures=$((f_failures + 1))
  fi
}

# --- static mode ---------------------------------------------------------------

if [[ "${1:-}" == "--static" ]]
then
  f_root="${2:-}"
  if [[ -z "${f_root}" ]]
  then
    if git rev-parse --show-toplevel >/dev/null 2>&1
    then
      f_root="$(git rev-parse --show-toplevel)"
    else
      f_root="${g_symbios_dir}/.."
    fi
  fi

  # 1. No direct inventory writes in WebUI views.
  if grep -rn "_save_inventory_config(" "${f_root}/webui/main/"*.py 2>/dev/null | grep -v __pycache__ | grep -v "def _save_inventory_config" | grep -q .
  then
    g_echo_error "FAIL: direct inventory writes in webui views" 2>/dev/null || echo "FAIL: direct inventory writes in webui views" >&2
    grep -rn "_save_inventory_config(" "${f_root}/webui/main/"*.py 2>/dev/null | grep -v __pycache__ | grep -v "def _save_inventory_config"
    f_failures=$((f_failures + 1))
  else
    g_echo "PASS: no direct inventory writes in webui views" 2>/dev/null || echo "PASS: no direct inventory writes in webui views"
  fi

  # 2-4. Per settings script: shared lib, dispatch, no secrets in argv.
  for f_script in "${f_root}"/scripts/symbios-settings-*.sh
  do
    [[ -f "${f_script}" ]] || continue
    # skip libs, tooling and the docs generator (no get/set/schema contract)
    case "${f_script}" in
      *-lib.sh|*-new.sh|*-check.sh|*-docs.sh) continue ;;
    esac
    f_base="$(basename "${f_script}")"
    grep -q 'source "\$g_symbios_dir/symbios-settings-lib.sh"' "${f_script}" \
      && g_echo "PASS: ${f_base} sources shared lib" 2>/dev/null || { echo "FAIL: ${f_base} sources shared lib" >&2; f_failures=$((f_failures + 1)); }
    if grep -q "get|set|schema)" "${f_script}"
    then
      g_echo "PASS: ${f_base} dispatches get/set/schema" 2>/dev/null || echo "PASS: ${f_base} dispatches get/set/schema"
    else
      # allow scripts with custom dispatch (openvpn has list, ssh-keys too)
      if grep -qE "get\||\|get\||list\|" "${f_script}"
      then
        g_echo "PASS: ${f_base} dispatches get/set/schema (custom)" 2>/dev/null || echo "PASS: ${f_base} dispatches get/set/schema (custom)"
      else
        echo "FAIL: ${f_base} dispatches get/set/schema" >&2
        f_failures=$((f_failures + 1))
      fi
    fi
    # A secret flag is only a violation when the value is accepted. Case
    # labels (--x|--x=*) are the rejection-guard idiom (followed by a
    # fail), as are comments documenting the deliberate absence.
    if grep -E '\-\-(ai-apikey|ai_apikey|stt-key|tts-key|ddns-apikey|password|apikey|api-key)[= ]' "${f_script}" \
      | grep -v "never as argv\|must be passed via\|deliberately no" \
      | grep -Ev "^[[:space:]]*--.*\)[[:space:]]*$" | grep -q .; then
      echo "FAIL: ${f_base} takes a secret as argv flag" >&2
      f_failures=$((f_failures + 1))
    else
      g_echo "PASS: ${f_base} takes no secret as argv flag" 2>/dev/null || echo "PASS: ${f_base} takes no secret as argv flag"
    fi
  done

  if [[ "${f_failures}" -gt 0 ]]
  then
    echo "${f_failures} static check(s) failed" >&2
    exit 1
  fi
  echo "All static checks pass"
  exit 0
fi

# --- live mode -------------------------------------------------------------------

f_only="${1:-}"
f_scripts=()
if [[ -n "${f_only}" ]]
then
  f_scripts=("symbios-settings-${f_only}.sh")
else
  for f_path in "${g_symbios_dir}"/symbios-settings-*.sh
  do
    case "${f_path}" in
      *-lib.sh|*-new.sh|*-check.sh) continue ;;
    esac
    f_scripts+=("$(basename "${f_path}")")
  done
fi

for f_script in "${f_scripts[@]}"
do
  if ! command -v "${f_script}" >/dev/null 2>&1 && [[ ! -x "${g_symbios_dir}/${f_script}" ]]
  then
    g_echo_error "FAIL: ${f_script} not found" 2>/dev/null || echo "FAIL: ${f_script} not found" >&2
    f_failures=$((f_failures + 1))
    continue
  fi
  f_bin="${f_script}"
  command -v "${f_script}" >/dev/null 2>&1 || f_bin="${g_symbios_dir}/${f_script}"
  f_check "${f_script} --help" "${f_bin}" --help
  # get vs list: read-capable verbs differ per backend (dict/file domains).
  if "${f_bin}" --help 2>&1 | grep -q "list \[--json\]"
  then
    f_check "${f_script} list" "${f_bin}" list
  else
    f_check "${f_script} get" "${f_bin}" get
  fi
  if f_schema="$("${f_bin}" schema 2>/dev/null)" \
    && printf '%s' "${f_schema}" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
  then
    g_echo "PASS: ${f_script} schema" 2>/dev/null || echo "PASS: ${f_script} schema"
  else
    g_echo_error "FAIL: ${f_script} schema" 2>/dev/null || echo "FAIL: ${f_script} schema" >&2
    f_failures=$((f_failures + 1))
  fi
  if "${f_bin}" bogus-command-xyz >/dev/null 2>&1
  then
    g_echo_error "FAIL: ${f_script} bogus exits 0" 2>/dev/null || echo "FAIL: ${f_script} bogus exits 0" >&2
    f_failures=$((f_failures + 1))
  else
    f_rc=$?
    if [[ "${f_rc}" == "2" ]]
    then
      g_echo "PASS: ${f_script} bogus exits 2" 2>/dev/null || echo "PASS: ${f_script} bogus exits 2"
    else
      g_echo_error "FAIL: ${f_script} bogus exits ${f_rc}" 2>/dev/null || echo "FAIL: ${f_script} bogus exits ${f_rc}" >&2
      f_failures=$((f_failures + 1))
    fi
  fi
done

if [[ "${f_failures}" -gt 0 ]]
then
  echo "${f_failures} live check(s) failed" >&2
  exit 1
fi
echo "All live checks pass"
exit 0
