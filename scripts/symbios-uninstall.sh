#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# symbios-uninstall.sh - Uninstall a SymbiOS service.
#
# Reads the # docs: block from the playbook via yq and performs the
# uninstall according to the selected mode.
#
# Modes:
#   full    - Uninstall: stop containers (removing their images), run the
#             optional docs.uninstall.commands cleanup list, delete the whole
#             service dir plus program_paths and userdata_paths (recursive)
#             and clear the state entry.
#   program - Uninstall (keep data): stop containers (removing their images),
#             delete program_paths (Traefik provider, healthcheck, ...) while
#             keeping the service dir completely intact - compose file and
#             all data survive - and clear the state entry.
#   reset   - Delete Userdata: stop containers (images are kept), wipe the
#             service dir plus userdata_paths and re-run the playbook so the
#             service comes back freshly provisioned. The state entry stays.
#
# docs.uninstall schema:
#   stop           - whitelisted stop command (docker compose/systemctl/virsh)
#   commands       - optional list of whitelisted cleanup commands, executed
#                    in full mode only (docker compose/systemctl/ufw/userdel/
#                    groupdel/smbpasswd/deluser/delgroup)
#   ldap_groups    - optional list of LDAP groups deleted in full mode (even
#                    if they still have members); defaults to the groups
#                    named in docs.access (admin_group/user_group)
#   authelia_blocks- optional list of Ansible managed block marker suffixes
#                    ("OIDC nextcloud", "dabo ACCESS CONTROL", ...) removed
#                    from the Authelia configuration.yml in full mode;
#                    Authelia is restarted afterwards if something changed
#   service_dir    - optional explicit service dir (default for playbooks
#                    below services/: $services_root/<name>/); must live
#                    below the services root
#   program_paths  - files/dirs installed outside the service dir
#   userdata_paths - legacy extra data dirs outside the service dir
#
# Template variables {{ ansible_facts['hostname'] }}, {{ ansible_hostname }}
# and {{ base_domain }} are expanded in paths and commands.
#
# The obsolete "restart" key of old playbooks is ignored: reset now always
# re-runs the playbook instead of restarting via a single command.
#
# The playbook-path is relative to the git root, e.g. "services/jellyfin.yml".

source /etc/bash/gaboshlib.include 2>/dev/null || true
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_script_dir/symbios-lib.sh"

# Check required tools
if ! command -v yq &>/dev/null
then
  g_echo_error "yq is not installed. Cannot parse playbook metadata."
  exit 1
fi

# Validate arguments
if [[ $# -lt 2 ]]
then
  g_echo_error "Usage: symbios-uninstall.sh <playbook-path> <mode>"
  g_echo_error "Modes: full, program, reset"
  exit 1
fi

f_playbook="$1"
f_mode="$2"

# Validate mode
if [[ "$f_mode" != "full" && "$f_mode" != "program" && "$f_mode" != "reset" ]]
then
  g_echo_error "Invalid mode: $f_mode (must be full, program, or reset)"
  exit 1
fi

# Resolve the playbook file path
f_playbook_file="${g_git_root}/${f_playbook}"
if [[ ! -f "$f_playbook_file" ]]
then
  g_echo_error "Playbook not found: $f_playbook_file"
  exit 1
fi

# Extract the # docs: block from the playbook comment header.
# The docs block starts at "# docs:" and continues until a non-comment
# line is encountered. We strip the leading "# " prefix for yq.
f_tmp=$(mktemp)
f_in_docs=0
while IFS= read -r f_line
do
  f_stripped="${f_line#"${f_line%%[![:space:]]*}"}"
  if [[ "$f_in_docs" -eq 1 ]]
  then
    if [[ "$f_stripped" == \#* ]]
    then
      # Strip "# " or "#" prefix
      echo "${f_stripped}" | sed 's/^#[ ]\?//' >> "$f_tmp"
    else
      break
    fi
  elif [[ "$f_stripped" == "# docs:"* ]]
  then
    f_in_docs=1
    echo "${f_stripped}" | sed 's/^#[ ]\?//' >> "$f_tmp"
  fi
done < "$f_playbook_file"

if [[ ! -s "$f_tmp" ]]
then
  g_echo_error "No # docs: block found in $f_playbook"
  rm -f "$f_tmp"
  exit 1
fi

g_echo_note "Parsed docs block from $f_playbook"

# Expand supported template variables in strings from the docs block.
# The patterns are passed quoted so brackets/quotes are matched literally.
function f_expand_vars {
  local f_value="$1"
  local f_host
  f_host="$(hostname)"
  local f_p_facts="{{ ansible_facts['hostname'] }}"
  local f_p_hostname="{{ ansible_hostname }}"
  local f_p_domain="{{ base_domain }}"
  f_value="${f_value//"${f_p_facts}"/${f_host}}"
  f_value="${f_value//"${f_p_hostname}"/${f_host}}"
  f_value="${f_value//"${f_p_domain}"/${g_base_domain}}"
  echo "$f_value"
}

# --- Step 1: Stop services ---
f_stop_cmd=$(yq eval '.docs.uninstall.stop // ""' "$f_tmp" 2>/dev/null)
if [[ -n "$f_stop_cmd" ]]
then
  # In full/program mode the container images are removed too by extending
  # a plain docker compose down with --rmi all (scoped to this project).
  if [[ "$f_mode" != "reset" && "$f_stop_cmd" =~ ^(docker\ compose\ .*)down$ ]]
  then
    f_stop_cmd="${BASH_REMATCH[1]}down --rmi all"
    g_echo_note "Removing container images along with the stack (--rmi all)"
  fi
  # Whitelist: only allow known management commands
  if [[ "$f_stop_cmd" =~ ^(docker\ compose|systemctl|virsh)([[:space:]]|$) ]]
  then
    g_echo_note "Stopping services: $f_stop_cmd"
    eval "$f_stop_cmd"
  else
    g_echo_error "Invalid stop command (only docker compose/systemctl/virsh allowed): $f_stop_cmd"
    exit 1
  fi
else
  g_echo_note "No stop command defined, skipping service stop"
fi

# --- Step 2: Cleanup commands (full mode only) ---
if [[ "$f_mode" == "full" ]]
then
  f_commands=$(yq eval '.docs.uninstall.commands[]' "$f_tmp" 2>/dev/null)
  if [[ -z "$f_commands" ]]
  then
    g_echo_note "No cleanup commands defined"
  else
    while IFS= read -r f_raw_cmd
    do
      if [[ -z "$f_raw_cmd" ]]
      then
        continue
      fi
      f_cmd=$(f_expand_vars "$f_raw_cmd")
      # Whitelist: only allow known cleanup commands
      if [[ ! "$f_cmd" =~ ^(docker\ compose|systemctl|ufw|userdel|groupdel|smbpasswd|deluser|delgroup)([[:space:]]|$) ]]
      then
        g_echo_error "Invalid cleanup command (only docker compose/systemctl/ufw/userdel/groupdel/smbpasswd/deluser/delgroup allowed): $f_cmd"
        exit 1
      fi
      g_echo_note "Running cleanup command: $f_cmd"
      if ! eval "$f_cmd"
      then
        # Individual cleanup steps may already be gone - never fatal.
        g_echo_warn "Cleanup command failed (continuing): $f_cmd"
      fi
    done <<< "$f_commands"
  fi
fi

# --- Step 3: Delete LDAP groups (full mode only) ---
if [[ "$f_mode" == "full" ]]
then
  f_ldap_groups=$(yq eval '.docs.uninstall.ldap_groups[]' "$f_tmp" 2>/dev/null)
  # Fallback: derive the groups from docs.access (naming convention).
  if [[ -z "$f_ldap_groups" ]]
  then
    f_ldap_groups=$(printf '%s\n%s\n' \
      "$(yq eval '.docs.access.admin_group // ""' "$f_tmp" 2>/dev/null)" \
      "$(yq eval '.docs.access.user_group // ""' "$f_tmp" 2>/dev/null)" | sed '/^$/d')
  fi
  if [[ -z "$f_ldap_groups" ]]
  then
    g_echo_note "No LDAP groups defined, skipping group deletion"
  else
    while IFS= read -r f_group
    do
      if [[ -z "$f_group" ]]
      then
        continue
      fi
      # Group names are plain identifiers; be defensive before passing on.
      if [[ ! "$f_group" =~ ^[a-zA-Z0-9._-]+$ ]]
      then
        g_echo_warn "Skipping invalid LDAP group name: $f_group"
        continue
      fi
      # Deletes the group even if it still has members.
      g_echo_note "Deleting LDAP group: $f_group"
      if ! "$g_script_dir/symbios-ldap-groups.sh" --delete --name "$f_group"
      then
        # Group may already be gone or LDAP unreachable - never fatal.
        g_echo_warn "LDAP group deletion failed (continuing): $f_group"
      fi
    done <<< "$f_ldap_groups"
  fi
fi

# Remove Authelia managed blocks (by marker suffix) from the Authelia
# configuration. Works on a backup copy, validates the YAML result before
# accepting it and restarts Authelia when something was removed.
function f_remove_authelia_blocks {
  local f_conf="${g_base_services_root}/authelia/authelia-data/configuration.yml"
  local f_backup="${f_conf}.pre-uninstall"
  local f_snap f_suffix f_changed=0
  if [[ ! -f "$f_conf" ]]
  then
    g_echo_note "Authelia configuration not found (${f_conf}), skipping block removal"
    return 0
  fi
  cp -p "$f_conf" "${f_backup}"
  f_snap=$(mktemp)
  cp -p "$f_conf" "$f_snap"
  while IFS= read -r f_suffix
  do
    if [[ -z "$f_suffix" ]]
    then
      continue
    fi
    # Marker suffixes are plain names like "OIDC nextcloud"; be defensive.
    local f_re='^[a-zA-Z0-9][a-zA-Z0-9 ._+-]*$'
    if [[ ! "$f_suffix" =~ ${f_re} ]]
    then
      g_echo_warn "Skipping suspicious Authelia block name: $f_suffix"
      continue
    fi
    awk -v b="^# BEGIN ANSIBLE MANAGED BLOCK ${f_suffix}[[:space:]]*\$" \
        -v e="^# END ANSIBLE MANAGED BLOCK ${f_suffix}[[:space:]]*\$" '
      $0 ~ b {inskip=1; next}
      $0 ~ e {inskip=0; next}
      !inskip {print}
    ' "$f_conf" > "${f_conf}.tmp.$$" \
      && chmod --reference="$f_conf" "${f_conf}.tmp.$$" \
      && mv "${f_conf}.tmp.$$" "$f_conf"
  done <<< "$f_authelia_blocks"
  if ! cmp -s "$f_conf" "$f_snap"
  then
    # Only accept the change when the result is still valid YAML.
    if python3 -c "import yaml; yaml.safe_load(open('${f_conf}'))" 2>/dev/null
    then
      f_changed=1
      g_echo_note "Removed Authelia configuration blocks (backup: ${f_backup})"
    else
      g_echo_error "Authelia configuration invalid after block removal - restoring backup"
      cp -p "${f_backup}" "$f_conf"
      rm -f "$f_snap"
      return 1
    fi
  else
    g_echo_note "No Authelia configuration changes made"
  fi
  rm -f "$f_snap"
  if [[ "$f_changed" -eq 1 ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^symbios-base-authelia$'
  then
    g_echo_note "Restarting Authelia to apply the configuration changes"
    if (cd "${g_base_services_root}/authelia" && docker compose restart authelia >/dev/null 2>&1) \
       || docker restart symbios-base-authelia >/dev/null 2>&1
    then
      g_echo_note "Authelia restarted"
    else
      g_echo_warn "Could not restart Authelia automatically"
    fi
  fi
  return 0
}

# --- Step 4: Remove Authelia managed blocks (full mode only) ---
if [[ "$f_mode" == "full" ]]
then
  f_authelia_blocks=$(yq eval '.docs.uninstall.authelia_blocks[]' "$f_tmp" 2>/dev/null)
  if [[ -z "$f_authelia_blocks" ]]
  then
    g_echo_note "No Authelia blocks defined, skipping block removal"
  else
    if ! f_remove_authelia_blocks
    then
      # Configuration could not be modified safely - abort the uninstall
      # before anything else gets deleted.
      g_echo_error "Aborting uninstall (Authelia configuration could not be updated safely)"
      exit 1
    fi
  fi
fi

# --- Step 5: Resolve the service dir ---
# Explicit docs key wins, otherwise playbooks below services/ map to
# $g_services_root/<name>/. It must stay below the services root for safety:
# the service dir is deleted wholesale in full/reset mode.
f_service_dir=$(yq eval '.docs.uninstall.service_dir // ""' "$f_tmp" 2>/dev/null)
if [[ -n "$f_service_dir" ]]
then
  f_service_dir=$(f_expand_vars "$f_service_dir")
elif [[ "$f_playbook" == services/* ]]
then
  f_service_dir="${g_services_root}/$(basename "$f_playbook" .yml)"
fi
f_service_dir="${f_service_dir%/}"
if [[ -n "$f_service_dir" && "$f_service_dir" != "${g_services_root}/"* ]]
then
  g_echo_error "Refusing unsafe service_dir outside ${g_services_root}: $f_service_dir"
  rm -f "$f_tmp"
  exit 1
fi

# Check whether a path is the service dir itself or lives below it.
function f_in_service_dir {
  local f_path="${1%/}"
  if [[ -z "$f_service_dir" ]]
  then
    return 1
  fi
  [[ "$f_path" == "$f_service_dir" || "$f_path" == "$f_service_dir"/* ]]
}

# Safety check: refuse to delete critical system paths
function f_path_is_critical {
  case "$1" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Delete a single path recursively after safety checks.
function f_delete_path {
  local f_path="$1"
  local f_label="$2"
  if f_path_is_critical "$f_path"
  then
    g_echo_error "Refusing to delete critical system path: $f_path"
    exit 1
  fi
  if [[ -e "$f_path" ]]
  then
    g_echo_note "Deleting ${f_label}: $f_path"
    rm -rf "$f_path"
  else
    g_echo_note "Path not found (skipping): $f_path"
  fi
}

# Delete a list of paths from the docs block (recursive).
# In "program" mode paths at/below the service dir are skipped so that the
# whole service dir (compose file + all data) survives.
function f_delete_paths {
  local f_key="$1"
  local f_label="$2"
  local f_paths f_path f_expanded
  f_paths=$(yq eval ".docs.uninstall.${f_key}[]" "$f_tmp" 2>/dev/null)
  if [[ -z "$f_paths" ]]
  then
    g_echo_note "No ${f_label} paths defined, skipping"
    return
  fi
  while IFS= read -r f_path
  do
    if [[ -z "$f_path" ]]
    then
      continue
    fi
    f_expanded=$(f_expand_vars "$f_path")
    if [[ "$f_mode" == "program" ]] && f_in_service_dir "$f_expanded"
    then
      g_echo_note "Keeping ${f_label} (service dir stays intact): $f_expanded"
      continue
    fi
    f_delete_path "$f_expanded" "$f_label"
  done <<< "$f_paths"
}

# --- Step 6: Delete paths ---
case "$f_mode" in
  full)
    g_echo_note "Mode: full - removing program paths, userdata and the service dir"
    f_delete_paths "program_paths" "program"
    f_delete_paths "userdata_paths" "userdata"
    if [[ -n "$f_service_dir" ]]
    then
      f_delete_path "$f_service_dir" "service dir"
    fi
    ;;
  program)
    g_echo_note "Mode: program - removing program paths, keeping the service dir with all data"
    f_delete_paths "program_paths" "program"
    ;;
  reset)
    g_echo_note "Mode: reset - wiping service data for fresh reprovisioning"
    f_delete_paths "userdata_paths" "userdata"
    if [[ -n "$f_service_dir" ]]
    then
      f_delete_path "$f_service_dir" "service dir"
    fi
    ;;
esac

# --- Step 7: State handling / reprovisioning ---
if [[ "$f_mode" == "reset" ]]
then
  # The service stays installed: re-run the playbook so compose files,
  # configuration and containers come back freshly provisioned.
  g_echo_note "Re-provisioning $f_playbook via playbook run"
  if "$g_script_dir/symbios-run-playbook.sh" "$f_playbook"
  then
    "$g_script_dir/symbios-state.sh" set "$f_playbook"
    g_echo_note "Reset of $f_playbook completed successfully"
  else
    g_echo_error "Playbook run failed during reset - service may be incomplete"
    exit 1
  fi
else
  g_echo_note "Removing $f_playbook from installed-playbooks state"
  "$g_script_dir/symbios-state.sh" unset "$f_playbook"
  g_echo_note "Uninstall of $f_playbook completed (mode: $f_mode)"
fi

# Cleanup
rm -f "$f_tmp"
