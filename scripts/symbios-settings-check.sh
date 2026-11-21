#!/bin/bash
# SymbiOS - Convention checks for the settings CLI-first architecture.
#
# Two modes (see AGENTS.md, Scaffolding/lint/tests):
#   symbios-settings-check.sh --static [ROOT]  repo-level greps, runs
#     anywhere (CI-safe, no host needed)
#   symbios-settings-check.sh [slug]           live contract checks, runs
#     on the host (needs inventory + sibling scripts on PATH)
#
# Live checks per script: --help exits 0, apply --dry-run exits 0, get
# exits 0, schema is valid JSON, an unknown command exits 2. Static checks:
# no direct inventory writes in WebUI views, every settings script sources
# the shared lib and dispatches get/set/schema/apply, declares
# f_managed_vars, every managed var has a uses_vars consumer, no secret
# travels as argv, and every base-service is either in install.sh or marked
# with an explicit install_mode exception.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--static [ROOT] | [slug]]

Convention checks for the settings CLI-first architecture.

  --static [ROOT]   Static repo checks (default ROOT: git repo auto-detect).
                    Fails on: direct inventory writes in webui views,
                    settings scripts without the shared lib, missing
                    get/set/schema dispatch, secrets as CLI flags, and
                    base-services missing from install.sh without an
                    install_mode exception.
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
    if grep -q "|apply)" "${f_script}"
    then
      g_echo "PASS: ${f_base} dispatches apply" 2>/dev/null || echo "PASS: ${f_base} dispatches apply"
    else
      echo "FAIL: ${f_base} dispatches apply" >&2
      f_failures=$((f_failures + 1))
    fi
    if grep -q '^f_managed_vars=' "${f_script}"
    then
      g_echo "PASS: ${f_base} declares f_managed_vars" 2>/dev/null || echo "PASS: ${f_base} declares f_managed_vars"
    else
      echo "FAIL: ${f_base} declares f_managed_vars" >&2
      f_failures=$((f_failures + 1))
    fi
  done

  # 5. uses_vars coverage (hard fail): every var a settings script manages
  # must be declared in uses_vars of at least one host playbook - that is
  # what the apply resolver reads. Declarations are `#   uses_vars:` plus
  # `#     - <bare word>` lines (other docs lists carry colons/quotes or
  # deeper indent and never match the anchored pattern).
  f_declared="$(grep -h -A25 '^#   uses_vars:' "${f_root}"/base-services/*.yml "${f_root}"/services/*.yml 2>/dev/null \
    | grep -o '^#     - [a-z0-9_]*$' | awk '{print $3}' | sort -u)"
  if [[ -z "${f_declared}" ]]
  then
    echo "FAIL: no uses_vars declarations found" >&2
    f_failures=$((f_failures + 1))
  else
    for f_script in "${f_root}"/scripts/symbios-settings-*.sh
    do
      case "${f_script}" in
        *-lib.sh|*-new.sh|*-check.sh|*-docs.sh) continue ;;
      esac
      f_base="$(basename "${f_script}")"
      f_managed="$(grep '^f_managed_vars=' "${f_script}" | head -1 | cut -d'"' -f2)"
      for f_var in ${f_managed}
      do
        if printf '%s\n' "${f_declared}" | grep -qx "${f_var}"
        then
          :
        else
          echo "FAIL: ${f_base} manages ${f_var} with no uses_vars consumer" >&2
          f_failures=$((f_failures + 1))
        fi
      done
    done
    g_echo "PASS: uses_vars coverage checked" 2>/dev/null || echo "PASS: uses_vars coverage checked"
  fi

  # 6. No-argument contract: a script whose usage says "no arguments" must
  # reject stray arguments (f_no_args from symbios-lib.sh or an inline
  # `[[ $# -gt 0 ]]` guard), so a typo cannot trigger the default action.
  # Libraries are sourced (no own argv), the checker itself takes a mode.
  f_noargs_fail=0
  for f_script in "${f_root}"/scripts/*.sh
  do
    [[ -f "${f_script}" ]] || continue
    case "${f_script}" in
      *-lib.sh|*/symbios-settings-check.sh) continue ;;
    esac
    grep -qi 'no arguments' "${f_script}" || continue
    if ! grep -qE 'f_no_args|\[\[ *\$\# *-gt *0 *\]\]' "${f_script}"
    then
      echo "FAIL: $(basename "${f_script}") documents no arguments but accepts them" >&2
      f_noargs_fail=1
    fi
  done
  if [[ "${f_noargs_fail}" -eq 0 ]]
  then
    g_echo "PASS: no-argument contract (usage marker => guard)" 2>/dev/null || echo "PASS: no-argument contract (usage marker => guard)"
  else
    f_failures=$((f_failures + 1))
  fi

  # 7. Every settings script with a write path must finish with f_ss_finish
  # and expose --no-apply, so `set` applies its consumers exactly once while
  # tests and low-level callers can write inventory only (AP2).
  f_finish_fail=0
  for f_script in "${f_root}"/scripts/symbios-settings-*.sh
  do
    [[ -f "${f_script}" ]] || continue
    case "${f_script}" in
      *-lib.sh|*-new.sh|*-check.sh|*-docs.sh) continue ;;
    esac
    grep -q 'f_ss_finish' "${f_script}" || {
      echo "FAIL: $(basename "${f_script}") never calls f_ss_finish" >&2
      f_finish_fail=1
    }
    grep -q -- '--no-apply' "${f_script}" || {
      echo "FAIL: $(basename "${f_script}") has no --no-apply escape hatch" >&2
      f_finish_fail=1
    }
  done
  if [[ "${f_finish_fail}" -eq 0 ]]
  then
    g_echo "PASS: all settings scripts finish and support --no-apply" 2>/dev/null || echo "PASS: all settings scripts finish and support --no-apply"
  else
    f_failures=$((f_failures + 1))
  fi

  # 8. Migrated settings views must not hardcode playbook names any more:
  # the settings CLI resolves consumers from uses_vars (AP2).
  f_view_fail=0
  if grep -rn "symbios-run-playbook.sh\|run_playbook(" \
    "${f_root}"/webui/main/views_settings*.py \
    "${f_root}"/webui/main/views_mailserver.py \
    "${f_root}"/webui/main/views_network_bridges.py \
    "${f_root}"/webui/main/views_wireguard.py \
    "${f_root}"/webui/main/views_openvpn.py \
    "${f_root}"/webui/main/views_port_forwarding.py 2>/dev/null \
    | grep -v __pycache__ | grep -q .
  then
    echo "FAIL: hardcoded playbook name in a settings view" >&2
    grep -rn "symbios-run-playbook.sh\|run_playbook(" \
      "${f_root}"/webui/main/views_settings*.py \
      "${f_root}"/webui/main/views_mailserver.py \
      "${f_root}"/webui/main/views_network_bridges.py \
      "${f_root}"/webui/main/views_wireguard.py \
      "${f_root}"/webui/main/views_openvpn.py \
      "${f_root}"/webui/main/views_port_forwarding.py 2>/dev/null | grep -v __pycache__
    f_view_fail=1
  fi
  if [[ "${f_view_fail}" -eq 0 ]]
  then
    g_echo "PASS: no hardcoded playbook names in settings views" 2>/dev/null || echo "PASS: no hardcoded playbook names in settings views"
  else
    f_failures=$((f_failures + 1))
  fi

  # 9. Audit log path: one file on the encrypted partition, never /var/log
  # (AP1). The gateway helper must exist and the audit writer must be present.
  f_audit_fail=0
  if grep -rq --exclude=symbios-settings-check.sh '/var/log/symbios-audit.log' \
      "${f_root}"/scripts "${f_root}"/base-services 2>/dev/null \
    || [[ ! -f "${f_root}/scripts/symbios_audit.py" ]] \
    || ! grep -q 'f_audit_event' "${f_root}/scripts/symbios-lib.sh" \
    || ! grep -q 'f_audit_event' "${f_root}/scripts/symbios-exec.sh"
  then
    echo "FAIL: audit trail is not the shared /symbios log" >&2
    f_audit_fail=1
  fi
  if grep -Eq 'password|passwd|passphrase' "${f_root}/scripts/symbios-exec.sh" 2>/dev/null \
    && grep -Eq 'stt\[-_\]key' "${f_root}/scripts/symbios-exec.sh" 2>/dev/null
  then
    :
  else
    echo "FAIL: audit mask misses secret keys from the inventory table" >&2
    f_audit_fail=1
  fi
  if [[ "${f_audit_fail}" -eq 0 ]]
  then
    g_echo "PASS: audit path and secret mask" 2>/dev/null || echo "PASS: audit path and secret mask"
  else
    f_failures=$((f_failures + 1))
  fi

  # 10. Boot rule (AP3): a service playbook that declares boot_units must
  # register the unit through the shared after-mount task.
  f_boot_fail=0
  for f_pb in "${f_root}"/base-services/*.yml "${f_root}"/services/*.yml
  do
    [[ -f "${f_pb}" ]] || continue
    grep -q '^#   boot_units:' "${f_pb}" || continue
    if ! grep -q 'after-mount-unit.yml' "${f_pb}"
    then
      echo "FAIL: $(basename "${f_pb}") declares boot_units without registration" >&2
      f_boot_fail=1
    fi
  done
  [[ -f "${f_root}/shared-tasks/after-mount-unit.yml" ]] || {
    echo "FAIL: shared-tasks/after-mount-unit.yml is missing" >&2
    f_boot_fail=1
  }
  if [[ "${f_boot_fail}" -eq 0 ]]
  then
    g_echo "PASS: boot unit declarations have registrations" 2>/dev/null || echo "PASS: boot unit declarations have registrations"
  else
    f_failures=$((f_failures + 1))
  fi

  # 11. Cron jobs that point into the encrypted data root must stay quiet on
  # an early tick before rc.local unlocked /symbios (AP3). A bare path in a
  # cron line without an executability/existence guard is a boot-time error.
  f_cron_bad="$(grep -RIn --include='*.yml' \
    -E '^[[:space:]]*([0-9*/,-]+[[:space:]]+){4,5}[0-9*/,-]+[[:space:]]+root[[:space:]].*(\{\{[[:space:]]*(git_root|data_root)[[:space:]]*\}\}|/symbios/)' \
    "${f_root}"/base-services "${f_root}"/services "${f_root}"/external-services 2>/dev/null \
    | grep -vE '(\[|\[\[)[[:space:]]*-?[xs][[:space:]]' || true)"
  if [[ -n "${f_cron_bad}" ]]
  then
    echo "FAIL: unguarded cron job below /symbios" >&2
    echo "${f_cron_bad}" >&2
    f_failures=$((f_failures + 1))
  else
    g_echo "PASS: cron jobs below /symbios are guarded" 2>/dev/null || echo "PASS: cron jobs below /symbios are guarded"
  fi

  # 12. Every blockinfile that writes /etc/rc.local must use a SymbiOS marker
  # and insert before the final exit 0, so re-runs cannot duplicate boot blocks.
  f_rc_bad=""
  for f_pb in "${f_root}"/base-services/*.yml "${f_root}"/services/*.yml
  do
    [[ -f "${f_pb}" ]] || continue
    f_rc_bad+="$(awk -v f_pb="$(basename "${f_pb}")" '
      /^[[:space:]]*- name:/ {
        if (f_bf && f_path && (!f_marker || !f_insert || f_marker_line !~ /SymbiOS/))
          print f_pb ": " f_task ": rc.local blockinfile needs SymbiOS marker and insertbefore"
        f_task=$0; f_bf=0; f_path=0; f_marker=0; f_insert=0; f_marker_line=""
      }
      /blockinfile:/ { f_bf=1 }
      /path:[[:space:]]*\/etc\/rc\.local/ { f_path=1 }
      /marker:/ { f_marker=1; f_marker_line=$0 }
      /insertbefore:/ { f_insert=1 }
      END {
        if (f_bf && f_path && (!f_marker || !f_insert || f_marker_line !~ /SymbiOS/))
          print f_pb ": " f_task ": rc.local blockinfile needs SymbiOS marker and insertbefore"
      }
    ' "${f_pb}")"
  done
  if [[ -n "${f_rc_bad}" ]]
  then
    echo "FAIL: unmarked rc.local blockinfile task" >&2
    echo "${f_rc_bad}" >&2
    f_failures=$((f_failures + 1))
  else
    g_echo "PASS: rc.local blocks have SymbiOS markers" 2>/dev/null || echo "PASS: rc.local blocks have SymbiOS markers"
  fi

  # 11. Central secret store: age CLI, identity outside the config dir,
  # audit events and the shared library read helper must be present.
  f_store="${f_root}/scripts/symbios-secret.sh"
  f_store_fail=0
  if [[ ! -x "${f_store}" ]] \
    || ! grep -q 'age -e -R' "${f_store}" \
    || ! grep -q 'age -d -i' "${f_store}" \
    || ! grep -q '${g_data_root}/.keys/symbios-secret.age.key' "${f_store}" \
    || ! grep -q '${g_data_root}/.keys/symbios-secret.age.pub' "${f_store}" \
    || ! grep -q 'f_audit_event secret' "${f_store}" \
    || ! grep -q 'f_secret_get_to_file' "${f_root}/scripts/symbios-lib.sh"
  then
    echo "FAIL: central secret store contract" >&2
    f_store_fail=1
  fi
  if [[ "${f_store_fail}" -eq 0 ]]
  then
    g_echo "PASS: central secret store contract" 2>/dev/null || echo "PASS: central secret store contract"
  else
    f_failures=$((f_failures + 1))
  fi

  # 12. Every baseline base-service must be reachable on fresh installs.
  # Intentional exceptions declare install_mode in their docs header.
  f_base_missing=()
  f_base_invalid=()
  f_install_list="$(grep -oE 'base-services/[a-zA-Z0-9._-]+\.yml' "${f_root}/install.sh" 2>/dev/null | sort -u)"
  while IFS= read -r f_pb
  do
    f_rel="${f_pb#"${f_root}/"}"
    if grep -qxF "${f_rel}" <<< "${f_install_list}"
    then
      continue
    fi
    f_mode="$(sed -n 's/^#   install_mode:[[:space:]]*\([^[:space:]]*\).*/\1/p' "${f_pb}" | head -n 1)"
    case "${f_mode}" in
      deferred|settings|optional|repair)
        ;;
      "")
        f_base_missing+=("${f_rel}")
        ;;
      *)
        f_base_invalid+=("${f_rel} (${f_mode})")
        ;;
    esac
  done < <(find "${f_root}/base-services" -maxdepth 1 -type f -name '*.yml' | sort)
  if [[ ${#f_base_missing[@]} -gt 0 || ${#f_base_invalid[@]} -gt 0 ]]
  then
    echo "FAIL: base-services install.sh coverage" >&2
    [[ ${#f_base_missing[@]} -gt 0 ]] && printf '  missing: %s\n' "${f_base_missing[@]}" >&2
    [[ ${#f_base_invalid[@]} -gt 0 ]] && printf '  invalid install_mode: %s\n' "${f_base_invalid[@]}" >&2
    f_failures=$((f_failures + 1))
  else
    g_echo "PASS: base-services install.sh coverage" 2>/dev/null || echo "PASS: base-services install.sh coverage"
  fi

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
      *-lib.sh|*-new.sh|*-check.sh|*-docs.sh) continue ;;
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
  f_check "${f_script} apply --dry-run" "${f_bin}" apply --dry-run
  # get vs list: read-capable verbs differ per backend (dict/file domains).
  if "${f_bin}" --help 2>&1 | grep -q "list \[--json\]"
  then
    f_check "${f_script} list" "${f_bin}" list
  else
    f_check "${f_script} get" "${f_bin}" get
  fi
  if f_schema="$("${f_bin}" schema 2>/dev/null)" \
    && printf '%s' "${f_schema}" | jq -e . >/dev/null 2>&1
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

# The secret store CLI shares the --help contract but is not a settings script.
if [[ -x "${g_symbios_dir}/symbios-secret.sh" ]]
then
  f_check "symbios-secret.sh --help" "${g_symbios_dir}/symbios-secret.sh" --help
fi

if [[ "${f_failures}" -gt 0 ]]
then
  echo "${f_failures} live check(s) failed" >&2
  exit 1
fi
echo "All live checks pass"
exit 0
