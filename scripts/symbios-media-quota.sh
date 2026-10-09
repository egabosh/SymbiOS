#!/bin/bash
# SymbiOS - Apply project quotas on the shared media tree.
#
# Project IDs are stable without an allocation table: fixed 31010-31015
# for the libraries, the owner uidNumber for homes, the owner gidNumber
# for shares. Limits come from media_quota_* (GiB, 0 = unlimited).
# Called from base-services/media.yml. Skips silently without prjquota.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Apply project quotas on the media libraries, home dirs and shares.
Reads media_root, media_* paths and media_quota_* limits from
inventory.yml via symbios-lib.sh. Skips silently when the media
filesystem has no prjquota support. No arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_quota_one {
  local f_projid="${1}" f_path="${2}" f_limit="${3}" f_root="${4}"
  if [[ "${f_limit}" -gt 0 ]]
  then
    chattr -p "${f_projid}" "${f_path}"
    chattr +P "${f_path}"
    setquota -P "${f_projid}" $(( f_limit * 1048576 )) $(( f_limit * 1048576 )) 0 0 "${f_root}"
  fi
}

function f_media_quota {
  local f_root f_dir f_id f_limit
  f_root="$(f_symbios_var media_root "/symbios/media")"

  # Skip silently without project quota support
  if ! findmnt -n -o OPTIONS --target "${f_root}" | tr ',' '\n' | grep -qx prjquota
  then
    return 0
  fi

  # Fixed library dirs (projid 31010-31015)
  f_quota_one 31010 "$(f_symbios_var media_inbox "/symbios/media/inbox")" "$(f_symbios_var media_quota_inbox 0)" "${f_root}"
  f_quota_one 31011 "$(f_symbios_var media_videos "/symbios/media/videos")" "$(f_symbios_var media_quota_videos 0)" "${f_root}"
  f_quota_one 31012 "$(f_symbios_var media_audio "/symbios/media/audio")" "$(f_symbios_var media_quota_audio 0)" "${f_root}"
  f_quota_one 31013 "$(f_symbios_var media_images "/symbios/media/images")" "$(f_symbios_var media_quota_images 0)" "${f_root}"
  f_quota_one 31014 "$(f_symbios_var media_books "/symbios/media/books")" "$(f_symbios_var media_quota_books 0)" "${f_root}"
  f_quota_one 31015 "$(f_symbios_var media_documents "/symbios/media/documents")" "$(f_symbios_var media_quota_documents 0)" "${f_root}"

  # Homes (projid = owner uid) and shares (projid = owner gid)
  for f_dir in "${f_root}/home/"*/ "${f_root}/shared/"*/
  do
    [[ -d "${f_dir}" ]] || continue
    if [[ "${f_dir}" == */home/* ]]
    then
      f_id="$(stat -c '%u' "${f_dir}")"
      f_limit="$(f_symbios_var media_quota_home 0)"
    else
      f_id="$(stat -c '%g' "${f_dir}")"
      f_limit="$(f_symbios_var media_quota_share 0)"
    fi
    if [[ "${f_limit}" -gt 0 ]]
    then
      chattr -p "${f_id}" "${f_dir}"
      chattr +P "${f_dir}"
      setquota -P "${f_id}" $(( f_limit * 1048576 )) $(( f_limit * 1048576 )) 0 0 "${f_root}"
    fi
  done
}

f_media_quota
