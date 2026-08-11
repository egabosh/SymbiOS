#!/bin/bash
# Index file storing Docker container information
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_index_file="${g_log_dir}/docker-containers.tsv"
g_temp_file="${g_index_file}.tmp"

# Write current container list to temp file
docker ps --no-trunc --format '{{.ID}}	{{.Names}}' > "$g_temp_file" 2>/dev/null

# Atomically replace index file
mv "$g_temp_file" "$g_index_file"

# Set permissions on index file
chmod 644 "$g_index_file"

# Grant read and execute on containers directory
setfacl -m u:10000:rx "$g_docker_root/containers/" 2>/dev/null

# Grant read and execute on each container subdirectory
for d in "$g_docker_root"/containers/*/
do
  setfacl -m u:10000:rx "$d" 2>/dev/null
done

# Grant read permission on each JSON log file
for f in "$g_docker_root"/containers/*/*-json.log
do
  setfacl -m u:10000:r "$f" 2>/dev/null
done
