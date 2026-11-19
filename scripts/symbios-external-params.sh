#!/bin/bash
# SymbiOS - Saved variables for external-system playbook runs.
#
# Stores Ansible extra vars per external target (host_vars, valid for every
# playbook on that target) and per target/playbook (playbook_vars). Both are
# consumed by symbios-run-remote-playbook.sh, so repeated runs do not need the
# same values typed again. Values travel as JSON on stdin, never as argv.
#
# Usage:
#   symbios-external-params.sh get  <target> [playbook] [--json]
#   symbios-external-params.sh set  <target> [playbook] --json-stdin

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") get <target> [playbook] [--json]
       $(basename "$0") set <target> [playbook] --json-stdin

Read or save Ansible extra vars for an external system. "get" prints the
merged document (host_vars overlaid by playbook_vars) as JSON. "set" merges
the JSON object read from stdin into the selected scope: with a playbook
argument into playbook_vars, otherwise into host_vars.

Arguments:
  <target>        id of an entry in \${g_config_dir}/external-systems.yml
  [playbook]      file name below external-services/ (e.g. openwrt_basics.yml)

Options:
  --json          get: print JSON (default: human-readable JSON as well)
  --json-stdin    set: read the JSON object from stdin (required)
  -h, --help      show this help and exit

Storage (relative to the config dir):
  external-systems/host_vars/<target>.yml
  external-systems/playbook_vars/<target>/<playbook>.yml

Examples:
  $(basename "$0") get openwrt-vm
  echo '{"ip":"172.18.0.1"}' | \\
    $(basename "$0") set openwrt-vm openwrt_basics.yml --json-stdin

Exit codes: 0 ok, 2 usage or validation error, 1 technical error.
EOF
}

function f_fail {
  g_echo_error "$1"
  exit "${2:-1}"
}

# --- arguments --------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

g_action="${1:-}"
[[ "$g_action" == "get" || "$g_action" == "set" ]] || {
  f_usage >&2
  exit 2
}
shift

g_target="${1:-}"
if [[ -z "${g_target}" ]]
then
  f_usage >&2
  exit 2
fi
shift

g_playbook=""
if [[ $# -gt 0 && "$1" != --* ]]
then
  g_playbook="$1"
  shift
fi

g_json_stdout=0
g_json_stdin=0
while [[ $# -gt 0 ]]
do
  case "$1" in
    --json)
      g_json_stdout=1
      ;;
    --json-stdin)
      g_json_stdin=1
      ;;
    *)
      f_usage >&2
      exit 2
      ;;
  esac
  shift
done

# --- validate ---------------------------------------------------------------
if [[ ! "${g_target}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
then
  f_fail "Invalid target id: ${g_target}" 2
fi
if ! f_external_target "${g_target}"
then
  f_fail "Unknown external system: ${g_target}" 2
fi

g_rel_host="external-systems/host_vars/${g_target}.yml"
if [[ -n "${g_playbook}" ]]
then
  if [[ ! "${g_playbook}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.yml$ ]]
  then
    f_fail "Invalid playbook name: ${g_playbook}" 2
  fi
  if [[ ! -f "${g_git_root}/external-services/${g_playbook}" ]]
  then
    f_fail "Playbook not found: external-services/${g_playbook}" 2
  fi
  g_rel_pb="external-systems/playbook_vars/${g_target}/${g_playbook}"
fi

function f_read_doc {
  local f_rel="$1"
  local f_json
  f_json=$(symbios-config.py --file "${f_rel}" get --json 2>/dev/null || true)
  if [[ -z "${f_json}" ]]
  then
    printf '{}\n'
    return 0
  fi
  if ! jq -e 'type == "object"' <<< "${f_json}" > /dev/null 2>&1
  then
    f_fail "Not a JSON object: ${f_rel}"
  fi
  jq -c '.' <<< "${f_json}"
}

# --- read -------------------------------------------------------------------
if [[ "${g_action}" == "get" ]]
then
  [[ "${g_json_stdin}" == "0" ]] || {
    f_usage >&2
    exit 2
  }
  g_host_json=$(f_read_doc "${g_rel_host}")
  g_pb_json='{}'
  [[ -z "${g_playbook}" ]] || g_pb_json=$(f_read_doc "${g_rel_pb}")
  printf '%s\n%s\n' "${g_host_json}" "${g_pb_json}" | jq -c -s '.[0] * .[1]'
  exit 0
fi

# --- write ------------------------------------------------------------------
[[ "${g_json_stdin}" == "1" ]] || {
  f_usage >&2
  exit 2
}
[[ "${g_json_stdout}" == "0" ]] || {
  f_usage >&2
  exit 2
}

g_work_file=$(mktemp) || f_fail "Cannot create a temporary file"
trap 'rm -f "${g_work_file}"' EXIT
cat > "${g_work_file}"
if ! jq -e 'type == "object"' "${g_work_file}" > /dev/null 2>&1
then
  f_fail "Invalid JSON on stdin (expected an object)" 2
fi

if [[ -n "${g_playbook}" ]]
then
  symbios-config.py --file "${g_rel_pb}" merge < "${g_work_file}" || f_fail "Cannot save playbook vars"
  g_echo_note "Saved playbook vars for ${g_target} / ${g_playbook}"
else
  symbios-config.py --file "${g_rel_host}" merge < "${g_work_file}" || f_fail "Cannot save host vars"
  g_echo_note "Saved host vars for ${g_target}"
fi
