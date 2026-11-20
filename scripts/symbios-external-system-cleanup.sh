#!/bin/bash
# SymbiOS - Remove the local state of an external system target.
#
# Deletes the target entry from external-systems.yml, all remote-run markers
# ending in " @ <target>" from external-systems/installed-playbooks.yml and
# the target's saved vars/state files. The remote system itself is untouched.
# Used by the OpenWrt VM uninstall cleanup and by the External Systems delete
# view. Idempotent: missing pieces are skipped silently.
#
# Usage:
#   symbios-external-system-cleanup.sh <target_id>

function f_usage {
  cat << EOF
Usage: $(basename "$0") <target_id>

Remove all local SymbiOS state for an external system. This includes the
target entry, remote playbook install markers, saved vars and sync state.
The external system itself is not contacted or changed.

Arguments:
  <target_id>   id from ${g_config_dir}/external-systems.yml

Options:
  -h, --help    Show this help and exit

Examples:
  $(basename "$0") openwrt-vm

Exit codes: 0 = ok, 1 = technical error, 2 = usage error.
EOF
}

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

g_target="${1:-}"
if [[ -z "${g_target}" ]]
then
  f_usage >&2
  exit 2
fi
shift
if [[ $# -gt 0 ]]
then
  f_usage >&2
  exit 2
fi
if [[ ! "${g_target}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
then
  g_echo_error "Invalid target id: ${g_target}"
  exit 2
fi

function f_config_json {
  local f_rel="$1"
  "${g_script_dir}/symbios-config.py" --file "${f_rel}" get --json 2>/dev/null || printf '{}\n'
}

function f_write_config {
  local f_rel="$1"
  local f_doc="$2"
  if ! printf '%s\n' "${f_doc}" \
    | "${g_script_dir}/symbios-config.py" --file "${f_rel}" write > /dev/null
  then
    g_echo_error "Cannot update ${f_rel}"
    return 1
  fi
  return 0
}

function f_remove_system_entry {
  local f_path="${g_config_dir}/external-systems.yml"
  local f_doc
  [[ -f "${f_path}" ]] || return 0
  f_doc=$(f_config_json external-systems.yml)
  jq -e 'type == "object"' <<< "${f_doc}" > /dev/null 2>&1 || return 0
  f_doc=$(jq -c --arg f_id "${g_target}" \
    'if (.external_systems | type) == "array"
     then .external_systems |= map(select(.id != $f_id))
     else . end' <<< "${f_doc}")
  f_write_config external-systems.yml "${f_doc}"
}

function f_remove_install_markers {
  local f_path="${g_config_dir}/external-systems/installed-playbooks.yml"
  local f_doc
  local f_new
  [[ -f "${f_path}" ]] || return 0
  f_doc=$(f_config_json external-systems/installed-playbooks.yml)
  jq -e 'type == "object"' <<< "${f_doc}" > /dev/null 2>&1 || return 0
  f_new=$(jq -c --arg f_suffix " @ ${g_target}" \
    'with_entries(select((.key | endswith($f_suffix)) | not))' <<< "${f_doc}")
  [[ "${f_new}" == "${f_doc}" ]] && return 0
  f_write_config external-systems/installed-playbooks.yml "${f_new}" || return 1
  chmod 0644 "${f_path}" 2>/dev/null || true
}

function f_remove_target_files {
  local f_base
  for f_base in \
    "${g_config_dir}/external-systems/states/${g_target}.json" \
    "${g_config_dir}/external-systems/host_vars/${g_target}.yml"
  do
    rm -f "${f_base}" "${f_base}.bak" "${f_base}.lock" || return 1
  done
  rm -rf "${g_config_dir}/external-systems/playbook_vars/${g_target}" || return 1
}

# --- main --------------------------------------------------------------------
f_remove_system_entry || exit 1
f_remove_install_markers || exit 1
f_remove_target_files || exit 1
f_audit_event cli "external-system-cleanup" "target=${g_target}"
g_echo_note "Removed local state for external system ${g_target}"
