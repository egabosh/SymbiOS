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
# Seed plugin.video.jellyfin auth state from a password entered in the Kodi
# Options WebUI. The password is read from a transient file and never passed
# on the command line.

g_secret_files=()

function f_secret_cleanup {
  local f_file
  for f_file in "${g_secret_files[@]}"
  do
    [[ -e "$f_file" ]] && shred -u "$f_file" 2>/dev/null || true
  done
}
trap f_secret_cleanup EXIT

# Create a transient file and register it for shredding on exit. Call this
# directly, never inside $(...), so the EXIT trap is changed in this process.
function f_secret_tmp {
  local f_prefix="$1" f_target="$2" f_file
  f_file=$(mktemp "${TMPDIR:-/tmp}/kodi-login-${f_prefix}-XXXXXX") || return 1
  chmod 0600 "$f_file"
  printf -v "$f_target" '%s' "$f_file"
  g_secret_files+=("$f_file")
}

if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include || true
fi

f_usage() {
  cat <<'EOF'
Usage: symbios-kodi-jellyfin-login.sh --server URL --user NAME --password-file PATH --data-dir PATH

Authenticate to a Jellyfin server and seed the Kodi addon data.json with the
resulting device token so no manual sign-in is needed in the Kodi UI.

Options:
  --server URL          Base URL of the Jellyfin server, e.g. https://jellyfin.example.invalid
  --user NAME           Jellyfin user name
  --password-file PATH  Transient 0600 file holding the plaintext password
  --data-dir PATH       Addon data directory (owns the resulting data.json)
  -h, --help            Show this help

Output:
  Status lines plus a final kodi-jellyfin-login-changed or
  kodi-jellyfin-login-unchanged token.

Exit codes:
  0 success or unchanged, 1 technical error, 2 usage error.
EOF
}

g_server=""
g_user=""
g_password_file=""
g_data_dir=""
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { g_echo_error "--server needs a value"; f_usage >&2; exit 2; }
      g_server="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || { g_echo_error "--user needs a value"; f_usage >&2; exit 2; }
      g_user="$2"
      shift 2
      ;;
    --password-file)
      [[ $# -ge 2 ]] || { g_echo_error "--password-file needs a value"; f_usage >&2; exit 2; }
      g_password_file="$2"
      shift 2
      ;;
    --data-dir)
      [[ $# -ge 2 ]] || { g_echo_error "--data-dir needs a value"; f_usage >&2; exit 2; }
      g_data_dir="$2"
      shift 2
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$g_server" || -z "$g_user" || -z "$g_password_file" || -z "$g_data_dir" ]]
then
  g_echo_error "Missing required option"
  f_usage >&2
  exit 2
fi

if [[ ! -s "$g_password_file" ]]
then
  g_echo_error "Missing or empty password file: $g_password_file"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1
then
  g_echo_error "curl and jq are required"
  exit 1
fi

source "${g_script_dir}/symbios-lib.sh"
g_lockfile

# Remove a trailing slash so the URL joins below cannot produce a double slash.
g_server="${g_server%/}"

# A still-valid token avoids a new session (and a Kodi restart) on every
# reapply. Check the existing token against the server first; the token travels
# in a 0600 header file, never in argv or in a curl config value.
if [[ -s "$g_data_dir/data.json" ]]
then
  f_existing_token="$(jq -er '.Servers[0].AccessToken // empty' \
    "$g_data_dir/data.json" 2>/dev/null || true)"
  f_existing_address="$(jq -er '.Servers[0].address // empty' \
    "$g_data_dir/data.json" 2>/dev/null || true)"
  if [[ -n "$f_existing_token" && "$f_existing_address" == "$g_server" ]]
  then
    f_secret_tmp jfcheckhdr f_check_hdr
    f_secret_tmp jfcheck f_check
    f_secret_tmp jfcheckcfg f_check_cfg
    printf 'Authorization: MediaBrowser Client="SymbiOS", Device="Kodi Setup", DeviceId="symbios-kodi-login", Version="1.0", Token="%s"\n' \
      "$f_existing_token" > "$f_check_hdr"
    printf 'request = "GET"\n' > "$f_check_cfg"
    printf 'url = "%s/Users/Me"\n' "$g_server" >> "$f_check_cfg"
    printf 'header = "Accept: application/json"\n' >> "$f_check_cfg"
    printf 'output = "%s"\n' "$f_check" >> "$f_check_cfg"
    f_code="$(curl -sS --config "$f_check_cfg" -H @"$f_check_hdr" \
      -w '%{http_code}' || true)"
    if [[ "$f_code" == "200" ]]
    then
      g_echo_note "kodi-jellyfin-login-unchanged"
      exit 0
    fi
  fi
fi

# Authenticate as the technical user. Jellyfin 12 needs the client metadata in
# the Authorization header instead of the legacy X-Emby-* headers. The header
# is read from a file: curl's config parser truncates a quoted header value at
# the first embedded quote, which makes Jellyfin see an empty request.App.
f_secret_tmp jfbody f_body
f_secret_tmp jfauth f_auth
f_secret_tmp jfauthhdr f_auth_hdr
jq -n --arg f_user "$g_user" --rawfile f_pw "$g_password_file" \
  '{Username: $f_user, Pw: ($f_pw | rtrimstr("\n") | rtrimstr("\r"))}' > "$f_body" || exit 1
printf 'Authorization: MediaBrowser Client="SymbiOS", Device="Kodi Setup", DeviceId="symbios-kodi-login", Version="1.0"\n' \
  > "$f_auth_hdr"
f_secret_tmp jfcurlauth f_curl_auth
printf 'request = "POST"\n' > "$f_curl_auth"
printf 'url = "%s/Users/AuthenticateByName"\n' "$g_server" >> "$f_curl_auth"
printf 'header = "Accept: application/json"\n' >> "$f_curl_auth"
printf 'header = "Content-Type: application/json"\n' >> "$f_curl_auth"
printf 'data = "@%s"\n' "$f_body" >> "$f_curl_auth"
printf 'output = "%s"\n' "$f_auth" >> "$f_curl_auth"
f_code="$(curl -sS --config "$f_curl_auth" -H @"$f_auth_hdr" \
  -w '%{http_code}' || true)"
if [[ "$f_code" != "200" ]]
then
  g_echo_error "Jellyfin authentication failed for $g_user (HTTP $f_code)"
  exit 1
fi

f_secret_tmp jftoken f_token
f_secret_tmp jfuid f_user_id
jq -er '.AccessToken' "$f_auth" > "$f_token" || exit 1
jq -er '.User.Id' "$f_auth" > "$f_user_id" || exit 1
chmod 0600 "$f_token" "$f_user_id"

# The addon needs the stable server Id and display name from System/Info.
f_secret_tmp jfinfo f_info
f_secret_tmp jfcurlinfo f_curl_info
printf 'request = "GET"\n' > "$f_curl_info"
printf 'url = "%s/System/Info/Public"\n' "$g_server" >> "$f_curl_info"
printf 'header = "Accept: application/json"\n' >> "$f_curl_info"
printf 'output = "%s"\n' "$f_info" >> "$f_curl_info"
f_code="$(curl -sS --config "$f_curl_info" -w '%{http_code}' || true)"
if [[ "$f_code" != "200" ]]
then
  g_echo_error "Could not read Jellyfin server info (HTTP $f_code)"
  exit 1
fi

f_secret_tmp jfsid f_server_id
f_secret_tmp jfsname f_server_name
jq -er '.Id' "$f_info" > "$f_server_id" || exit 1
jq -er '.ServerName' "$f_info" > "$f_server_name" || exit 1

# Build the addon credential file. Only the keys the addon itself consumes are
# compared below, so an addon upgrade adding fields does not force a rewrite.
# Native-mode path replacements live in the same file and have to survive a
# token rotation, so carry the existing "paths" mapping into the new document.
f_secret_tmp jfdesired f_desired
f_secret_tmp jfdesiredown f_desired_own
f_secret_tmp jfcurrent f_current
f_secret_tmp jfpaths f_paths
if [[ -s "$g_data_dir/data.json" ]]
then
  jq -c '.Servers[0].paths // {}' "$g_data_dir/data.json" > "$f_paths" || exit 1
else
  printf '{}\n' > "$f_paths"
fi
jq -n \
  --argjson f_paths "$(< "$f_paths")" \
  --arg f_id "$(tr -d '\r\n' < "$f_server_id")" \
  --arg f_name "$(tr -d '\r\n' < "$f_server_name")" \
  --arg f_address "$g_server" \
  --arg f_now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --rawfile f_user "$f_user_id" \
  --rawfile f_token "$f_token" \
  '{Servers: [{Id: $f_id, Name: $f_name, address: $f_address,
      UserId: ($f_user | rtrimstr("\n") | rtrimstr("\r")),
      AccessToken: ($f_token | rtrimstr("\n") | rtrimstr("\r")),
      DateLastAccessed: $f_now,
      paths: $f_paths,
      Users: [{Id: ($f_user | rtrimstr("\n") | rtrimstr("\r")), IsSignedInOffline: true}]}]}' > "$f_desired" || exit 1
jq -S '{Servers: [.Servers[0] | {Id, Name, address, UserId, AccessToken, paths, Users}]}' \
  "$f_desired" > "$f_desired_own" || exit 1
: > "$f_current"
if [[ -s "$g_data_dir/data.json" ]]
then
  jq -S '{Servers: [.Servers[0] | {Id, Name, address, UserId, AccessToken, paths, Users}]}' \
    "$g_data_dir/data.json" > "$f_current" || exit 1
fi

if cmp -s "$f_current" "$f_desired_own"
then
  g_echo_note "kodi-jellyfin-login-unchanged"
  exit 0
fi

install -d -o kodi -g kodi -m 0750 "$g_data_dir" || exit 1
install -o kodi -g kodi -m 0600 "$f_desired" "$g_data_dir/data.json" || exit 1
g_echo_note "kodi-jellyfin-login-changed"
