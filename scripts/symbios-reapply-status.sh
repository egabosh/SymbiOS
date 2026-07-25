#!/bin/bash
# SymbiOS - Read reapply status from host /tmp
# Output: raw status string (idle | running | running:N/T pb | done:N)

source /etc/bash/gaboshlib.include

g_status_file="/tmp/symbios-reapply.status"

if [[ -r "$g_status_file" ]]
then
  cat "$g_status_file"
else
  echo "idle"
fi
