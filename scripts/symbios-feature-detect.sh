#!/bin/bash
# symbios-feature-detect.sh - Generic feature parameter detection for SymbiOS.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <service> <feature> <param>

Generic feature parameter detection for SymbiOS. Reads plugin.yml to find
the detect script for a given feature parameter, runs it, and outputs JSON
(an array of {value, label} objects used to populate select/multi-select
params in the WebUI).

Arguments:
  service     service name (directory under <git_root>/services/)
  feature     feature id from plugin.yml
  param       parameter name from plugin.yml

Exit codes: 0 = success, 1 = usage/config error.

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

. /etc/bash/gaboshlib.include
source symbios-lib.sh

SERVICE="$1"
FEATURE="$2"
PARAM="$3"

if [[ -z "$SERVICE" ]] || [[ -z "$FEATURE" ]] || [[ -z "$PARAM" ]]
then
  f_usage
  exit 1
fi

# plugin.yml and features/ live in the git repo (same as symbios-feature-apply.sh).
PLUGIN_DIR="${g_git_root}/services/${SERVICE}"
PLUGIN_YML="${PLUGIN_DIR}/plugin.yml"

if [[ ! -f "$PLUGIN_YML" ]]
then
  g_echo_error "plugin.yml not found for service: $SERVICE"
  exit 1
fi

# Read the detect script path from plugin.yml.
# yq v4 syntax: no '// empty' (invalid in v4); missing paths print nothing.
SCRIPT=$(yq ".features[] | select(.id == \"$FEATURE\") | .params[] | select(.name == \"$PARAM\") | .detect" "$PLUGIN_YML" 2>/dev/null)

if [[ -z "$SCRIPT" ]] || [[ "$SCRIPT" = "null" ]]
then
  # No detect script: return empty array.
  echo "[]"
  exit 0
fi

SCRIPT_PATH="${PLUGIN_DIR}/features/${SCRIPT}"
if [[ ! -f "$SCRIPT_PATH" ]]
then
  g_echo_error "Detect script not found: $SCRIPT_PATH"
  echo "[]"
  exit 1
fi

# Run the detect script (must output JSON array of {value, label}).
bash "$SCRIPT_PATH"
