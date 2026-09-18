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

# Ensure the WordPress shared-db .env file exists and is complete.
#
# Generates the root password for the shared MariaDB once and, for every
# instance passed as an argument, the database name, user and a per-instance
# password. Existing values are kept, so the file is safe to re-run any time.
# To rotate a single password, delete its line and re-run.
#
# The .env file lives in the compose project directory and is picked up
# automatically by docker compose for variable substitution.
#
# Usage: symbios-wordpress-env.sh <instance> [<instance> ...]

source /etc/bash/gaboshlib.include 1>/dev/null 2>&1 || true
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_script_dir/symbios-lib.sh" 1>/dev/null 2>&1 || true

g_env_dir="${g_services_root}/wordpress"
g_env_file="${g_env_dir}/.env"

# The playbook already creates the directory; be safe and ensure it exists too.
mkdir -p "$g_env_dir"
chmod 0750 "$g_env_dir"
touch "$g_env_file"
chmod 0600 "$g_env_file"

# Root password for the shared MariaDB, created once on first run.
if ! grep -q '^WORDPRESS_DB_ROOT_PASSWORD=' "$g_env_file"
then
  g_echo_note "Generating WORDPRESS_DB_ROOT_PASSWORD"
  printf 'WORDPRESS_DB_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> "$g_env_file"
fi

# Idempotently ensure the per-instance variables DB_USER / DB_PASSWORD / DB_NAME.
for f_name in "$@"
do
  f_var=$(printf '%s' "$f_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  f_db="wp_${f_name//-/_}"
  for f_suffix in DB_USER DB_PASSWORD DB_NAME
  do
    f_key="WORDPRESS_${f_var}_${f_suffix}"
    if grep -q "^${f_key}=" "$g_env_file"
    then
      continue
    fi
    case "$f_suffix" in
      DB_PASSWORD)
        f_value="$(openssl rand -hex 24)"
        ;;
      DB_USER|DB_NAME)
        f_value="$f_db"
        ;;
    esac
    printf '%s=%s\n' "$f_key" "$f_value" >> "$g_env_file"
    g_echo_note "Generated ${f_key}"
  done
done

g_echo_ok "WordPress .env up to date: ${g_env_file}"