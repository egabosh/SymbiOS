#!/bin/bash
# SymbiOS - Seed and sync the Jellyfin libraries in the Kodi addon.
#
# The Jellyfin for Kodi addon expects its libraries to be selected in a GUI
# dialog. This helper reads the available views from the Jellyfin API, stores
# them in the addon's sync.json and jellyfin.db, and asks the running Kodi
# service to synchronise them through a file-based request queue. No GUI
# interaction and no password on the command line is needed.

function f_secret_file {
  local f_prefix="$1"
  local f_target="$2"
  local f_file
  f_file="$(mktemp "/run/symbios-kodi-jf-${f_prefix}.XXXXXX")" || exit 1
  chmod 0600 "$f_file" || exit 1
  g_secret_files+=("$f_file")
  printf -v "$f_target" '%s' "$f_file"
}

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--data-dir <path>] [--database <path>]
                           [--media-root <path>] [--force]

Seed the Jellyfin for Kodi addon library state and start a library sync.

Options:
  --data-dir <path>       Addon data directory (default: the kodi profile)
  --database <path>       Addon jellyfin.db (default: the kodi profile)
  --media-root <path>     Local sshfs root that mirrors the Jellyfin libraries
  --force                 Sync again even when a whitelist already exists
  -h, --help              Show this help and exit

Output: the last stdout line is kodi-jellyfin-library-triggered or
kodi-jellyfin-library-unchanged. The Jellyfin token is never printed.

Exit codes:
  0  ok (also when already configured)
  1  technical error (no token, API or database failure)
  2  usage error
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

g_data_dir=/home/kodi/.kodi/userdata/addon_data/plugin.video.jellyfin
g_database=/home/kodi/.kodi/userdata/Database/jellyfin.db
g_media_root=/symbios/services/kodi/media
g_force=false

while [[ $# -gt 0 ]]
do
  case "$1" in
    --data-dir)
      [[ $# -ge 2 ]] || { f_usage >&2; exit 2; }
      g_data_dir="$2"
      shift 2
      ;;
    --database)
      [[ $# -ge 2 ]] || { f_usage >&2; exit 2; }
      g_database="$2"
      shift 2
      ;;
    --media-root)
      [[ $# -ge 2 ]] || { f_usage >&2; exit 2; }
      g_media_root="$2"
      shift 2
      ;;
    --force)
      g_force=true
      shift
      ;;
    *)
      f_usage >&2
      exit 2
      ;;
  esac
done

for f_tool in jq curl sqlite3
do
  command -v "$f_tool" >/dev/null 2>&1 || { g_echo_error "Missing tool: $f_tool"; exit 1; }
done

[[ -s "$g_data_dir/data.json" ]] || { g_echo_error "Jellyfin addon is not authenticated yet"; exit 1; }

g_lockfile
# gaboshlib's lock helper replaces the EXIT trap, so register the lib's shared
# secret cleanup only after it has run. The lib owns g_secret_files.
f_secret_cleanup_register

# The native path replacements are refreshed on every managed run. A "stream://"
# target marks Jellyfin downloads as stream-only: no local sshfs mount exists,
# so the addon must write a plugin:// playback URL into Kodi's database.
f_secret_file data g_data_json
jq --arg f_movies "${g_media_root}/movies" \
  --arg f_tvshows "${g_media_root}/tvshows" \
  --arg f_audio "${g_media_root}/audio" \
  '.Servers[0].paths = {"/media/movies": $f_movies, "/media/tvshows": $f_tvshows, "/media/audio": $f_audio, "/media/downloads": "stream://jellyfin"}' \
  "$g_data_dir/data.json" > "$g_data_json" || exit 1
install -o kodi -g kodi -m 0600 "$g_data_json" "$g_data_dir/data.json" || exit 1

# The state file is written once by the first sync. Later reapplies must not
# start another full sync of a large music library.
if [[ "$g_force" == false && -s "$g_data_dir/sync.json" ]]
then
  if [[ "$(jq -r '.Whitelist | length // 0' "$g_data_dir/sync.json" 2>/dev/null || printf '0')" != "0" ]]
  then
    # A previous full sync can leave Libraries/RestorePoint behind when Kodi is
    # restarted mid-sync. The addon then asks to resume that sync on startup and
    # waits for a GUI answer, so clear the resume state on every managed run.
    f_secret_file resume g_sync_resume
    jq '.Libraries = [] | .RestorePoint = {}' "$g_data_dir/sync.json" > "$g_sync_resume" || exit 1
    if ! cmp -s "$g_sync_resume" "$g_data_dir/sync.json"
    then
      install -o kodi -g kodi -m 0644 "$g_sync_resume" "$g_data_dir/sync.json" || exit 1
    fi
    g_echo_note "kodi-jellyfin-library-unchanged"
    exit 0
  fi
fi

g_server="$(jq -er '.Servers[0].address // empty' "$g_data_dir/data.json")" || exit 1
g_uid="$(jq -er '.Servers[0].UserId // empty' "$g_data_dir/data.json")" || exit 1
g_token="$(jq -er '.Servers[0].AccessToken // empty' "$g_data_dir/data.json")" || exit 1
[[ -n "$g_server" && -n "$g_uid" && -n "$g_token" ]] || { g_echo_error "Incomplete Jellyfin addon state"; exit 1; }
g_server="${g_server%/}"

f_secret_file auth g_auth_hdr
printf 'Authorization: MediaBrowser Client="SymbiOS", Device="Kodi Library Setup", DeviceId="symbios-kodi-library", Version="1.0", Token="%s"\n' \
  "$g_token" > "$g_auth_hdr"

f_secret_file cfg g_curl_cfg
f_secret_file views g_views
f_secret_file item g_item
f_secret_file supported g_supported
f_secret_file selected g_selected
f_secret_file meta g_selected_meta
f_secret_file sorted g_sorted
f_secret_file sync g_sync

# Query a Jellyfin endpoint with the token in a 0600 header file. The token
# must never enter argv or a curl config value.
function f_jf_get {
  local f_path="$1"
  local f_out="$2"
  local f_code
  printf 'request = "GET"\n' > "$g_curl_cfg"
  printf 'url = "%s%s"\n' "$g_server" "$f_path" >> "$g_curl_cfg"
  printf 'header = "Accept: application/json"\n' >> "$g_curl_cfg"
  printf 'output = "%s"\n' "$f_out" >> "$g_curl_cfg"
  f_code="$(curl -sS --config "$g_curl_cfg" -H @"$g_auth_hdr" -w '%{http_code}' || true)"
  [[ "$f_code" == "200" ]] || return 1
}

f_jf_get "/Users/${g_uid}/Views" "$g_views" || { g_echo_error "Could not read Jellyfin views"; exit 1; }

jq -r '.Items[]? | select(.CollectionType == "movies" or .CollectionType == "tvshows" or .CollectionType == "music" or .CollectionType == "musicvideos" or .CollectionType == "mixed") | [.Id, .Name, .CollectionType] | @tsv' \
  "$g_views" > "$g_supported"
jq -r '.Items[]?.Id' "$g_views" > "$g_sorted"

# Only libraries with at least one item get a synced node. Empty collection
# folders in the Jellyfin demo data would otherwise show up as empty entries.
: > "$g_selected"
: > "$g_selected_meta"
while IFS=$'\t' read -r f_id f_name f_media
do
  [[ -n "$f_id" ]] || continue
  f_jf_get "/Users/${g_uid}/Items?ParentId=${f_id}&Recursive=true&Limit=1" "$g_item" \
    || continue
  if [[ "$(jq -r '.Items | length // 0' "$g_item")" != "0" ]]
  then
    printf '%s\n' "$f_id" >> "$g_selected"
    printf '%s\t%s\t%s\n' "$f_id" "$f_name" "$f_media" >> "$g_selected_meta"
  fi
done < "$g_supported"

[[ -s "$g_selected" ]] || { g_echo_error "No Jellyfin libraries with media found"; exit 1; }

# The addon reads sync.json at startup and builds its video/music nodes from
# Whitelist plus the view table in jellyfin.db. Seeding both avoids the GUI
# library-selection dialog. Libraries stays empty: a non-empty value would
# trigger the addon's "resume previous sync?" prompt on startup.
jq -n --rawfile f_sorted "$g_sorted" --rawfile f_selected "$g_selected" \
  '{Libraries: [], RestorePoint: {}, SortedViews: ($f_sorted | split("\n") | map(select(length > 0))), Whitelist: ($f_selected | split("\n") | map(select(length > 0)))}' \
  > "$g_sync"

install -d -o kodi -g kodi -m 0750 "$g_data_dir"
install -o kodi -g kodi -m 0644 "$g_sync" "$g_data_dir/sync.json"

install -d -o kodi -g kodi -m 0755 "$(dirname "$g_database")"
sqlite3 "$g_database" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS jellyfin(
  jellyfin_id TEXT UNIQUE, media_folder TEXT, jellyfin_type TEXT, media_type TEXT,
  kodi_id INTEGER, kodi_fileid INTEGER, kodi_pathid INTEGER, parent_id INTEGER,
  checksum INTEGER, jellyfin_parent_id TEXT);
CREATE TABLE IF NOT EXISTS view(
  view_id TEXT UNIQUE, view_name TEXT, media_type TEXT);
CREATE TABLE IF NOT EXISTS version(idVersion TEXT);
SQL

while IFS=$'\t' read -r f_id f_name f_media
do
  [[ -n "$f_id" ]] || continue
  f_sql_name="${f_name//\'/\'\'}"
  sqlite3 "$g_database" \
    "INSERT OR REPLACE INTO view(view_id, view_name, media_type) VALUES ('${f_id}', '${f_sql_name}', '${f_media}');" \
    >/dev/null || { g_echo_error "Could not seed Jellyfin view $f_name"; exit 1; }
done < "$g_selected_meta"
chown kodi:kodi "$g_database" 2>/dev/null || true
chown kodi:kodi "${g_database}-wal" "${g_database}-shm" 2>/dev/null || true

# The patched Kodi service consumes this queue in its main loop and calls the
# addon's add_library() directly, which skips every selection dialog.
g_trigger="$g_data_dir/sync-requests"
install -o kodi -g kodi -m 0600 "$g_selected" "$g_trigger"

for f_i in $(seq 1 30)
do
  [[ -e "$g_trigger" ]] || break
  sleep 1
done
if [[ -e "$g_trigger" ]]
then
  g_echo_warn "Kodi has not consumed the sync request yet; it will start at the next service loop"
fi

g_echo_note "kodi-jellyfin-library-triggered"
