#!/bin/bash
# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

# Restart all Docker Compose services cleanly after boot.
# Runs as a systemd oneshot at the end of the boot process.

source /etc/bash/gaboshlib.include
g_lockfile

for f_compose in $(find /symbios/base-services /symbios/services -maxdepth 2 -name docker-compose.yml | sort)
do
  f_dir=$(dirname "$f_compose")
  cd "$f_dir" || continue

  if docker compose down 2>/dev/null
  then
    g_echo "Stopped"
  fi

  if docker compose up -d 2>/dev/null
  then
    g_echo_ok "Started"
  else
    g_echo_error "Start failed"
  fi
done

g_echo_ok "All services processed."
