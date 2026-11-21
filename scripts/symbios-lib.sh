#!/bin/bash
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
#
# symbios-lib.sh - Central configuration loader for SymbiOS bash scripts.
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
#   g_media_root         media base dir (inventory media_root)
#   g_media_audio        audio library (inventory media_audio)
#   g_media_images       photo library (inventory media_images)
#   g_media_videos       video library (inventory media_videos)
#   g_media_books        e-book library (inventory media_books)
#   g_media_documents    document library (inventory media_documents)
#   g_media_inbox        ingest dir (inventory media_inbox)
#   g_media_shared       group shares base (inventory media_shared)
#   g_media_gid          shared media filesystem gid (inventory media_gid)
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
#   f_symbios_var_set <key> <value> set a scalar under all.vars (host only)
#   f_symbios_var_json <key>        read a dict/list as compact JSON ({} if unset)
#   f_symbios_ssh_key_usable <key>  check a key is usable unattended (reason on failure)
#   f_json_escape                   escape a string (stdin) for JSON
#   f_json_error <msg>              print {"ok":false,"error":"<msg>"}
#   f_json_get <json> <key>         extract a string value from JSON
#   f_audit_event <src> <act> [det] append a best-effort audit event
#   f_check_cache <name>            skip a check that ran within 5 min
#   f_symbios_ldap_init             set f_ldap_uri/f_base_dn/f_admin_pw/f_bind_dn
#   f_ldap_exec / f_ldap_ldif       run LDAP in the webui container
#   f_secret_get_to_file <name>     read <name> from the central secret store
#                                   into a transient 0600 file (path in
#                                   g_secret_file_path, shredded on exit)
#   f_symbios_traefik_hosts         write Traefik Host labels to $g_tmp/hosts
#
#   f_media_quota <projid> <dir> <limit_gib>  apply an ext4 project
#                                                  quota (best-effort)
#
# CONFIG_PATH may be set (e.g. /config/inventory.yml inside the WebUI
# container) to point at the inventory file.
#
# NOTE: This library must NOT be sourced from scripts that run before the
# data partition is mounted (symbios-boot-unlock/*, symbios-data-partition.sh).
# Those scripts hardcode their paths by design.

# ---------------------------------------------------------------------------
# Direct invocation (not sourced): this is a library, so running it directly
# only makes sense to read its documentation. All SymbiOS scripts source this
# file; the guard (BASH_SOURCE == $0) prevents the usage block from triggering
# when a caller script is itself invoked with --help.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
  then
    cat << EOF
$(basename "$0") - Central configuration loader for SymbiOS bash scripts.

This is a library and must be sourced, not executed:
  source /etc/bash/gaboshlib.include   # optional, for g_echo* helpers
  source symbios-lib.sh                # via PATH (scripts/ is in PATH)

Resolves the filesystem layout and key configuration values from
inventory.yml (or /etc/symbios/symbios.conf if present) and exports them as
g_* globals. Provides helper functions:

  f_symbios_var <key> <default>    read a scalar from inventory.yml
  f_symbios_var_set <key> <value>  set a scalar under all.vars (host only)
  f_symbios_var_json <key>         read a dict/list as compact JSON ({} if unset)
  f_external_target <target_id>    resolve an external system from
                                   external-systems.yml (g_ext_host/_port/
                                   _user/_type)
  f_symbios_ssh_key_usable <key>  check a key is usable unattended (reason on failure)
  f_json_escape                    escape a string (stdin) for JSON
  f_json_error <msg>               print {"ok":false,"error":"<msg>"}
  f_json_get <json> <key>          extract a string value from JSON
  f_no_args "$@"                   reject stray arguments (usage + exit 2)
  f_audit_event <src> <act> [det]  append a best-effort audit event
  f_check_cache <name>             skip a check that ran within 5 min
  f_symbios_ldap_init              set f_ldap_uri/f_base_dn/f_admin_pw/f_bind_dn
  f_ldap_exec / f_ldap_ldif        run LDAP in the webui container
  f_symbios_traefik_hosts          write Traefik Host labels to \$g_tmp/hosts
  f_ldap_groups_hooks              run LDAP group-change hooks

Exported globals: g_data_root, g_git_root, g_base_services_root,
g_services_root, g_docker_root, g_containerd_root, g_backup_root,
g_media_root, g_media_audio, g_media_images, g_media_videos,
g_media_books, g_media_documents, g_media_inbox, g_media_shared, g_media_gid,
g_config_dir, g_log_dir, g_inventory, g_state_file, g_base_domain,
g_ldap_basedn.

Options:
  -h, --help  Show this help and exit
EOF
    exit 0
  fi
  echo "$(basename "$0") is a library and cannot be run directly - source it instead." >&2
  exit 1
fi

# Base paths are deterministic; inventory.yml may override the root.
g_data_root="/symbios"

# Allow the WebUI container to inject its own inventory path.
if [[ -n "${CONFIG_PATH:-}" ]]
then
  g_inventory="${CONFIG_PATH}"
else
  g_inventory="${g_data_root}/base-services/symbios-ui/config/inventory.yml"
fi

# Resolve one external system entry from external-systems.yml.
# Usage: f_external_target <target_id>
# Sets g_ext_host, g_ext_port, g_ext_user, g_ext_type (empty on failure).
# Returns 1 when the file is unreadable or the id is unknown.
function f_external_target {
  local f_id="${1:-}"
  local f_file="${g_config_dir}/external-systems.yml"
  local f_line

  g_ext_host=""
  g_ext_port="22"
  g_ext_user="root"
  g_ext_type=""

  [[ -n "${f_id}" && -r "${f_file}" ]] || return 1
  command -v yq > /dev/null || return 1

  # yq is the established YAML reader; the id comes from the WebUI (word
  # characters and hyphens only), so it is safe to inline.
  f_line=$(yq -r ".external_systems[] | select(.id == \"${f_id}\") | [.host, (.port // 22), (.user // \"root\"), (.type // \"\")] | @tsv" "${f_file}" 2> /dev/null | head -1)
  [[ -n "${f_line}" ]] || return 1
  IFS=$'\t' read -r g_ext_host g_ext_port g_ext_user g_ext_type <<< "${f_line}"

  [[ -n "${g_ext_host}" ]]
}

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
  # Escape regex metacharacters in the key to prevent injection
  local f_escaped_key
  f_escaped_key=$(printf '%s' "${f_key}" | sed 's/[.[\*^$()+?{|]/\\&/g')
  f_line=$(grep -E "^[[:space:]]*${f_escaped_key}:[[:space:]]" "${g_inventory}" \
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

# Read a structured value (dict/list) from inventory.yml as compact JSON.
# Delegates to symbios-inventory.py, so flow and block YAML behave the same.
# Missing/unreadable keys become {} so health checks stay silent.
function f_symbios_var_json {
  local f_key="$1" f_dir f_json
  f_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  f_json="$("${f_dir}/symbios-inventory.py" --inventory "${g_inventory}" \
    get --json "${f_key}" 2>/dev/null)"
  if [[ -z "${f_json}" ]]
  then
    printf '{}\n'
  else
    printf '%s\n' "${f_json}"
  fi
}

# Set a scalar under all.vars in inventory.yml (host side).
# Usage: f_symbios_var_set <key> <value>
# The write is atomic (tmp file + rename) so concurrent readers always see
# a valid file. Delegates to symbios-inventory.py, the single host-side
# writer - no inline YAML parsing here.
function f_symbios_var_set {
  local f_key="$1" f_value="$2"
  local f_dir
  f_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  "${f_dir}/symbios-inventory.py" --inventory "${g_inventory}" set "${f_key}" "${f_value}"
}

# Check that a private key can be used unattended by OpenSSH: it must exist, be
# readable and carry no passphrase. On failure the reason is printed and the
# function returns 1, so the caller can wrap it in its own error format.
#
# Shared by the backup pre-flight (symbios-backup-lib.sh) and the WebUI
# "Test connection" button, so both judge the same key the same way - a script
# that silently fell back to the ssh-agent would report a healthy connection
# for an identity the backup never uses.
function f_symbios_ssh_key_usable {
  local f_key="$1"

  if [[ ! -f "$f_key" ]]
  then
    echo "does not exist"
    return 1
  fi

  if [[ ! -r "$f_key" ]]
  then
    echo "is not readable by $(id -un)"
    return 1
  fi

  if ! ssh-keygen -y -P '' -f "$f_key" >/dev/null 2>&1
  then
    echo "is passphrase-protected and cannot be used unattended"
    return 1
  fi

  return 0
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
  # Audit trail lives on the encrypted data partition, never in /var/log.
  g_audit_log="${SYMBIOS_AUDIT_LOG:-$(f_symbios_var audit_log "${g_data_root}/log/symbios-audit.log")}"
  export SYMBIOS_AUDIT_LOG="${g_audit_log}"
  g_media_root=$(f_symbios_var media_root "${g_data_root}/media")
  g_media_audio=$(f_symbios_var media_audio "${g_media_root}/audio")
  g_media_images=$(f_symbios_var media_images "${g_media_root}/images")
  g_media_videos=$(f_symbios_var media_videos "${g_media_root}/videos")
  g_media_books=$(f_symbios_var media_books "${g_media_root}/books")
  g_media_documents=$(f_symbios_var media_documents "${g_media_root}/documents")
  g_media_inbox=$(f_symbios_var media_inbox "${g_media_root}/inbox")
  g_media_shared=$(f_symbios_var media_shared "${g_media_root}/shared")
  g_media_gid=$(f_symbios_var media_gid "31000")
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
  local f_s f_c
  IFS= read -d '' -r f_s
  f_s="${f_s//\\/\\\\}"
  f_s="${f_s//\"/\\\"}"
  f_s="${f_s//$'\t'/\\t}"
  f_s="${f_s//$'\n'/\\n}"
  f_s="${f_s//$'\r'/\\r}"
  # Escape the remaining C0 control characters (e.g. the ANSI ESC from
  # gaboshlib's colored output) as \uXXXX. A raw control byte inside a JSON
  # string is invalid and makes json.loads() in the WebUI reject the whole
  # document (jobs then looked like "Host stopped answering").
  for f_c in 01 02 03 04 05 06 07 08 0b 0c 0e 0f 10 11 12 13 14 15 16 17 \
             18 19 1a 1b 1c 1d 1e 1f
  do
    f_s="${f_s//$(printf "\\x${f_c}")/\\u00${f_c}}"
  done
  printf '"%s"' "$f_s"
}

# Print {"ok":false,"error":"<message>"} and exit 1.
function f_json_error {
  local f_msg="$1"
  printf '{"ok":false,"error":%s}\n' "$(echo "$f_msg" | f_json_escape)"
  exit 1
}

# Reject stray arguments in scripts that take none: a typo like "status"
# must never fall through into the script's default action. Prints the
# calling script's f_usage (when defined) to stderr and exits 2.
# Usage: f_no_args "$@"
function f_no_args {
  if [[ $# -gt 0 ]]
  then
    printf 'Unknown argument: %s (this script takes no arguments)\n' "$1" >&2
    if declare -F f_usage >/dev/null
    then
      f_usage >&2
    fi
    exit 2
  fi
}

# Extract a string value for <key> from a JSON document.
# Handles both compact ("key":"value") and pretty-printed
# ("key": "value") JSON as produced by json.dumps().
function f_json_get {
  local f_json="$1" f_key="$2"
  local f_tmp="${f_json#*\"${f_key}\":}"
  [[ "$f_tmp" == "$f_json" ]] && { echo ""; return 1; }
  f_tmp="${f_tmp## }"
  if [[ "${f_tmp:0:1}" != '"' ]]; then
    echo ""
    return 1
  fi
  f_tmp="${f_tmp:1}"
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

# Determine whether a reboot is currently required. Sets g_reboot_reason to a
# human-readable explanation and returns 0 when a reboot is pending.
#
# /run/reboot-required is the Debian apt marker. Debian trixie no longer
# installs update-notifier-common, so the marker can be absent after a kernel
# update; the running-vs-installed kernel comparison below keeps the result
# reliable. Both reboot-required.check and reboot-threshold.update use this
# detector so reporting and the opt-in policy cannot disagree.
function f_reboot_needed {
  local f_reason="" f_pkgs="" f_release f_flavour f_version
  local f_pkg f_cand f_cand_version f_pkg_count=0 f_running_installed=0 f_newer=""

  g_reboot_reason=""

  # Debian marker written by apt postinst scripts (may be missing on trixie).
  if [[ -f /run/reboot-required ]]
  then
    if [[ -s /run/reboot-required.pkgs ]]
    then
      f_pkgs="$(sort -u /run/reboot-required.pkgs | tr '\n' ' ')"
      f_pkgs="${f_pkgs% }"
    fi
    f_reason="Reboot required${f_pkgs:+: pending update of ${f_pkgs}}"
  fi

  # Split uname -r into version and flavour, e.g. "6.1.0-13-amd64" ->
  # 6.1.0-13 + "-amd64", "6.18.50+rpt-rpi-2712" -> 6.18.50 + "+rpt-rpi-2712".
  # The flavour filter matters on Pi hosts with two installed kernel flavours.
  f_release="$(uname -r)"
  if [[ "${f_release}" == *"+"* ]]
  then
    f_flavour="+${f_release#*+}"
  elif [[ "${f_release}" == *"-"* ]]
  then
    f_flavour="-${f_release##*-}"
  else
    f_flavour=""
  fi
  f_version="${f_release%"${f_flavour}"}"

  # dpkg compares Debian versions correctly (6.1.0-14 > 6.1.0-13). Process
  # substitution keeps the loop in the current shell so the counters survive.
  while read -r f_pkg
  do
    f_pkg_count=$((f_pkg_count + 1))
    f_cand="${f_pkg#linux-image-}"
    [[ "${f_cand}" == "${f_release}" ]] && f_running_installed=1
    [[ -n "${f_flavour}" && "${f_cand}" != *"${f_flavour}"* ]] && continue

    f_cand_version="${f_cand%"${f_flavour}"}"
    if dpkg --compare-versions "${f_cand_version}" gt "${f_version}" 2>/dev/null
    then
      f_newer="${f_newer} ${f_cand}"
    fi
  done < <(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$NF == "installed" {print $1}')

  # Only judge when the host actually has versioned kernel image packages.
  if [[ "${f_pkg_count}" -gt 0 ]]
  then
    if [[ -n "${f_newer}" ]]
    then
      [[ -z "${f_reason}" ]] || f_reason="${f_reason}; "
      f_reason="${f_reason}Kernel update pending: installed${f_newer}, running ${f_release}"
    elif [[ "${f_running_installed}" -eq 0 ]]
    then
      [[ -z "${f_reason}" ]] || f_reason="${f_reason}; "
      f_reason="${f_reason}Kernel update pending: running kernel ${f_release} is no longer installed"
    fi
  fi

  g_reboot_reason="${f_reason}"
  [[ -n "${f_reason}" ]] && return 0
  return 1
}

# Transient secret files shared by the credential-handling helpers. Every
# path written here is shredded on exit (see f_secret_cleanup_register).
declare -ag g_secret_files=()

# Shred all transient secret files registered during this process.
function f_cleanup_secret_files {
  local f_file
  for f_file in "${g_secret_files[@]:-}"
  do
    if [[ -n "${f_file}" && -f "${f_file}" ]]
    then
      shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"
    fi
  done
  g_secret_files=()
}

# Append secret cleanup to an existing EXIT trap instead of replacing it.
function f_secret_cleanup_register {
  local f_line f_body
  f_line=$(trap -p EXIT 2>/dev/null || true)
  [[ "${f_line}" == *f_cleanup_secret_files* ]] && return 0
  if [[ -z "${f_line}" ]]
  then
    trap 'f_cleanup_secret_files' EXIT
    return 0
  fi
  # Extract the body of the existing trap (single or double quoted).
  f_body="${f_line#*\'}"
  f_body="${f_body%\'*}"
  if [[ "${f_body}" == "${f_line}" ]]
  then
    f_body="${f_line#trap -- }"
    f_body="${f_body% EXIT}"
    f_body="${f_body#\"}"
    f_body="${f_body%\"}"
  fi
  trap -- "${f_body}; f_cleanup_secret_files" EXIT
}

# Write a secret to a transient 0600 file and set g_secret_file_path to its
# path. The value is read from stdin so it never appears in argv. Call this
# function directly, NOT inside $(...): f_secret_cleanup_register modifies the
# EXIT trap, and a command-substitution subshell would fire that trap on exit
# and shred the file before the caller can use it.
function f_write_secret_file {
  local f_type="${1:-secret}"
  local f_path
  g_secret_file_path=""
  [[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || return 1
  f_path=$(mktemp "${g_config_dir}/.secret-${f_type}-XXXXXX") || return 1
  chmod 0600 "${f_path}" || return 1
  # ldapsearch -y (and similar clients) reject a password file with a trailing
  # newline; command substitution strips trailing newlines from the value.
  local f_value
  f_value=$(cat) || return 1
  printf '%s' "${f_value}" > "${f_path}" || return 1
  g_secret_files+=("${f_path}")
  f_secret_cleanup_register
  g_secret_file_path="${f_path}"
}

# Read a secret from the central store into a transient 0600 file. The path is
# returned in g_secret_file_path and shredded when the CALLING process exits.
# Call directly (not in $(...)): f_secret_cleanup_register changes the trap.
function f_secret_get_to_file {
  local f_name="${1:-}" f_path f_lib_dir
  g_secret_file_path=""
  [[ -n "${f_name}" ]] || return 2
  [[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || return 1
  f_path=$(mktemp "${g_config_dir}/.secret-store-XXXXXX") || return 1
  chmod 0600 "${f_path}" || return 1
  f_lib_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  if ! "${f_lib_dir}/symbios-secret.sh" get "${f_name}" --path "${f_path}" >/dev/null 2>&1
  then
    shred -u "${f_path}" 2>/dev/null || rm -f "${f_path}"
    return 1
  fi
  g_secret_files+=("${f_path}")
  f_secret_cleanup_register
  g_secret_file_path="${f_path}"
}

# Read a secret by name for use in command substitution. The central store is
# authoritative; a legacy plaintext inventory value is a migration fallback
# (a `secret:` reference is never returned as a credential). Prints the value
# to stdout - callers capture it, it is never logged or passed as argv.
function f_secret_var {
  local f_name="${1:-}" f_fallback="${2:-}" f_val
  [[ -n "${f_name}" ]] || return 2
  if f_secret_get_to_file "${f_name}"
  then
    cat "${g_secret_file_path}"
    return 0
  fi
  f_val="$(f_symbios_var "${f_name}" "${f_fallback}")"
  [[ "${f_val}" == secret:* ]] && f_val=""
  printf '%s' "${f_val}"
}

# Write a curl config containing an Authorization: Bearer header to a
# transient 0600 file. The path is returned via g_curl_cfg_path and shredded
# on exit, so the token never appears in curl's argv or the process list.
# Call directly (not in $(...)); f_secret_cleanup_register changes the trap.
function f_bearer_curl_config {
  local f_token="${1:-}"
  g_curl_cfg_path=""
  [[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || return 1
  g_curl_cfg_path=$(mktemp "${g_config_dir}/.curl-bearer-XXXXXX") || return 1
  chmod 0600 "${g_curl_cfg_path}" || return 1
  printf 'header = "Authorization: Bearer %s"\n' "${f_token}" > "${g_curl_cfg_path}" || return 1
  g_secret_files+=("${g_curl_cfg_path}")
  f_secret_cleanup_register
}

# Set up LDAP connection details for host-side scripts. Reads the base DN
# from inventory and the admin password from the central secret store, with a
# fallback to ${g_config_dir}/.ldap_admin_pw during migration. Sets f_ldap_uri,
# f_base_dn, f_admin_pw, f_bind_dn and f_ldap_pw_file (path to a transient 0600
# file for `ldap* -y`, so the bind secret stays out of argv).
function f_symbios_ldap_init {
  # LDAP publishes 127.0.0.1:389 on the host, so host ldap-utils can be used
  # directly. All f_ldap_exec/f_ldap_ldif callers pass -H "${f_ldap_uri}".
  f_ldap_uri="${LDAP_URI:-ldap://127.0.0.1:389}"
  f_base_dn="$(f_symbios_var ldap_basedn "dc=openldap,dc=local")"
  f_bind_dn="cn=head-of-ldap,${f_base_dn}"
  # Prefer the encrypted store; the plaintext file is a migration fallback
  # for hosts where ldap.yml has not seeded the store yet.
  if f_secret_get_to_file ldap_admin_password
  then
    f_ldap_pw_file="${g_secret_file_path}"
    f_admin_pw="$(<"${f_ldap_pw_file}")"
  else
    f_admin_pw="$(cat "${g_config_dir}/.ldap_admin_pw" 2>/dev/null || echo 'changeme')"
    f_write_secret_file ldap <<< "${f_admin_pw}" || f_ldap_pw_file=""
    f_ldap_pw_file="${g_secret_file_path}"
  fi
}

# Run an LDAP command on the host (ldap-utils installed by ldap.yml). Using
# 127.0.0.1 avoids a docker exec wrapper and lets the password stay in a file.
function f_ldap_exec {
  "$@"
}

# Run an LDAP command with LDIF on stdin. Kept as a separate function so all
# callers work unchanged; stdin is passed straight through to the client.
function f_ldap_ldif {
  "$@"
}

# Collect Traefik Host labels from all service compose files and the traefik
# providers. Writes the raw label lines to ${g_tmp}/hosts. Match the complete
# Host(`...`) rule: a plain "grep Host" also catches comments, which would
# become bogus hostnames in the checker and /etc/hosts.
function f_symbios_traefik_hosts {
  local f_host_rule='Host\(`[^`]+`\)'
  >"$g_tmp/hosts"
  find "${g_base_services_root}" "${g_services_root}" -maxdepth 1 -mindepth 1 -type d | grep -E -v "\.del$|\.bak$|\.old$|var-lib-docker$" | while read f_dir
  do
    # Skip directories marked as down
    if [[ -s "$f_dir/.downok" ]]
    then
      continue
    fi
    # Extract Host rules from docker-compose files
    if grep -qE "$f_host_rule" "$f_dir/docker-compose.override.yml" >/dev/null 2>&1
    then
      grep -E "$f_host_rule" "$f_dir/docker-compose.override.yml" >>"$g_tmp/hosts"
    elif [[ -f "$f_dir/docker-compose.yml" ]]
    then
      grep -E "$f_host_rule" "$f_dir/docker-compose.yml" >>"$g_tmp/hosts"
    fi
  done
  grep -E "$f_host_rule" "${g_base_services_root}/traefik/providers/"*.yml >>"$g_tmp/hosts" 2>/dev/null
}

# Run all LDAP group-change hooks from ${g_data_root}/ldap-groups.d/.
# Called after every successful group mutation by symbios-ldap-groups.sh
# (CLI and WebUI both go through it) so services can react to membership
# changes (e.g. Nextcloud admin sync). Hooks receive:
#   $1 = event (group-created|group-deleted|member-added|member-removed)
#   $2 = group name
#   $3 = uid (empty for create/delete)
function f_ldap_groups_hooks {
  local f_hook_event="$1"
  local f_hook_group="$2"
  local f_hook_uid="${3:-}"
  local f_hook_dir="${g_data_root}/ldap-groups.d"
  local f_hook_file

  # No hook directory -> nothing to do
  [[ -d "${f_hook_dir}" ]] || return 0

  for f_hook_file in "${f_hook_dir}"/*.hook
  do
    # Skip when the glob did not match anything
    [[ -e "${f_hook_file}" ]] || continue
    g_echo_note "Group-change hook: $(basename "${f_hook_file}") (${f_hook_event} ${f_hook_group} ${f_hook_uid})"
    # Errors are logged but never abort the loop or the caller
    bash "${f_hook_file}" "${f_hook_event}" "${f_hook_group}" "${f_hook_uid}" \
      || g_echo_error "Hook failed: ${f_hook_file}"
  done
}

# Run all LDAP password hooks from ${g_data_root}/ldap-groups.d/.
# Called after every successful password set by symbios-ldap-user.sh
# (create and modify - covers all WebUI password flows and CLI use) so
# services with their own credential store (e.g. S3 htpasswd) can follow.
# Hooks receive:
#   $1 = event (always password-set)
#   $2 = uid
#   $3 = path to a 0600 file holding the plaintext password. The caller
#        shreds it after all hooks ran - never log its content.
# Existing group-change hooks ignore this event via their $1/$2 guards.
function f_ldap_password_hooks {
  local f_hook_uid="$1"
  local f_hook_pwfile="$2"
  local f_hook_dir="${g_data_root}/ldap-groups.d"
  local f_hook_file

  # No hook directory -> nothing to do
  [[ -d "${f_hook_dir}" ]] || return 0

  for f_hook_file in "${f_hook_dir}"/*.hook
  do
    # Skip when the glob did not match anything
    [[ -e "${f_hook_file}" ]] || continue
    g_echo_note "Password hook: $(basename "${f_hook_file}") (password-set ${f_hook_uid})"
    # Errors are logged but never abort the loop or the caller
    bash "${f_hook_file}" "password-set" "${f_hook_uid}" "${f_hook_pwfile}" \
      || g_echo_error "Hook failed: ${f_hook_file}"
  done
}

# Apply an ext4 project quota to a media dir (best-effort).
# Usage: f_media_quota <projid> <dir> <limit_gib>  (0 = unlimited, skip)
# Silent no-op when quota tools are missing or the filesystem is not
# mounted with prjquota (e.g. root filesystems created before quotas).
function f_media_quota {
  local f_projid="$1" f_dir="$2" f_limit="$3"
  local f_kb

  [[ "${f_limit}" -gt 0 ]] 2>/dev/null || return 0
  command -v chattr >/dev/null 2>&1 || return 0
  command -v setquota >/dev/null 2>&1 || return 0
  command -v findmnt >/dev/null 2>&1 || return 0
  findmnt -n -o OPTIONS --target "${f_dir}" 2>/dev/null | tr ',' '\n' | grep -qx prjquota || return 0

  f_kb=$(( f_limit * 1048576 ))
  chattr -p "${f_projid}" "${f_dir}" 2>/dev/null || return 0
  chattr +P "${f_dir}" 2>/dev/null || true
  setquota -P "${f_projid}" "${f_kb}" "${f_kb}" 0 0 "${g_media_root}" 2>/dev/null || true
}

# Ask MAS for a Synapse admin access token of mx-admin (compatibility token).
# Usage: f_matrix_admin_token [service_dir]   (prints the token, empty on error)
# Since Synapse delegates authentication to the Matrix Authentication Service,
# the access_tokens table holds no interactive logins any more; the maintenance
# scripts therefore fetch a short-lived compatibility token right before use.
# The fixed device id keeps MAS from adding a new device on every cron run.
function f_matrix_admin_token {
  local f_dir="${1:-${g_services_root}/matrix}"
  local f_out

  f_out=$(cd "${f_dir}" && docker compose exec -T -e NO_COLOR=1 matrix-auth \
    mas-cli -c /config/mas-config.yaml manage issue-compatibility-token \
    mx-admin symbios-maintenance --yes-i-want-to-grant-synapse-admin-privileges 2>&1)
  # Strip ANSI escapes, then take the token from the "Compatibility token
  # issued: <token> k=v ..." log line (mas-cli prints it via its log formatter
  # and appends the session metadata on the same line)
  f_out=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' <<<"${f_out}")
  sed -n 's/.*Compatibility token issued: \(mct_[A-Za-z0-9_-]*\).*/\1/p' <<<"${f_out}" | tail -n1
}

# Load layout immediately so sourcing the library is sufficient.
f_symbios_load_layout

# Append one audit event to the encrypted data partition. The Python helper
# owns the format; a failed write warns but never aborts the action that
# triggered it. Detail strings must never contain secret values.
function f_audit_event {
  local f_source="$1"
  local f_action="$2"
  local f_detail="${3:-}"
  if ! SYMBIOS_AUDIT_LOG="${g_audit_log}" python3 \
    "${g_git_root}/scripts/symbios_audit.py" event \
    "${f_source}" "${f_action}" "${f_detail}" 2>/dev/null
  then
    g_echo_warn "audit log write failed - continuing: ${g_audit_log}"
  fi
  return 0
}
