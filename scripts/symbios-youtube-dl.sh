#!/bin/bash
# SymbiOS - download a video with yt-dlp through the one-shot container.
# Adapted from the legacy plain-Debian wrapper archived under
# media/_preshare/_system/usr/local/bin/youtube-dl.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <URL|yt-dlp option> ...

Run the yt-dlp one-shot container and download into the configured video
library (media_videos/downloads). Defaults are --no-playlist,
--download-archive in the target directory and --merge-output-format mp4;
arguments are appended after them, so yt-dlp options can refine them.
After a successful download the Nextcloud media index is refreshed in the
background (at most one scan at a time).

Options:
  -h, --help   Show this help and exit (use yt-dlp directly for its own help)

Examples:
  $(basename "$0") https://www.youtube.com/watch?v=VIDEOID
  $(basename "$0") --format bestvideo+bestaudio URL

Output: yt-dlp output on stdout/stderr; warnings only for the optional
Nextcloud scan. Exit codes:
  0  download succeeded
  1  service directory missing
  2  usage error (missing URL)
  other  yt-dlp / docker exit code
EOF
}

# An empty call used to start yt-dlp without a target; fail loudly instead.
if [[ $# -eq 0 ]]
then
  f_usage >&2
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]
then
  f_usage
  exit 0
fi

# Resolve siblings even when called through the /usr/local/bin symlink.
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

g_service_dir="${g_services_root}/youtube-dl"
if [[ ! -d "${g_service_dir}" ]]
then
  g_echo_error "youtube-dl service directory missing: ${g_service_dir}" 2>/dev/null || echo "youtube-dl service directory missing: ${g_service_dir}" >&2
  exit 1
fi

# --build is required: the nightly docker prune removes the image because
# no container keeps a reference to it between downloads.
cd "${g_service_dir}" || exit 1
g_rc=0
docker compose run --build --rm youtube-dl --no-playlist \
  --download-archive /downloaddir/.download-archive \
  --merge-output-format mp4 "$@" || g_rc=$?

# Refresh the Nextcloud index for the download target only, never for the
# whole library. The lock keeps concurrent downloads from stacking scans.
if [[ ${g_rc} -eq 0 && -d "${g_services_root}/nextcloud" ]]
then
  (
    flock -n 9 || exit 0
    "${g_script_dir}/symbios-nextcloud-media-scan.sh" "Media Videos" >/dev/null 2>&1 || true
  ) 9>/tmp/youtube-dl-scan.lock &
  disown || true
fi

exit "${g_rc}"
