#!/bin/bash
# symbios-lib.sh — Central configuration loader for SymbiOS bash scripts.
#
# Resolves the filesystem layout and key configuration values from
# inventory.yml (or /etc/symbios/symbios.conf if present) and exports them
# as g_* globals. All SymbiOS scripts should source this library instead of
# hardcoding paths, so a single source of truth exists.
#
# Sourcing:
#   source /etc/bash/gaboshlib.include   # optional, for g_echo* helpers
#   source symbios-lib.sh                # via PATH (scripts/ is in PATH)
#
# Exported globals:
#   g_data_root          /symbios
#   g_git_root           $g_data_root/git/SymbiOS
#   g_base_services_root $g_data_root/base-services
#   g_services_root      $g_data_root/services
#   g_docker_root        $g_data_root/docker
#   g_containerd_root    $g_data_root/containerd
#   g_backup_root        $g_data_root/backups
#   g_config_dir         dir of inventory.yml (host: .../symbios-ui/config,
#                        container CONFIG_PATH=/config/inventory.yml: /config)
#   g_log_dir            $dirname(g_config_dir)/log
#   g_inventory          $g_config_dir/inventory.yml
#   g_state_file         $g_config_dir/installed-playbooks.yml
#   g_base_domain        base_domain from inventory
#   g_ldap_basedn        ldap_basedn from inventory
#
# Functions:
#   f_symbios_var <key> <default>   read a scalar from inventory.yml
#   f_json_escape                   escape a string (stdin) for JSON
#   f_json_error <msg>              print {"ok":false,"error":"<msg>"}
#   f_json_get <json> <key>         extract a string value from JSON
#   f_check_cache <name>            skip a check that ran within 5 min
#   f_symbios_ldap_init             set f_ldap_uri/f_base_dn/f_admin_pw/f_bind_dn
#   f_ldap_exec / f_ldap_ldif       run LDAP in the webui container
#   f_symbios_traefik_hosts         write Traefik Host labels to $g_tmp/hosts
#
# CONFIG_PATH may be set (e.g. /config/inventory.yml inside the WebUI
# container) to point at the inventory file.
#
# NOTE: This library must NOT be sourced from scripts that run before the
# data partition is mounted (symbios-boot-unlock/*, symbios-data-partition.sh).
# Those scripts hardcode their paths by design.

# Base paths are deterministic; inventory.yml may override the root.
g_data_root="/symbios"

# Allow the WebUI container to inject its own inventory path.
if [[ -n "${CONFIG_PATH:-}" ]]
then
  g_inventory="${CONFIG_PATH}"
else
  g_inventory="${g_data_root}/base-services/symbios-ui/config/inventory.yml"
fi

# Read a scalar value from inventory.yml.
# Usage: f_symbios_var <key> <default>
# The key is looked up as '<key>:' (any indentation, but not inside a
# comment) in the inventory file. Values must be simple scalars (strings);
# nested structures are not supported.
function f_symbios_var {
  local f_key="$1"
  local f_default="${2:-}"
  local f_line f_value

  if [[ ! -r "${g_inventory}" ]]
  then
    echo "${f_default}"
    return 0
  fi

  # Find the key line (anchor: line starts with whitespace, not with '#')
  f_line=$(grep -E "^[[:space:]]*${f_key}:[[:space:]]" "${g_inventory}" \
    | head -1)
  if [[ -z "${f_line}" ]]
  then
    echo "${f_default}"
    return 0
  fi

  # Trim whitespace, strip quotes, trim again (handles ' "v" ' and '"v"').
  f_value="${f_line#*:}"
  f_value="${f_value#"${f_value%%[![:space:]]*}"}"
  f_value="${f_value%"${f_value##*[![:space:]]}"}"
  f_value="${f_value#\"}"
  f_value="${f_value%\"}"
  f_value="${f_value#\'}"
  f_value="${f_value%\'}"
  f_value="${f_value#"${f_value%%[![:space:]]*}"}"
  f_value="${f_value%"${f_value##*[![:space:]]}"}"

  [[ -n "${f_value}" ]] && echo "${f_value}" || echo "${f_default}"
}

# Load the full layout into g_* globals.
function f_symbios_load_layout {
  g_data_root=$(f_symbios_var data_root "/symbios")
  g_git_root=$(f_symbios_var git_root "${g_data_root}/git/SymbiOS")
  g_base_services_root=$(f_symbios_var base_services_root "${g_data_root}/base-services")
  g_services_root=$(f_symbios_var services_root "${g_data_root}/services")
  g_docker_root=$(f_symbios_var docker_root "${g_data_root}/docker")
  g_containerd_root=$(f_symbios_var containerd_root "${g_data_root}/containerd")
  g_backup_root=$(f_symbios_var backup_root "${g_data_root}/backups")
  g_base_domain=$(f_symbios_var base_domain "")
  g_ldap_basedn=$(f_symbios_var ldap_basedn "dc=openldap,dc=local")

  # Derive config/log dirs from the inventory location. On the host this
  # yields <base_services_root>/symbios-ui/{config,log}; inside the WebUI
  # container (CONFIG_PATH=/config/inventory.yml) it yields /config and /log.
  g_config_dir="$(dirname "${g_inventory}")"
  g_log_dir="${g_config_dir%/*}/log"
  g_state_file="${g_config_dir}/installed-playbooks.yml"
}

# Escape a string for safe embedding in JSON (prints the quoted value).
# Reads from stdin so it can be used in a pipe.
function f_json_escape {
  local f_s
  IFS= read -r f_s
  f_s="${f_s//\\/\\\\}"
  f_s="${f_s//\"/\\\"}"
  f_s="${f_s//$'\t'/\\t}"
  f_s="${f_s//$'\n'/\\n}"
  f_s="${f_s//$'\r'/\\r}"
  printf '"%s"' "$f_s"
}

# Print {"ok":false,"error":"<message>"} and exit 1.
function f_json_error {
  local f_msg="$1"
  printf '{"ok":false,"error":%s}\n' "$(echo "$f_msg" | f_json_escape)"
  exit 1
}

# Extract a string value for <key> from a JSON document.
function f_json_get {
  local f_json="$1" f_key="$2"
  local f_tmp="${f_json#*\"${f_key}\":\"}"
  [[ "$f_tmp" == "$f_json" ]] && { echo ""; return 1; }
  echo "${f_tmp%%\"*}"
}

# Skip a runchecks.d check that ran within the last 5 minutes.
# Usage: f_check_cache <name> || return 2>/dev/null || true
function f_check_cache {
  local f_name="$1"
  local f_cache_file="${g_tmp:-/tmp}/${f_name}"
  if [[ -f "$f_cache_file" ]] && find "$f_cache_file" -mmin -5 | grep -q "$f_cache_file"
  then
    return 1
  fi
  date > "$f_cache_file"
  return 0
}

# Set up LDAP connection details for host-side scripts. Reads the base DN
# from inventory and the admin password from ${g_config_dir}/.ldap_admin_pw.
# Sets f_ldap_uri, f_base_dn, f_admin_pw, f_bind_dn.
function f_symbios_ldap_init {
  f_ldap_uri="${LDAP_URI:-ldap://openldap}"
  f_base_dn="$(f_symbios_var ldap_basedn "dc=openldap,dc=local")"
  f_admin_pw="$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null || echo 'changeme')"
  f_bind_dn="cn=head-of-ldap,${f_base_dn}"
}

# Run an LDAP command inside the webui container (has network access to openldap)
function f_ldap_exec {
  docker exec symbios-webui "$@"
}

# Run an LDAP command inside the webui container with LDIF on stdin
function f_ldap_ldif {
  docker exec -i symbios-webui "$@"
}

# Collect Traefik Host labels from all service compose files and the traefik
# providers. Writes the raw label lines to ${g_tmp}/hosts.
function f_symbios_traefik_hosts {
  >"$g_tmp/hosts"
  find "${g_base_services_root}" "${g_services_root}" -maxdepth 1 -mindepth 1 -type d | grep -E -v "\.del$|\.bak$|\.old$|var-lib-docker$" | while read f_dir
  do
    # Skip directories marked as down
    if [[ -s "$f_dir/.downok" ]]
    then
      continue
    fi
    # Extract Host labels from docker-compose files
    if grep -q Host "$f_dir/docker-compose.override.yml" >/dev/null 2>&1
    then
      grep Host "$f_dir/docker-compose.override.yml" >>"$g_tmp/hosts"
    elif [[ -f "$f_dir/docker-compose.yml" ]]
    then
      grep Host "$f_dir/docker-compose.yml" >>"$g_tmp/hosts"
    fi
  done
  grep Host "${g_base_services_root}/traefik/providers/"*.yml >>"$g_tmp/hosts" 2>/dev/null
}

# Load layout immediately so sourcing the library is sufficient.
f_symbios_load_layout
