#!/bin/bash
# SymbiOS - Run an Ansible playbook with standard flags
# Usage: symbios-run-playbook.sh <playbook_path>
# The playbook_path is relative to /home/SymbiOS/ (e.g. base-services/smtp.yml)

source /etc/bash/gaboshlib.include

g_playbook="${1:-}"
g_inventory="/home/docker/symbios-ui/config/inventory.yml"
g_repo="/home/SymbiOS"

if [[ -z "$g_playbook" ]]
then
  echo '{"ok":false,"error":"Usage: symbios-run-playbook.sh <playbook_path>"}' >&2
  exit 1
fi

# Build full path if relative
if [[ "$g_playbook" != /* ]]
then
  g_full_path="${g_repo}/${g_playbook}"
else
  g_full_path="$g_playbook"
fi

if [[ ! -f "$g_full_path" ]]
then
  echo "{\"ok\":false,\"error\":\"Playbook not found: ${g_playbook}\"}" >&2
  exit 1
fi

exec ansible-playbook \
  --connection=local \
  --limit localhost \
  --inventory "$g_inventory" \
  -e ansible_python_interpreter=/usr/bin/python3 \
  "$g_full_path"
