#!/bin/bash
# SymbiOS - Run a playbook from external-services/ on an external system.
#
# Generic runner for all remote targets: the target is resolved from
# <config>/external-systems.yml, a throwaway inventory is generated and
# ansible-playbook is called locally over SSH. The playbooks stay standalone
# capable - they know nothing about this wrapper.
#
# Parameter values (WebUI input fields) are read as a JSON object from stdin,
# never from the command line: they may contain secrets (API keys, passwords)
# which must not show up in `ps` or in the exec audit log.
#
# Usage:
#   symbios-run-remote-playbook.sh <target_id> <playbook> [--vars-stdin]

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <target_id> <playbook> [--vars-stdin]

Run one playbook from external-services/ on an external system.

Arguments:
  <target_id>      id of an entry in ${g_config_dir}/external-systems.yml
  <playbook>       playbook file name below external-services/
                   (e.g. openwrt_dns_cname.yml)
  --vars-stdin     read the extra vars as a JSON object from stdin. Use this
                   for values that must not appear in the process list or in
                   the audit log (API keys, passwords).

Options:
  -h, --help       Show this help and exit

Examples:
  $(basename "$0") openwrt openwrt_basics.yml
  echo '{"cname":"nas.lan","target":"server.lan"}' | \\
    $(basename "$0") openwrt openwrt_dns_cname.yml --vars-stdin

Output: the plain ansible-playbook output. Exit code 0 on success, 1 on a
technical error, 2 on a usage error, otherwise the ansible exit code.
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

g_target="${1:-}"
g_playbook="${2:-}"
if [[ -z "${g_target}" || -z "${g_playbook}" ]]
then
  f_usage >&2
  exit 2
fi
shift 2
g_vars_stdin=0
while [[ $# -gt 0 ]]
do
  case "$1" in
    --vars-stdin)
      g_vars_stdin=1
      ;;
    *)
      f_usage >&2
      exit 2
      ;;
  esac
  shift
done

# --- resolve target ---------------------------------------------------------
if ! f_external_target "${g_target}"
then
  f_fail "Unknown external system: ${g_target} (see ${g_config_dir}/external-systems.yml)"
fi

# --- resolve playbook -------------------------------------------------------
# Only plain file names below external-services/ (no paths, no traversal).
if [[ ! "${g_playbook}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.yml$ ]]
then
  f_fail "Invalid playbook name: ${g_playbook}" 2
fi
g_playbook_path="${g_git_root}/external-services/${g_playbook}"
if [[ ! -f "${g_playbook_path}" ]]
then
  f_fail "Playbook not found: external-services/${g_playbook}"
fi

# --- temporary files --------------------------------------------------------
g_work_dir=$(mktemp -d) || f_fail "Cannot create a temporary directory"
trap 'rm -rf "${g_work_dir}"' EXIT
umask 077

# Inventory for the single target (no facts: minimal images, no Python).
cat > "${g_work_dir}/inventory.ini" << EOF
[external]
${g_target} ansible_host=${g_ext_host} ansible_port=${g_ext_port} ansible_user=${g_ext_user} ansible_connection=ssh ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new' gather_facts=no
EOF

# Extra vars: empty object unless the caller pipes a JSON object in.
g_vars_file="${g_work_dir}/vars.json"
printf '{}\n' > "${g_vars_file}"
if (( g_vars_stdin ))
then
  cat > "${g_vars_file}"
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${g_vars_file}" 2> /dev/null
  then
    f_fail "Invalid JSON on stdin (expected an object)" 2
  fi
fi

# --- run --------------------------------------------------------------------
g_echo_note "Running ${g_playbook} on ${g_target} (${g_ext_user}@${g_ext_host}:${g_ext_port})"
cd "${g_git_root}" || f_fail "Cannot change to ${g_git_root}"
ansible-playbook -i "${g_work_dir}/inventory.ini" -e "@${g_vars_file}" "${g_playbook_path}"
