#!/bin/bash
# Index file storing Docker container information
g_index_file=/home/docker/symbios-ui/log/docker-containers.tsv
g_temp_file="${g_index_file}.tmp"

# Write current container list to temp file
docker ps --no-trunc --format '{{.ID}}	{{.Names}}' > "$g_temp_file" 2>/dev/null

# Atomically replace index file
mv "$g_temp_file" "$g_index_file"

# Set permissions on index file
chmod 644 "$g_index_file"

# Grant read and execute on containers directory
setfacl -m u:10000:rx /var/lib/docker/containers/ 2>/dev/null

# Grant read and execute on each container subdirectory
for d in /var/lib/docker/containers/*/
do
  setfacl -m u:10000:rx "$d" 2>/dev/null
done

# Grant read permission on each JSON log file
for f in /var/lib/docker/containers/*/*-json.log
do
  setfacl -m u:10000:r "$f" 2>/dev/null
done
