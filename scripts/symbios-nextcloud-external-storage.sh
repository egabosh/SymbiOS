#!/bin/bash
# SymbiOS - Register the media libraries as Nextcloud external storage.
#
# Enables files_external (+ previewgenerator unless disabled) and creates
# the Media Audio/Videos/Images/Documents mounts via occ (idempotent by
# mount name). Prints "created <name>" per new mount (Ansible
# changed_when). Called from services/nextcloud.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--no-previews]

Register the media libraries as Nextcloud external storage via occ.
Waits up to 5 minutes for a live occ, then enables files_external
(and previewgenerator unless --no-previews is given) and creates any
missing library mounts. Must run in /symbios/services/nextcloud.

Options:
  --no-previews       Disable previewgenerator instead of enabling it
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

function f_nextcloud_external_storage {
  local f_previews="${1:-true}" f_spec f_name f_path f_i
  cd "${g_services_root}/nextcloud"
  # config.php exists on the host even mid-restart, so wait for a live occ.
  for f_i in $(seq 1 30)
  do
    if docker compose exec -T -u www-data nextcloud ./occ status 2>/dev/null | grep -q "installed: true"
    then
      break
    fi
    sleep 10
  done
  docker compose exec -T -u www-data nextcloud ./occ app:enable files_external >/dev/null 2>&1 || true
  # Pregenerate thumbnails for the photo/video libraries in the
  # background cronjob (the nextcloud-cron service runs it).
  if [[ "${f_previews}" == "true" ]]
  then
    docker compose exec -T -u www-data nextcloud ./occ app:enable previewgenerator >/dev/null 2>&1 || true
  else
    docker compose exec -T -u www-data nextcloud ./occ app:disable previewgenerator >/dev/null 2>&1 || true
  fi
  for f_spec in "Media Audio|/media/audio" "Media Videos|/media/videos" "Media Images|/media/images" "Media Documents|/media/documents"
  do
    f_name="${f_spec%%|*}"
    f_path="${f_spec##*|}"
    # Name-based idempotency: if the mount point exists it is kept
    # as-is (delete it once via occ when the datadir ever changes).
    if ! docker compose exec -T -u www-data nextcloud ./occ files_external:list 2>/dev/null | grep -q -e "${f_name}" -e "${f_path}"
    then
      docker compose exec -T -u www-data nextcloud ./occ files_external:create "${f_name}" local null::null -c datadir="${f_path}"
      echo "created ${f_name}"
    fi
  done
}

if [[ "${1:-}" == "--no-previews" ]]
then
  f_nextcloud_external_storage "false"
else
  f_nextcloud_external_storage "true"
fi
