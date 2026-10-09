#!/bin/bash
# SymbiOS - Scaffold a new symbios-settings-<slug>.sh CLI script.
#
# Creates the script skeleton from the template (contract: get/set/schema,
# --check, exit 0/2/1, state token) plus the registry row snippet for
# webui/main/settings_registry.py. The new script manages flat string
# fields under all.vars; adjust validation, secrets and merge building
# for the domain afterwards. See AGENTS.md (Settings CLI-first).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <slug>

Scaffold scripts/symbios-settings-<slug>.sh from the template, where
<slug> matches the WebUI page /settings/<slug>/ (lowercase, digits and
hyphens, e.g. ai-speech). Prints the registry row snippet for
webui/main/settings_registry.py to stdout.

The skeleton manages FIELDS as flat string vars with identical flag and
inventory names (--my-flag maps to my_flag only when spelled that way -
adjust otherwise). Secrets need --json-stdin handling like
symbios-settings-ai.sh; dict/list backends need dict-merge like
symbios-settings-openvpn.sh.

Examples:
  $(basename "$0") my-feature

Exit codes:
  0  scaffold written
  2  usage error (bad slug, file exists, ...)
  1  technical error
EOF
}

f_slug="${1:-}"
if [[ -z "${f_slug}" ]]
then
  f_usage >&2
  exit 2
fi
if ! [[ "${f_slug}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
then
  echo "Invalid slug: ${f_slug} (lowercase, digits, hyphens)" >&2
  exit 2
fi

source /etc/bash/gaboshlib.include 2>/dev/null || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
f_target="${g_symbios_dir}/symbios-settings-${f_slug}.sh"
if [[ -e "${f_target}" ]]
then
  echo "Refusing to overwrite existing ${f_target}" >&2
  exit 2
fi

# Uppercase token base: my-feature -> MY-FEATURE (adjust to domain style).
f_token="${f_slug^^}"

cat > "${f_target}" << 'TEMPLATE_EOF'
#!/bin/bash
# SymbiOS - Manage SLUG_PLACEHOLDER settings.
#
# Settings CLI-first architecture: the WebUI page /settings/SLUG_PLACEHOLDER/ is a
# thin wrapper (or generic registry entry) around this script, which owns
# validation and the inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction). Shared plumbing
# (f_ss_fail_*, f_ss_parse_bool, f_ss_require_url, f_ss_merge, ...) comes
# from symbios-settings-lib.sh - keep only usage text, option parsing,
# domain validation and JSON building here.

function f_usage {
  cat << USAGE
Usage: $(basename "$0") <command> [options]

Manage SymbiOS SLUG_PLACEHOLDER settings.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--field VALUE ... | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  --json-stdin reads the full field object.
                                  Empty values delete the key.
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (TOKEN_PLACEHOLDER-changed / TOKEN_PLACEHOLDER-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
USAGE
}

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

# TODO: adjust fields, validation, secrets (--json-stdin) and merge below.
TEMPLATE_EOF
sed -i "s/SLUG_PLACEHOLDER/${f_slug}/g; s/TOKEN_PLACEHOLDER/${f_token}/g" "${f_target}"
chmod 0755 "${f_target}"

g_echo_note "Scaffold written: ${f_target}" 2>/dev/null || echo "Scaffold written: ${f_target}"
cat << EOF

Registry row snippet for webui/main/settings_registry.py:
    'SLUG_PLACEHOLDER': {
        'script': 'symbios-settings-SLUG_PLACEHOLDER.sh',
        'title': '<Title>',
        'icon': 'bi-gear',
        'explain': '<explain-key>',
        'playbooks': [],
        'force': False,
        'message': '<Title> settings saved.',
    },

Contract smoke test (on the host, after rsync scripts/):
  symbios-settings-SLUG_PLACEHOLDER.sh --help
  symbios-settings-SLUG_PLACEHOLDER.sh get
  symbios-settings-SLUG_PLACEHOLDER.sh schema | python3 -c "import json,sys; json.load(sys.stdin)"
  symbios-settings-SLUG_PLACEHOLDER.sh set --check   # must change nothing
EOF
exit 0
