#!/bin/bash
# SymbiOS - Resolve which host playbooks consume inventory variables.
#
# Reads the uses_vars lists from every playbook docs block under
# base-services/ and services/ (external-services/ runs elsewhere and is
# ignored) and prints the playbooks listing any of the given vars, one per
# line, in run order (install.sh order for base-services, alphabetical for
# services/). Uninstalled services/* are skipped (never auto-install apps);
# base-services/* always run (platform converges). Skipped entries go to
# stderr as info, never fail the call.
#
# This is pure lookup: execution lives in symbios-settings-lib.sh
# (f_ss_apply). The docs blocks are the single source - validated by
# symbios-settings-check.sh --static.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--all] <var> [<var> ...]

Print host playbooks consuming any of the given inventory variables.

Scope: base-services/*.yml and services/*.yml below the repo root
(external-services/ runs on other systems and is ignored). Order:
install.sh order for base-services, alphabetical for services/.

By default uninstalled services/* are skipped (reported on stderr);
base-services/* always run (platform converges, incl. first install).
--all lists skipped services too (marked).

Examples:
  $(basename "$0") timezone
  $(basename "$0") twofa_enabled
  $(basename "$0") --all base_domain

Exit codes:
  0  ok (also when nothing matches - empty output)
  2  usage error (no vars given, ...)
  1  technical error (repo/playbooks unreadable, ...)
EOF
}

f_all="no"
f_vars=()

while [[ $# -gt 0 ]]
do
  case "$1" in
    --all)
      f_all="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      f_usage >&2
      exit 2
      ;;
    *)
      f_vars+=("$1")
      shift
      ;;
  esac
done

if [[ "${#f_vars[@]}" -eq 0 ]]
then
  echo "Nothing to resolve - pass at least one variable name" >&2
  f_usage >&2
  exit 2
fi

# NOTE: source WITHOUT 2>/dev/null - gaboshlib saves stderr to fd 9 at
# source time, and a redirect here would poison fd 9 with /dev/null.
# The -r test keeps it silent where the file is absent.
# shellcheck disable=SC1091
[[ -r /etc/bash/gaboshlib.include ]] && source /etc/bash/gaboshlib.include || true
# gaboshlib diverts stderr into a red colorizer on stdout (DEBUG trap).
# That is fine for terminals, but this script's stdout is machine-read
# (f_ss_apply feeds it to symbios-run-playbook.sh), so kill the trap
# first and then restore real stderr (fd 9 is gaboshlib's saved copy;
# probe it silently - a direct guard redirect would void the restore).
trap - DEBUG
if (exec 2>&9) 2>/dev/null
then
  exec 2>&9
fi
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
# Repo root: scripts/ lives at <root>/scripts.
g_repo_root="$(cd "${g_symbios_dir}/.." && pwd)"

# --- collect candidate playbooks ----------------------------------------------

# base-services in install.sh order (canonical platform order).
f_ordered=()
while read -r f_pb
do
  [[ -n "${f_pb}" ]] || continue
  f_ordered+=("${f_pb}")
done < <(grep -o 'base-services/[a-z0-9-]*\.yml' "${g_repo_root}/install.sh" 2>/dev/null | awk '!seen[$0]++' || true)
# ...plus any base-services playbook not mentioned there, alphabetical.
while read -r f_path
do
  f_rel="${f_path#${g_repo_root}/}"
  f_hit="no"
  for f_have in ${f_ordered[@]+"${f_ordered[@]}"}
  do
    [[ "${f_have}" == "${f_rel}" ]] && f_hit="yes"
  done
  [[ "${f_hit}" == "yes" ]] || f_ordered+=("${f_rel}")
done < <(cd "${g_repo_root}" && ls base-services/*.yml 2>/dev/null | sort || true)
# services/* alphabetical (no canonical order exists).
while read -r f_path
do
  f_ordered+=("${f_path#${g_repo_root}/}")
done < <(cd "${g_repo_root}" && ls services/*.yml 2>/dev/null | sort || true)

if [[ "${#f_ordered[@]}" -eq 0 ]]
then
  echo "No playbooks found below ${g_repo_root}" >&2
  exit 1
fi

# --- match uses_vars ------------------------------------------------------------

# Extract a uses_vars block list from a playbook docs comment (block style
# only: one "- name" per line - the documented convention; anything else
# is ignored, not guessed).
function f_uses_vars {
  local f_file="$1"
  awk '
    /^# *uses_vars: *$/ { in_block = 1; next }
    in_block && /^# *- / {
      line = $0
      sub(/^# *- */, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line != "") print line
      next
    }
    { in_block = 0 }
  ' "${f_file}" 2>/dev/null
}
# Ask the state file whether a service playbook is installed (missing
# state counts as not installed - never auto-install apps).
function f_is_installed {
  local f_pb="$1"
  "${g_symbios_dir}/symbios-state.sh" is-installed "${f_pb}" >/dev/null 2>&1
}

for f_rel in ${f_ordered[@]+"${f_ordered[@]}"}
do
  f_hit="no"
  while read -r f_declared
  do
    [[ -z "${f_declared}" ]] && continue
    for f_want in ${f_vars[@]+"${f_vars[@]}"}
    do
      if [[ "${f_declared}" == "${f_want}" ]]
      then
        f_hit="yes"
        break 2
      fi
    done
  done < <(f_uses_vars "${g_repo_root}/${f_rel}")
  [[ "${f_hit}" == "yes" ]] || continue
  if [[ "${f_rel}" == services/* ]]
  then
    if f_is_installed "${f_rel}"
    then
      echo "${f_rel}"
    elif [[ "${f_all}" == "yes" ]]
    then
      echo "${f_rel} (not installed)"
    else
      echo "skip: ${f_rel} (not installed)" >&2
    fi
  else
    echo "${f_rel}"
  fi
done
exit 0
