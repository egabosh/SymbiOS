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
# Propagate a rotated Jellyfin kodi password to Jellyfin. The store calls this
# hook with <secret-name> <new-value-file> <old-value-file>; a failure rolls the
# stored secret back, so exit non-zero on any propagation error.

set -u

f_name="${1:-}"
[[ "$f_name" == "jellyfin_kodi_password" ]] || exit 0

f_new_file="${2:-}"
if [[ ! -s "$f_new_file" ]]
then
  printf 'rotation hook: missing new value file\n' >&2
  exit 1
fi

# The hook lives in <git_root>/scripts/secret-rotation.d; the provisioner is
# one directory above it. The service dir contains the bootstrap admin token.
f_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f_service_dir="${JELLYFIN_SERVICE_DIR:-/symbios/services/jellyfin}"

exec "${f_script_dir}/symbios-jellyfin-provision.sh" \
  --config-dir "$f_service_dir" \
  --kodi-password-file "$f_new_file" \
  --rotate-kodi-password
