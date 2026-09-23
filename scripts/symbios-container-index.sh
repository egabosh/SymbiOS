#!/bin/bash
# Index file storing Docker container information

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Refresh the Docker container index file <log>/docker-containers.tsv with the
current container list (id and name per line) and grant the WebUI container
(uid 10000) ACL read access to the container logs. Called by the WebUI on
demand; no arguments.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

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
