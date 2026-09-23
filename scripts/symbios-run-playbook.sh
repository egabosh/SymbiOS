#!/bin/bash
# SymbiOS - Run an Ansible playbook with standard flags

function f_usage {
  cat << EOF
Usage: $(basename "$0") <playbook_path>

Run an Ansible playbook with the standard SymbiOS flags
(--connection=local, --limit localhost, inventory from the WebUI config).
On success the playbook output is streamed to stdout; on failure a JSON
error is printed to stderr.

Arguments:
  <playbook_path>   path relative to the SymbiOS repo
                    (e.g. base-services/smtp.yml) or absolute

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# The playbook_path is relative to the SymbiOS repo (e.g. base-services/smtp.yml)

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_playbook="${1:-}"
g_repo="${g_git_root}"

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
