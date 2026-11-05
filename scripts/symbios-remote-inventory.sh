#!/bin/bash
# SymbiOS - Inventory and row actions for external-services playbooks.
#
# The # docs: block of the playbook is the single source of truth. Its
# docs.inventory section declares
#   command    shell snippet that lists the existing resources on the target
#              (one record per line, tab separated)
#   columns    column keys + labels, in the order the command prints them
#   actions    row actions, each with the playbook to run, the variable
#              mapping (variable -> column key) and fixed extras; an action
#              with a download block fetches a file instead of running one
#
# This script knows nothing about the target's operating system: it runs the
# declared command over SSH and maps the declared values back. Every playbook
# that targets a remote system can use it.
#
# Usage:
#   symbios-remote-inventory.sh list <target_id> <playbook>
#   symbios-remote-inventory.sh action <target_id> <playbook> <action> [row.json]
#   symbios-remote-inventory.sh download <target_id> <playbook> <action> [row.json]
#
# The row for an action is a JSON object (column key -> value) on stdin or in
# the optional file, so values never show up in the process list.

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") list <target_id> <playbook>
       $(basename "$0") action <target_id> <playbook> <action> [<row.json>]
       $(basename "$0") download <target_id> <playbook> <action> [<row.json>]

List the existing resources of an external system, run one row action or
fetch the file one row action declares (download).

The inventory is declared in the playbook's # docs: block
(docs.inventory.command, .columns, .actions), so the WebUI and this script
need no knowledge about the target's operating system.

Arguments:
  <target_id>   id of an entry in ${g_config_dir}/external-systems.yml
  <playbook>    playbook file name below external-services/
                (e.g. openwrt_wireguard-tor-client.yml)
  <action>      name of an entry in docs.inventory.actions
  <row.json>    JSON object of the row (column key -> value); read from stdin
                when omitted

Options:
  -h, --help    Show this help and exit

Examples:
  $(basename "$0") list openwrt-og openwrt_wireguard-tor-client.yml
  echo '{"name":"pi_kodi_heidi"}' | \\
    $(basename "$0") action openwrt-og openwrt_wireguard-tor-client.yml remove
  echo '{"name":"pi_kodi_heidi"}' | \\
    $(basename "$0") download openwrt-og openwrt_wireguard-tor-client.yml download

Output (list): JSON {"ok":true,"columns":[...],"rows":[...],"count":N}
Output (action): the plain output of the playbook run.
Output (download): the raw file content on stdout, errors on stderr.

Exit codes:
  0  ok
  1  technical error (SSH failed, invalid docs block, write failed)
  2  usage error (unknown action, missing docs.inventory, bad row JSON)
EOF
}

function f_fail {
  g_echo_error "$1"
  exit "${2:-1}"
}

# Print the # docs: block of a playbook as JSON. Mirrors the extraction in
# webui/main/playbook_catalog.py: the leading comment block up to the first
# non-comment line, starting at "docs:".
function f_docs_json {
  python3 - "$1" << 'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as fh:
        lines = fh.read().splitlines()
except OSError as exc:
    sys.exit('Cannot read %s: %s' % (path, exc))

block = []
in_comment = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('#'):
        in_comment = True
        block.append(line)
    elif in_comment and stripped == '':
        continue
    elif in_comment:
        break

docs = []
in_docs = False
for line in block:
    content = line[2:] if line.startswith('# ') else line[1:]
    if not in_docs:
        if content.startswith('docs:'):
            in_docs = True
            docs.append(content)
    else:
        docs.append(content)

if not docs:
    sys.exit('No # docs: block found in %s' % path)

try:
    import yaml
    data = yaml.safe_load('\n'.join(docs))
except Exception as exc:
    sys.exit('Invalid # docs: block in %s: %s' % (path, exc))

print(json.dumps((data or {}).get('docs') or {}))
PY
}

# Print the inventory command of a docs JSON document.
function f_inventory_command {
  python3 -c 'import json,sys; inv=(json.load(open(sys.argv[1])) or {}).get("inventory") or {}; print(inv.get("command") or "")' "$1"
}

# --- arguments --------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

g_mode="${1:-}"
g_target="${2:-}"
g_playbook="${3:-}"
if [[ ! "${g_mode}" =~ ^(list|action|download)$ || -z "${g_target}" || -z "${g_playbook}" ]]
then
  f_usage >&2
  exit 2
fi
shift 3

# --- resolve target and playbook --------------------------------------------
if ! f_external_target "${g_target}"
then
  f_fail "Unknown external system: ${g_target} (see ${g_config_dir}/external-systems.yml)"
fi

# Only plain file names below external-services/ (no paths, no traversal).
if [[ ! "${g_playbook}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.yml$ ]]
then
  f_fail "Invalid playbook name: ${g_playbook}" 2
fi
g_playbook_path="${g_git_root}/external-services/${g_playbook}"
if [[ ! -f "${g_playbook_path}" ]]
then
  f_fail "Playbook not found: external-services/${g_playbook}"
fi

g_work_dir=$(mktemp -d) || f_fail "Cannot create a temporary directory"
trap 'rm -rf "${g_work_dir}"' EXIT

g_docs="${g_work_dir}/docs.json"
if ! f_docs_json "${g_playbook_path}" > "${g_docs}"
then
  f_fail "Cannot read the # docs: block of ${g_playbook}"
fi

# Both modes need a declared inventory, otherwise there is nothing to show.
if ! python3 -c 'import json,sys; sys.exit(0 if ((json.load(open(sys.argv[1])) or {}).get("inventory")) else 1)' "${g_docs}"
then
  f_fail "No docs.inventory declared in ${g_playbook}" 2
fi

# --- action and download: resolve the row, then run or fetch ---------------
# Read the row JSON (column key -> value) into a file. Values may contain
# secrets, so they never travel as argv: a file name is optional, otherwise
# stdin is read.
function f_read_row {
  local f_dest="$1"
  local f_src="${2:-}"
  if [[ -n "${f_src}" ]]
  then
    cp "${f_src}" "${f_dest}" || return 1
  else
    cat > "${f_dest}" || return 1
  fi
}

# Map a row onto the action's declared values (vars + extra) and write them
# as a JSON object. Prints the playbook the action declares (empty when the
# action only downloads a file).
function f_action_values {
  python3 - "$1" "$2" "$3" "$4" << 'PY'
import json
import sys

docs_path, action_name, row_path, out_path = sys.argv[1:5]
with open(docs_path) as fh:
    inventory = (json.load(fh) or {}).get('inventory') or {}
actions = inventory.get('actions') or []
action = next((a for a in actions if a.get('name') == action_name), None)
if action is None:
    sys.exit('Unknown action "%s" for this playbook' % action_name)
try:
    with open(row_path) as fh:
        row = json.load(fh) or {}
except ValueError:
    sys.exit('Invalid row JSON (expected an object)')
if not isinstance(row, dict):
    sys.exit('Invalid row JSON (expected an object)')

values = {}
for var, column in (action.get('vars') or {}).items():
    values[str(var)] = str(row.get(str(column), ''))
for var, value in (action.get('extra') or {}).items():
    values[str(var)] = value

with open(out_path, 'w') as fh:
    json.dump(values, fh)
print((action.get('playbook') or '').strip())
PY
}

# Build the shell snippet of a download action. Every declared variable is
# substituted shell-quoted, so a row value can never break out of the snippet.
function f_download_command {
  python3 - "$1" "$2" "$3" << 'PY'
import json
import shlex
import sys

docs_path, action_name, vars_path = sys.argv[1:4]
with open(docs_path) as fh:
    inventory = (json.load(fh) or {}).get('inventory') or {}
actions = inventory.get('actions') or []
action = next((a for a in actions if a.get('name') == action_name), None)
if action is None:
    sys.exit('Unknown action "%s" for this playbook' % action_name)
download = action.get('download')
if not isinstance(download, dict):
    sys.exit('Action "%s" declares no download' % action_name)
command = (download.get('command') or '').strip()
if not command:
    sys.exit('Action "%s" declares no download command' % action_name)
with open(vars_path) as fh:
    values = json.load(fh) or {}

for var, value in values.items():
    quoted = shlex.quote(str(value))
    command = command.replace('{{ %s }}' % var, quoted)
    command = command.replace('{{%s}}' % var, quoted)

# An unresolved placeholder would reach the target's shell verbatim.
if '{{' in command:
    sys.exit('Unknown placeholder in the download command of action "%s"' % action_name)
print(command)
PY
}

if [[ "${g_mode}" == "action" ]]
then
  g_action="${1:-}"
  shift
  if [[ -z "${g_action}" ]]
  then
    f_usage >&2
    exit 2
  fi
  g_row="${g_work_dir}/row.json"
  f_read_row "${g_row}" "${1:-}" || f_fail "Cannot read the row JSON"
  g_vars="${g_work_dir}/vars.json"
  if ! g_action_playbook=$(f_action_values "${g_docs}" "${g_action}" "${g_row}" "${g_vars}")
  then
    f_fail "Cannot resolve action ${g_action} of ${g_playbook}" 2
  fi
  if [[ -z "${g_action_playbook}" ]]
  then
    f_fail "Action ${g_action} of ${g_playbook} declares no playbook" 2
  fi
  g_echo_note "Running ${g_action} (${g_action_playbook}) for one ${g_playbook} record on ${g_target}"
  exec "${g_script_dir}/symbios-run-remote-playbook.sh" \
    "${g_target}" "${g_action_playbook}" --vars-stdin < "${g_vars}"
fi

if [[ "${g_mode}" == "download" ]]
then
  g_action="${1:-}"
  shift
  if [[ -z "${g_action}" ]]
  then
    f_usage >&2
    exit 2
  fi
  g_row="${g_work_dir}/row.json"
  f_read_row "${g_row}" "${1:-}" || f_fail "Cannot read the row JSON"
  g_vars="${g_work_dir}/vars.json"
  if ! f_action_values "${g_docs}" "${g_action}" "${g_row}" "${g_vars}" > /dev/null
  then
    f_fail "Cannot resolve action ${g_action} of ${g_playbook}" 2
  fi
  if ! the_command=$(f_download_command "${g_docs}" "${g_action}" "${g_vars}")
  then
    f_fail "Cannot resolve the download command of ${g_playbook}" 2
  fi
  # Raw file content on stdout: never print a log line here, it is the payload.
  printf '%s\n' "${the_command}" | \
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}" sh -s
  exit $?
fi

# --- list: run the declared command on the target ---------------------------
g_command=$(f_inventory_command "${g_docs}")
if [[ -z "${g_command}" ]]
then
  f_fail "docs.inventory.command is empty in ${g_playbook}" 2
fi

g_raw="${g_work_dir}/rows.tsv"
if ! printf '%s\n' "${g_command}" | \
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -p "${g_ext_port}" "${g_ext_user}@${g_ext_host}" sh -s > "${g_raw}" 2> "${g_work_dir}/ssh.err"
then
  g_echo_error "$(cat "${g_work_dir}/ssh.err")"
  printf '{"ok":false,"error":%s}\n' "$(printf 'Cannot list the resources of %s' "${g_target}" | f_json_escape)"
  exit 1
fi

# Map the tab separated records onto the declared column keys.
python3 - "${g_docs}" "${g_raw}" << 'PY'
import json
import sys

docs_path, raw_path = sys.argv[1:3]
with open(docs_path) as fh:
    inventory = (json.load(fh) or {}).get('inventory') or {}
columns = [c.get('key') for c in (inventory.get('columns') or []) if c.get('key')]
if not columns:
    print(json.dumps({'ok': False, 'error': 'docs.inventory.columns is empty'}))
    sys.exit(0)

rows = []
with open(raw_path, errors='replace') as fh:
    for line in fh:
        line = line.rstrip('\n').rstrip('\r')
        if not line.strip():
            continue
        parts = line.split('\t')
        rows.append({key: (parts[i] if i < len(parts) else '') for i, key in enumerate(columns)})

print(json.dumps({'ok': True, 'columns': columns, 'rows': rows, 'count': len(rows)}))
PY
