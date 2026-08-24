#!/bin/bash
# symbios-feature-apply.sh - Generic feature executor for SymbiOS services.
#
# Reads plugin.yml (manifest) and features-state.yml (current state) from the
# service directory, maps WebUI parameters to Ansible extra-vars using the
# param_mapping defined in plugin.yml, then runs the target playbook.
#
# Usage: symbios-feature-apply.sh <service> <feature>
#
# Exit codes: 0 = success, 1 = usage/config error, 2 = playbook failure.
. /etc/bash/gaboshlib.include
source symbios-lib.sh

SERVICE="$1"
FEATURE="$2"

if [[ -z "$SERVICE" ]] || [[ -z "$FEATURE" ]]
then
  echo "Usage: $0 <service> <feature>"
  exit 1
fi

# plugin.yml and features/ live in the git repo (read-only source).
# features-state.yml is in the config dir (writable, same as WebUI container /config).
PLUGIN_DIR="${g_git_root}/services/${SERVICE}"
PLUGIN_YML="${PLUGIN_DIR}/plugin.yml"
STATE_YML="${g_config_dir}/services/${SERVICE}/features-state.yml"

if [[ ! -f "$PLUGIN_YML" ]]
then
  g_echo_error "plugin.yml not found for service: $SERVICE"
  exit 1
fi

if [[ ! -f "$STATE_YML" ]]
then
  g_echo_error "features-state.yml not found for service: $SERVICE"
  exit 1
fi

# Extract the feature block from plugin.yml using yq.
FEAT_YML=$(yq ".features[] | select(.id == \"$FEATURE\")" "$PLUGIN_YML" 2>/dev/null)
if [[ -z "$FEAT_YML" ]] || [[ "$FEAT_YML" = "null" ]]
then
  g_echo_error "Unknown feature: $FEATURE (service: $SERVICE)"
  exit 1
fi

# Parse feature metadata.
PLAYBOOK=$(echo "$FEAT_YML" | yq ".playbook" 2>/dev/null)
TARGET=$(echo "$FEAT_YML" | yq ".target" 2>/dev/null)
MAPPING=$(echo "$FEAT_YML" | yq -o=json ".param_mapping // {}" 2>/dev/null)

if [[ -z "$PLAYBOOK" ]] || [[ "$PLAYBOOK" = "null" ]]
then
  g_echo_error "No playbook defined for feature: $FEATURE"
  exit 1
fi

# Build Ansible extra-vars by mapping state values through param_mapping.
# Format: {"webui_param": "ansible_var", ...}
EXTRA_ARGS=""
if [[ "$MAPPING" != "{}" ]] && [[ -n "$MAPPING" ]]
then
  for ROW in $(echo "$MAPPING" | jq -r 'to_entries[] | "\(.key)|\(.value)"' 2>/dev/null)
  do
    WEBUI_PARAM="${ROW%%|*}"
    ANSIBLE_VAR="${ROW#*|}"
    VALUE=$(yq ".$FEATURE.params.$WEBUI_PARAM // .${FEATURE}.${WEBUI_PARAM} // empty" "$STATE_YML" 2>/dev/null)
    if [[ -n "$VALUE" ]] && [[ "$VALUE" != "null" ]] && [[ "$VALUE" != "" ]]
    then
      EXTRA_ARGS="$EXTRA_ARGS -e ${ANSIBLE_VAR}=${VALUE}"
    fi
  done
fi

g_echo_note "Applying feature: $SERVICE/$FEATURE (playbook: $PLAYBOOK, target: ${TARGET:-vm})"

# Run the playbook against the appropriate target.
PLAYBOOK_PATH="${PLUGIN_DIR}/features/${PLAYBOOK}"
if [[ ! -f "$PLAYBOOK_PATH" ]]
then
  g_echo_error "Playbook not found: $PLAYBOOK_PATH"
  exit 1
fi

if [[ "$TARGET" = "host" ]]
then
  # Host-side playbook: runs locally with Ansible's local connection.
  ansible-playbook -i localhost, --connection=local \
    $EXTRA_ARGS \
    "$PLAYBOOK_PATH"
else
  # VM-side playbook: SSH into the target (default).
  VM_IP=$(yq '.vars.vm_ip // "192.168.41.201"' "${g_git_root}/services/${SERVICE}.yml" 2>/dev/null)
  VM_IP="${VM_IP:-192.168.41.201}"
  ansible-playbook -i "${VM_IP}," -u root \
    --timeout=30 --connect-timeout=10 \
    $EXTRA_ARGS \
    "$PLAYBOOK_PATH"
fi

RC=$?
if [[ $RC -eq 0 ]]
then
  g_echo_ok "Feature $FEATURE applied successfully"
else
  g_echo_error "Feature $FEATURE failed (exit code: $RC)"
fi
exit $RC
