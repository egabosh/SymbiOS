#!/bin/bash

# SymbiOS - Debian-based server management platform
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

# Provision databases and users for WordPress instances on the shared MariaDB.
#
# Reads the credentials from the wordpress .env file (see
# symbios-wordpress-env.sh), waits for MariaDB to accept connections and then
# creates DATABASE + USER per instance. All statements are idempotent, so the
# script is safe to re-run (e.g. to add a new instance). The database is
# utf8mb4/utf8mb4_unicode_ci to support full UTF-8 content.
#
# Usage: symbios-wordpress-db.sh <instance> [<instance> ...]

source /etc/bash/gaboshlib.include 1>/dev/null 2>&1 || true
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_script_dir/symbios-lib.sh" 1>/dev/null 2>&1 || true

g_db_container="symbios-wordpress-db"
g_env_file="${g_services_root}/wordpress/.env"

# Read a single KEY=value line from the .env file.
function f_env_value {
  local f_key="$1"
  sed -n "s/^${f_key}=//p" "$g_env_file" | tail -1
}

# Wait until MariaDB in the shared container answers "ping" (first boot takes
# a while because the data directory is initialized). Give up after 120 s.
g_tries=0
while ! docker exec "$g_db_container" mariadb-admin ping -h localhost --silent >/dev/null 2>&1
do
  g_tries=$((g_tries + 1))
  if [[ "$g_tries" -ge 60 ]]
  then
    g_echo_error "MariaDB (${g_db_container}) did not become ready in time"
    exit 1
  fi
  sleep 2
done
g_echo_note "MariaDB (${g_db_container}) is ready"

g_rootpw=$(f_env_value "WORDPRESS_DB_ROOT_PASSWORD")
if [[ -z "$g_rootpw" ]]
then
  g_echo_error "WORDPRESS_DB_ROOT_PASSWORD missing in ${g_env_file} (run symbios-wordpress-env.sh first)"
  exit 1
fi

for f_name in "$@"
do
  f_var=$(printf '%s' "$f_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  f_user=$(f_env_value "WORDPRESS_${f_var}_DB_USER")
  f_pass=$(f_env_value "WORDPRESS_${f_var}_DB_PASSWORD")
  f_db=$(f_env_value "WORDPRESS_${f_var}_DB_NAME")
  if [[ -z "$f_user" ]] || [[ -z "$f_pass" ]] || [[ -z "$f_db" ]]
  then
    g_echo_error "Incomplete credentials for instance ${f_name} in ${g_env_file}, skipping"
    continue
  fi

  # The password travels via MYSQL_PWD so it never shows up in the process list.
  if docker exec -e "MYSQL_PWD=${g_rootpw}" -i "$g_db_container" mariadb -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${f_db}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${f_user}'@'%' IDENTIFIED BY '${f_pass}';
ALTER USER '${f_user}'@'%' IDENTIFIED BY '${f_pass}';
GRANT ALL PRIVILEGES ON \`${f_db}\`.* TO '${f_user}'@'%';
FLUSH PRIVILEGES;
SQL
  then
    g_echo_ok "Provisioned database ${f_db} for user ${f_user}"
  else
    g_echo_error "Failed to provision database ${f_db} for user ${f_user}"
  fi
done