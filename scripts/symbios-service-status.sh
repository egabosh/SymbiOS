#!/bin/bash
# File storing system service statuses
g_file=/home/docker/symbios-ui/log/symbios-services.tsv
g_tmp="${g_file}.tmp"

# Write status for each service to temp file
# No system services to track currently
echo -e "" > "$g_tmp"

# Set permissions on temp file
chmod 644 "$g_tmp"

# Atomically replace status file
mv "$g_tmp" "$g_file"
