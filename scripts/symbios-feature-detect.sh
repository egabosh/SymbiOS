#!/bin/bash
# symbios-feature-detect.sh - Generic feature parameter detection for SymbiOS.
#
# Reads plugin.yml to find the detect script for a given feature parameter,
# then runs it and outputs JSON (array of {value, label} objects).
#
# Usage: symbios-feature-detect.sh <service> <feature> <param>
#
# Exit codes: 0 = success, 1 = usage/config error.
. /etc/bash/gaboshlib.include
source symbios-lib.sh

SERVICE="$1"
FEATURE="$2"
PARAM="$3"

if [[ -z "$SERVICE" ]] || [[ -z "$FEATURE" ]] || [[ -z "$PARAM" ]]
then
  echo "Usage: $0 <service> <feature> <param>"
  exit 1
fi

PLUGIN_DIR="${g_services_root}/${SERVICE}"
PLUGIN_YML="${PLUGIN_DIR}/plugin.yml"

if [[ ! -f "$PLUGIN_YML" ]]
then
  g_echo_error "plugin.yml not found for service: $SERVICE"
  exit 1
fi

# Read the detect script path from plugin.yml.
SCRIPT=$(yq ".features[] | select(.id == \"$FEATURE\") | .params[] | select(.name == \"$PARAM\") | .detect // empty" "$PLUGIN_YML" 2>/dev/null)

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
