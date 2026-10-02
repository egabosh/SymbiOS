#!/bin/bash
# SymbiOS - Index new files on Nextcloud external media mounts.
#
# Browsing a folder indexes it live, but search, gallery timelines and
# shares need filecache rows. Full-library scans on TB archives bloat the
# database and take forever, so only explicitly listed mounts are scanned
# (per user, new files only). Configure via inventory:
# nextcloud_media_scan_mounts (list of mount display names).
#
# Usage: symbios-nextcloud-media-scan.sh [mount...]
#   No args: scan the inventory list. Explicit mounts always scan
#   (used by the youtube-dl hook for its target dir).

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_scan_mounts {
  local f_mounts="$1"
  local f_users f_uid f_mount

  [[ -d "${g_services_root}/nextcloud" ]] || return 0

  if [[ -z "${f_mounts}" ]]
  then
    # Inventory stores a YAML list - flatten one-per-line entries
    f_mounts="$(awk '/^[[:space:]]*nextcloud_media_scan_mounts:/{found=1; next} found && /^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next} found{exit}' "${g_inventory}" 2>/dev/null)"
  fi
  [[ -n "${f_mounts}" ]] || return 0

  f_users="$(docker compose -f "${g_services_root}/nextcloud/docker-compose.yml" exec -T -u www-data nextcloud ./occ user:list 2>/dev/null | sed -n 's/^  - \([^:]*\):.*/\1/p')"
  [[ -n "${f_users}" ]] || return 0

  while read -r f_mount
  do
    [[ -n "${f_mount}" ]] || continue
    while read -r f_uid
    do
      [[ -n "${f_uid}" ]] || continue
      docker compose -f "${g_services_root}/nextcloud/docker-compose.yml" exec -T -u www-data nextcloud \
        ./occ files:scan --path="/${f_uid}/files/${f_mount}" --unscanned --no-interaction -q >/dev/null 2>&1 || true
    done <<<"${f_users}"
  done <<<"${f_mounts}"
  g_echo_note "External media scan done"
}

if [[ $# -gt 0 ]]
then
  f_scan_mounts "$(printf '%s\n' "$@")"
else
  f_scan_mounts ""
fi
