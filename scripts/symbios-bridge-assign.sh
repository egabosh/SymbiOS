#!/bin/bash
# SymbiOS - Apply interface-to-bridge assignments and persist them across
# reboots in /etc/rc.local.
#
# Usage: echo '{"wlan0":"br-lan","eth1":"br-lan"}' | symbios-bridge-assign.sh
#
# Reads a JSON dict (interface -> bridge) from stdin, applies it immediately
# with `ip link set ... master ...`, releases interfaces that were dropped,
# and regenerates the rc.local boot block (markers below) so the assignments
# are restored once networking is up after boot.
#
# Only names matching [A-Za-z0-9_.@-] are accepted; everything else is
# rejected so command injection is impossible.

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_marker="SymbiOS Network Bridge Assignments"
g_pairs_file="$(mktemp)"
g_old_pairs_file="$(mktemp)"
trap 'rm -f "${g_pairs_file}" "${g_old_pairs_file}"' EXIT

# Parse a JSON/YAML dict into "iface<TAB>bridge" lines (stdin -> stdout).
# Validates names against [A-Za-z0-9_.@-] and rejects non-dict input.
f_parse_pairs() {
  python3 - "$1" <<'PYEOF'
import re
import sys
import yaml

raw = sys.argv[1]
try:
    data = yaml.safe_load(raw) or {}
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)
name_re = re.compile(r'^[A-Za-z0-9_.@-]+$')
out = []
for iface, bridge in sorted(data.items()):
    if not name_re.match(str(iface)) or not name_re.match(str(bridge)):
        sys.exit(2)
    out.append(str(iface) + "\t" + str(bridge))
if out:
    out.append("")
sys.stdout.write("\n".join(out))
PYEOF
}

# Insert/replace the marker block in /etc/rc.local (idempotent). The ignored
# marker in the heredoc gets replaced at runtime via string substitution.
f_rc_update() {
  python3 - "$g_marker" "$1" <<'PYEOF'
import sys

marker, block = sys.argv[1], sys.argv[2]
rc_path = "/etc/rc.local"
begin = "# " + marker
end = "# " + marker + " end"

try:
    with open(rc_path) as fh:
        content = fh.read()
except FileNotFoundError:
    content = ""
if content and not content.endswith("\n"):
    content += "\n"

blocktext = ""
if block:
    blocktext = (
        "{begin}\n"
        "# Restore interface-to-bridge assignments (managed by "
        "Settings -> Network Bridges).\n"
        "{block}\n"
        "{end}\n"
    ).format(begin=begin, block=block, end=end)

# Build the new file line by line, dropping any old marker range (identical
# for first install and rerun, so the update is idempotent). Exact equality
# is used for the markers so the end marker ("<begin> end") cannot be
# mistaken for a new begin marker (startswith would match both).
lines = content.splitlines(keepends=True)
out = []
skipping = False
for line in lines:
    if line.strip() == begin:
        skipping = True
        continue
    if line.strip() == end:
        skipping = False
        continue
    if not skipping:
        out.append(line)

if blocktext:
    # Insert the (new) block before the final "exit 0" line. Leftover blank
    # lines from a previous block are dropped first, so repeated runs leave
    # the file byte-identical (no blank lines pile up).
    inserted = False
    result = []
    for line in out:
        if not inserted and line.strip() == "exit 0":
            while result and result[-1].strip() == "":
                result.pop()
            result.append("\n" + blocktext)
            inserted = True
        result.append(line)
    if not inserted:
        while result and result[-1].strip() == "":
            result.pop()
        if result and not result[-1].endswith("\n"):
            result[-1] += "\n"
        result.append(blocktext + "\n")
    out = result

new_content = "".join(out).rstrip("\n") + "\n"
if new_content == content.rstrip("\n") + "\n":
    sys.exit(0)  # unchanged

with open(rc_path, "w") as fh:
    fh.write(new_content)
try:
    import os
    os.chmod(rc_path, 0o755)
except Exception:
    pass
PYEOF
}

# Read the stored assignments dict from inventory.yml (block or flow YAML).
f_read_inventory_assignments() {
  python3 - "${g_inventory}" <<'PYEOF' 2>/dev/null
import json
import sys
import yaml

path = sys.argv[1]
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(1)
assignments = (cfg.get('all', {}).get('vars', {})
               .get('bridge_assignments') or {})
print(json.dumps(assignments))
PYEOF
}

# Read the JSON from stdin (the WebUI/detached job pipes the .input file).
# Without stdin (e.g. playbook reapply) fall back to the inventory value so a
# reapply re-establishes the current assignments.
g_json="$(cat)"
if [[ -z "${g_json}" ]]
then
  g_json="$(f_read_inventory_assignments)"
fi
[[ -z "${g_json}" ]] && g_json='{}'

# Parse the submitted assignments.
if ! f_parse_pairs "${g_json}" > "${g_pairs_file}"
then
  f_json_error "Invalid bridge assignments: expected an object mapping interfaces to bridges"
fi

# Previous assignments from the inventory (state already applied before).
g_old_json="$(f_read_inventory_assignments)"
[[ -z "${g_old_json}" ]] && g_old_json='{}'
f_parse_pairs "${g_old_json}" > "${g_old_pairs_file}" 2>/dev/null || true

# Collect the new interface set so dropped interfaces can be released.
g_new_ifaces=""
while IFS=$'\t' read -r f_iface f_bridge
do
  [[ -z "${f_iface}" ]] && continue
  g_new_ifaces="${g_new_ifaces} ${f_iface}"
done < "${g_pairs_file}"

# 1. Release interfaces that are no longer assigned to any bridge.
if [[ -s "${g_old_pairs_file}" ]]
then
  while IFS=$'\t' read -r f_iface f_bridge
  do
    [[ -z "${f_iface}" ]] && continue
    if [[ " ${g_new_ifaces} " != *" ${f_iface} "* ]]
    then
      g_echo_debug "Releasing interface ${f_iface} from ${f_bridge}"
      ip link set "${f_iface}" nomaster 2>/dev/null || true
    fi
  done < "${g_old_pairs_file}"
fi

# 2. Apply the new assignments. The bridge must already exist; a missing
#    bridge is an error the WebUI user should see immediately.
g_error=""
while IFS=$'\t' read -r f_iface f_bridge
do
  [[ -z "${f_iface}" ]] && continue
  if ! ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -qx "${f_bridge}"
  then
    g_echo_error "Bridge '${f_bridge}' does not exist - cannot assign ${f_iface}"
    g_error="yes"
    continue
  fi
  g_echo "Assigning ${f_iface} to bridge ${f_bridge}"
  if ! ip link set "${f_iface}" master "${f_bridge}"
  then
    g_echo_error "Failed to assign ${f_iface} to bridge ${f_bridge}"
    g_error="yes"
  fi
done < "${g_pairs_file}"

# 3. Regenerate the rc.local block with the submitted assignments. This is
#    done even when an error occurred above so the boot block always matches
#    the saved config.
g_rc_block=""
while IFS=$'\t' read -r f_iface f_bridge
do
  [[ -n "${g_rc_block}" ]] && g_rc_block="${g_rc_block}"$'\n'
  g_rc_block="${g_rc_block}ip link set ${f_iface} master ${f_bridge} >/dev/null 2>&1 || true"
done < "${g_pairs_file}"
f_rc_update "${g_rc_block}"

if [[ -n "${g_error}" ]]
then
  exit 1
fi
# The colliding comment on the inventory write is avoided: this script reports
# success, the WebUI already saved the assignments into inventory.yml before
# starting the job, so no write-back is needed here.
exit 0