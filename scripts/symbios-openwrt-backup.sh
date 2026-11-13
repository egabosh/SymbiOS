#!/bin/bash
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# symbios-openwrt-backup.sh - Back up the configuration of the OpenWrt
# systems registered in external-systems.yml.
#
# WHY sysupgrade -b: it produces exactly the archive the router itself
# defines as its configuration (everything in /etc/sysupgrade.conf and
# /lib/upgrade/keep.d/*). A hand-maintained file list would drift from that
# definition; this one cannot. The archive is streamed to stdout, so nothing
# is written on the target.
#
# The archives land in ${g_backup_root}/openwrt/<id>/ and are therefore part
# of every restic snapshot taken by symbios-backup.sh. Called by
# backup.d/openwrt.backup (nightly 00:05): an unreachable router only logs an
# error and never stops the other systems or the snapshot.

if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [<id>...]

Back up the configuration of the OpenWrt systems registered in
${g_config_dir}/external-systems.yml (type: OpenWrt).

Every system delivers its own sysupgrade archive (the complete OpenWrt
configuration: /etc/config, SSH host keys and authorized keys, OpenVPN PKI,
WireGuard, Asterisk, cron, ...) plus a JSON with the release, board and
package metadata into
  ${g_backup_root}/openwrt/<id>/<id>-<YYYYmmddHHMM>.tar.gz
  ${g_backup_root}/openwrt/<id>/<id>-<YYYYmmddHHMM>.json

The archive is streamed over SSH, so nothing is written on the target. An
unreachable system is reported and skipped - the remaining systems and the
restic snapshot keep running. The newest ${g_retention} archives per system
are kept locally; the long-term history lives in the restic snapshots.

Commands:
  backup [<id>...]   Create a backup (default: every OpenWrt system)
  list [<id>...]     Show the existing archives per system

Options:
  -h, --help         Show this help and exit

Exit codes:
  0  all requested systems were backed up
  1  at least one system failed
  2  invalid usage, or an id that is unknown or not of type OpenWrt
EOF
}

# Directory below the backup root, and the number of archives kept per system.
g_backup_subdir="${g_backup_root}/openwrt"
g_retention=7

# Metadata of the current system (key -> value from the target).
declare -A g_meta=()

# Print the ids of all systems registered as type OpenWrt (one per line).
function f_openwrt_ids {
  local f_file="${g_config_dir}/external-systems.yml"
  [[ -r "${f_file}" ]] || return 0
  command -v yq > /dev/null || return 0
  yq -r '.external_systems[] | select(.type == "OpenWrt") | .id' "${f_file}" 2> /dev/null
}

# Build the ssh command array for the resolved g_ext_* target.
function f_ssh_cmd {
  g_ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10 \
              -o StrictHostKeyChecking=accept-new \
              -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}")
}

# JSON string literal for one value (f_json_escape adds the quotes).
function f_json_str {
  printf '%s' "${1:-}" | f_json_escape
}

# Print the existing archives of one system with age and size.
function f_list_system {
  local f_id="$1"
  local f_dir="${g_backup_subdir}/${f_id}"
  local f_file f_count=0
  for f_file in $(ls -1t "${f_dir}/${f_id}"-*.tar.gz 2> /dev/null)
  do
    f_count=$(( f_count + 1 ))
    printf '%s  %8s MB  %s\n' \
      "$(basename "${f_file}")" \
      "$(( $(stat -c %s "${f_file}") / 1048576 ))" \
      "$(date -r "${f_file}" '+%Y-%m-%d %H:%M')"
  done
  if [[ "${f_count}" -eq 0 ]]
  then
    printf '  no archive\n'
  fi
}

# Read release/board/package metadata from the target into g_meta.
# Best effort: a failed call must not discard the archive that already landed.
function f_read_metadata {
  local f_id="$1"
  local f_raw="${g_tmp}/meta.tsv"
  local f_key f_value

  g_meta=()
  if ! "${g_ssh[@]}" 'sh -s' > "${f_raw}" 2> "${g_tmp}/meta.err" << 'EOF'
. /etc/openwrt_release
printf 'distribution\t%s\n' "${DISTRIB_ID}"
printf 'release\t%s\n' "${DISTRIB_RELEASE}"
printf 'revision\t%s\n' "${DISTRIB_REVISION}"
printf 'target\t%s\n' "${DISTRIB_TARGET}"
printf 'arch\t%s\n' "${DISTRIB_ARCH}"
printf 'model\t%s\n' "$(cat /tmp/sysinfo/model 2>/dev/null)"
printf 'board_name\t%s\n' "$(cat /tmp/sysinfo/board_name 2>/dev/null)"
printf 'kernel\t%s\n' "$(uname -r)"
printf 'packages_installed\t%s\n' "$(apk list --installed 2>/dev/null | wc -l)"
printf 'packages_world\t%s\n' "$(tr '\n' ' ' < /etc/apk/world 2>/dev/null)"
EOF
  then
    g_echo_warn "${f_id}: metadata could not be read: $(head -3 "${g_tmp}/meta.err" | tr '\n' ' ')"
    return 0
  fi

  while IFS=$'\t' read -r f_key f_value
  do
    [[ -n "${f_key}" ]] || continue
    g_meta["${f_key}"]="${f_value}"
  done < "${f_raw}"
}

# Write the metadata JSON next to the archive.
function f_write_metadata {
  local f_id="$1"
  local f_archive="$2"
  local f_meta="${f_archive%.tar.gz}.json"
  local f_pkg f_packages=""

  # Package names are [A-Za-z0-9._+~-] only (apk world entries, optionally
  # with a version constraint). They are quoted directly instead of through
  # f_json_escape: that helper spawns a subshell per control character, and
  # one call per entry of a 350-package list dominates the run time. The
  # charset filter keeps the JSON valid even for an unexpected entry.
  for f_pkg in ${g_meta[packages_world]:-}
  do
    f_pkg="${f_pkg//[^A-Za-z0-9._+~-]/}"
    [[ -n "${f_pkg}" ]] || continue
    f_packages="${f_packages:+${f_packages}, }\"${f_pkg}\""
  done

  {
    printf '{\n'
    printf '  "id": %s,\n' "$(f_json_str "${f_id}")"
    printf '  "host": %s,\n' "$(f_json_str "${g_ext_host}")"
    printf '  "archive": %s,\n' "$(f_json_str "$(basename "${f_archive}")")"
    printf '  "created": %s,\n' "$(f_json_str "$(date -Iseconds)")"
    printf '  "size_bytes": %s,\n' "$(stat -c %s "${f_archive}")"
    printf '  "sha256": %s,\n' "$(f_json_str "$(sha256sum "${f_archive}" | cut -d' ' -f1)")"
    printf '  "files": %s,\n' "$(tar -tzf "${f_archive}" | wc -l)"
    printf '  "distribution": %s,\n' "$(f_json_str "${g_meta[distribution]:-}")"
    printf '  "release": %s,\n' "$(f_json_str "${g_meta[release]:-}")"
    printf '  "revision": %s,\n' "$(f_json_str "${g_meta[revision]:-}")"
    printf '  "target": %s,\n' "$(f_json_str "${g_meta[target]:-}")"
    printf '  "arch": %s,\n' "$(f_json_str "${g_meta[arch]:-}")"
    printf '  "model": %s,\n' "$(f_json_str "${g_meta[model]:-}")"
    printf '  "board_name": %s,\n' "$(f_json_str "${g_meta[board_name]:-}")"
    printf '  "kernel": %s,\n' "$(f_json_str "${g_meta[kernel]:-}")"
    printf '  "packages_installed": %s,\n' "${g_meta[packages_installed]:-0}"
    printf '  "packages_world": [%s]\n' "${f_packages}"
    printf '}\n'
  } > "${f_meta}.part"
  mv "${f_meta}.part" "${f_meta}"
}

# Drop all but the newest g_retention archives of one system.
function f_apply_retention {
  local f_id="$1"
  local f_dir="${g_backup_subdir}/${f_id}"
  local f_file
  local f_old

  f_old=$(ls -1t "${f_dir}/${f_id}"-*.tar.gz 2> /dev/null | tail -n +$(( g_retention + 1 )))
  while IFS= read -r f_file
  do
    [[ -n "${f_file}" ]] || continue
    g_echo_note "${f_id}: retention - removing $(basename "${f_file}")"
    rm -f "${f_file}" "${f_file%.tar.gz}.json"
  done <<< "${f_old}"
}

# Back up one system: stream the archive, validate it, then write metadata.
function f_backup_system {
  local f_id="$1"
  local f_dir="${g_backup_subdir}/${f_id}"
  local f_stamp f_part f_archive f_list
  local f_files f_size

  mkdir -p "${f_dir}"
  f_stamp=$(date +%Y%m%d%H%M)
  f_archive="${f_dir}/${f_id}-${f_stamp}.tar.gz"
  f_part="${f_archive}.part"
  f_list="${g_tmp}/archive.list"

  # Stream the archive. The .part name keeps a truncated transfer out of the
  # retention and out of the snapshot.
  if ! "${g_ssh[@]}" 'sysupgrade -b -' > "${f_part}" 2> "${g_tmp}/ssh.err" < /dev/null
  then
    g_echo_error "${f_id}: sysupgrade -b failed: $(head -3 "${g_tmp}/ssh.err" | tr '\n' ' ')"
    rm -f "${f_part}"
    return 1
  fi

  # Validate before the archive is accepted: an SSH connection that drops
  # mid-transfer leaves a readable but broken file, and a target with an empty
  # keep list produces a tar without any configuration.
  if ! tar -tzf "${f_part}" > "${f_list}" 2> "${g_tmp}/tar.err"
  then
    g_echo_error "${f_id}: archive is not a valid gzip tar: $(head -3 "${g_tmp}/tar.err" | tr '\n' ' ')"
    rm -f "${f_part}"
    return 1
  fi
  if ! grep -qx 'etc/config/system' "${f_list}"
  then
    g_echo_error "${f_id}: archive does not contain etc/config/system - is the keep list empty on the target?"
    rm -f "${f_part}"
    return 1
  fi

  mv "${f_part}" "${f_archive}"
  f_files=$(wc -l < "${f_list}")
  f_size=$(stat -c %s "${f_archive}")

  f_read_metadata "${f_id}"
  f_write_metadata "${f_id}" "${f_archive}"
  f_apply_retention "${f_id}"

  g_echo_ok "${f_id}: $(basename "${f_archive}") (${f_size} bytes, ${f_files} files)"
}

# --- argument parsing -------------------------------------------------------
g_command="${1:-}"
case "${g_command}" in
  backup|list)
    ;;
  -h|--help)
    f_usage
    exit 0
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac
shift

# Without ids every registered OpenWrt system is used; explicit ids are
# validated up front so a typo fails before the first SSH connection.
g_ids=()
g_line=""
if [[ $# -gt 0 ]]
then
  for g_line in "$@"
  do
    if ! f_external_target "${g_line}"
    then
      g_echo_error "Unknown external system: ${g_line} (see ${g_config_dir}/external-systems.yml)"
      exit 2
    fi
    if [[ "${g_ext_type}" != "OpenWrt" ]]
    then
      g_echo_error "${g_line} is registered as type '${g_ext_type}', not OpenWrt"
      exit 2
    fi
    g_ids+=("${g_line}")
  done
else
  while IFS= read -r g_line
  do
    [[ -n "${g_line}" ]] || continue
    g_ids+=("${g_line}")
  done <<< "$(f_openwrt_ids)"
fi

if [[ ${#g_ids[@]} -eq 0 ]]
then
  g_echo_warn "No OpenWrt system registered in ${g_config_dir}/external-systems.yml - nothing to do."
  exit 0
fi

# --- run --------------------------------------------------------------------
g_failed=0
for g_id in "${g_ids[@]}"
do
  if [[ "${g_command}" == "list" ]]
  then
    printf '%s:\n' "${g_id}"
    f_list_system "${g_id}"
    continue
  fi

  if ! f_external_target "${g_id}"
  then
    g_echo_error "Unknown external system: ${g_id}"
    g_failed=$(( g_failed + 1 ))
    continue
  fi
  f_ssh_cmd
  g_echo_note "Backing up ${g_id} (${g_ext_host})"
  if ! f_backup_system "${g_id}"
  then
    g_failed=$(( g_failed + 1 ))
  fi
done

if [[ "${g_command}" == "backup" ]]
then
  if [[ "${g_failed}" -gt 0 ]]
  then
    g_echo_error "$(( ${#g_ids[@]} - g_failed )) of ${#g_ids[@]} OpenWrt systems backed up, ${g_failed} failed"
    exit 1
  fi
  g_echo_ok "All ${#g_ids[@]} OpenWrt systems backed up"
fi
exit 0
