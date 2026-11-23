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
# symbios-secret.sh - Centralized encrypted secret store for SymbiOS.
#
# Values are encrypted with age (X25519 + ChaCha20-Poly1305) and kept in
# <config_dir>/secrets/. The identity lives outside the WebUI container mount
# at <data_root>/.keys/symbios-secret.age.key. Neither values nor the identity
# are ever passed as argv; secrets are read from stdin and written to 0600
# files. Only secret names are audit-logged.
#
# Usage:
#   symbios-secret.sh init
#   symbios-secret.sh put <name>
#   symbios-secret.sh get <name> [--path <file>]
#   symbios-secret.sh show <name> [--actor <user>]
#   symbios-secret.sh list
#   symbios-secret.sh rotate <name> [--plan|--apply|--no-apply]
#   symbios-secret.sh status <name>
#   symbios-secret.sh rollback <name>
#   symbios-secret.sh import-env <file> --prefix <prefix> [--dry-run]
#   symbios-secret.sh export-env <file>
#   symbios-secret.sh cleanup <file>
#   symbios-secret.sh -h | --help
#
# Exit codes: 0 ok, 1 technical error, 2 usage error.

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
if ! declare -F g_echo_note >/dev/null 2>&1
then
  function g_echo_note { printf '%s\n' "$*"; }
  function g_echo_error { printf '%s\n' "$*" >&2; }
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Centralized encrypted secret store for SymbiOS (age, X25519/ChaCha20-Poly1305).

Commands:
  init                       Create the identity and the secrets directory.
  put <name> [--file <path>] Store a value read from stdin or a 0600 file
                             (trailing newlines are stripped). Existing values
                             are replaced.
  get <name> [--path <file>] Decrypt into a 0600 file and print its path.
                             Without --path a transient file is created. The
                             caller SHREDs it after use (see cleanup).
  show <name> [--actor <user>]
                              Print the current value once on stdout for an
                              explicit WebUI reveal. Never use in jobs or logs.
                              With --actor the audit records who revealed which
                              secret; without it only the name is recorded.
  list                       List stored secret names (never values).
  rotate <name> [--plan|--apply|--no-apply]
                             Generate a new 64-hex-character value. Without a
                             flag (or with --no-apply) only the store changes;
                             --apply also runs the matching propagation hook
                             and keeps one previous ciphertext for rollback.
                             --plan prints the intended actions only.
  status <name>              Show rotation metadata (never the value).
  rollback <name>            Restore the previous ciphertext if present.
  delete <name>              Shred a stored value (audit-logged by name).
  import-env <file> --prefix <prefix> [--dry-run]
                             Store every KEY=value of an env file as
                             <prefix>/<KEY> and replace the file with a
                             generated one. --dry-run only reports the keys.
  export-env <file>          Regenerate an env file from the store using the
                             prefix recorded in its generated header.
  cleanup <file>             Shred a transient file below \${g_config_dir}.
  -h, --help                 Show this help.

Secret names: letters, digits, dot, underscore and hyphen, optionally grouped
with slashes (for example openwrt-vm/OPENWRT_ROOT_PASSWORD).

Examples:
  echo 's3cr3t' | symbios-secret.sh put ddns_apikey
  f_file=\$(symbios-secret.sh get ddns_apikey)
  symbios-secret.sh cleanup "\${f_file}"
  symbios-secret.sh import-env /symbios/services/openwrt-vm/env --prefix openwrt-vm

Output:
  get/rotate print one file path on stdout; all other commands print status
  text. show is the only command that prints a value, and only for the explicit
  WebUI reveal. Value bytes never appear in argv, job output, logs or audit.

Exit codes:
  0 success, 1 technical error, 2 usage error.
EOF
}

# Scratch files (plaintext input, temporary ciphertext) must not survive a
# failed command. Output files of get/rotate are untracked and stay for callers.
declare -ag g_scratch_files=()

function f_cleanup_scratch {
  local f_file
  for f_file in "${g_scratch_files[@]:-}"
  do
    [[ -f "${f_file}" ]] && { shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"; }
  done
  g_scratch_files=()
}

function f_scratch_register {
  local f_path="$1" f_line f_body
  g_scratch_files+=("${f_path}")
  f_line=$(trap -p EXIT 2>/dev/null || true)
  [[ "${f_line}" == *f_cleanup_scratch* ]] && return 0
  if [[ -z "${f_line}" ]]
  then
    trap 'f_cleanup_scratch' EXIT
    return 0
  fi
  f_body="${f_line#*\'}"
  f_body="${f_body%\'*}"
  if [[ "${f_body}" == "${f_line}" ]]
  then
    f_body="${f_line#trap -- }"
    f_body="${f_body% EXIT}"
    f_body="${f_body#\"}"
    f_body="${f_body%\"}"
  fi
  trap -- "${f_body}; f_cleanup_scratch" EXIT
}

function f_scratch_untrack {
  local f_target="$1" f_file f_keep=()
  for f_file in "${g_scratch_files[@]:-}"
  do
    [[ "${f_file}" == "${f_target}" ]] || f_keep+=("${f_file}")
  done
  g_scratch_files=("${f_keep[@]:-}")
}

function f_fail {
  g_echo_error "$*"
  exit 1
}

function f_usage_error {
  g_echo_error "$*"
  f_usage >&2
  exit 2
}

# All store locations derive from symbios-lib.sh globals, never hardcoded.
function f_store_paths {
  g_secret_key="${g_data_root}/.keys/symbios-secret.age.key"
  g_secret_pub="${g_data_root}/.keys/symbios-secret.age.pub"
  g_secret_dir="${g_config_dir}/secrets"
}

function f_require_tools {
  command -v age >/dev/null 2>&1 || f_fail "age is not installed"
  command -v age-keygen >/dev/null 2>&1 || f_fail "age-keygen is not installed"
  command -v flock >/dev/null 2>&1 || f_fail "flock is not installed"
  command -v openssl >/dev/null 2>&1 || f_fail "openssl is not installed"
  [[ -n "${g_config_dir:-}" && -d "${g_config_dir}" ]] || f_fail "config directory not available: ${g_config_dir:-unset}"
}

function f_validate_name {
  local f_name="${1:-}"
  [[ "${f_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] \
    || f_usage_error "invalid secret name: ${f_name}"
}

function f_secret_file {
  printf '%s/%s.age' "${g_secret_dir}" "$1"
}

function f_require_initialized {
  [[ -f "${g_secret_key}" && -f "${g_secret_pub}" ]] \
    || f_fail "secret store is not initialized - run 'symbios-secret.sh init'"
}

# Encrypt a value file into the store. The value never travels as argv.
function f_store_put {
  local f_action="$1" f_name="$2" f_value_file="$3"
  local f_target f_tmp
  f_validate_name "${f_name}"
  f_target="$(f_secret_file "${f_name}")"
  mkdir -p "$(dirname "${f_target}")" || f_fail "cannot create secret group directory"
  chmod 0700 "$(dirname "${f_target}")" || f_fail "cannot chmod secret group directory"
  f_tmp=$(mktemp "${g_secret_dir}/.put-XXXXXX") || f_fail "cannot create temp file"
  f_scratch_register "${f_tmp}"
  chmod 0600 "${f_tmp}" || f_fail "cannot chmod temp file"
  age -e -R "${g_secret_pub}" -o "${f_tmp}" "${f_value_file}" 2>/dev/null \
    || f_fail "encryption failed for ${f_name}"
  mv -f "${f_tmp}" "${f_target}" || f_fail "cannot store ${f_name}"
  f_scratch_untrack "${f_tmp}"
  chmod 0600 "${f_target}" || f_fail "cannot chmod ${f_name}"
  f_audit_event secret "${f_action}" "${f_name}"
}

# Decrypt a value from the store into a caller-provided 0600 file.
function f_store_get {
  local f_name="$1" f_out="$2" f_action="${3:-get}" f_detail="${4:-}" f_source
  f_validate_name "${f_name}"
  f_source="$(f_secret_file "${f_name}")"
  [[ -f "${f_source}" ]] || f_fail "secret not found: ${f_name}"
  chmod 0600 "${f_out}" || f_fail "cannot chmod output file"
  age -d -i "${g_secret_key}" -o "${f_out}" "${f_source}" 2>/dev/null \
    || f_fail "decryption failed for ${f_name}"
  if [[ -n "${f_detail}" ]]
  then
    f_audit_event secret "${f_action}" "${f_detail}"
  else
    f_audit_event secret "${f_action}" "${f_name}"
  fi
}

# Write a shell value to a transient 0600 file without exposing it in argv.
function f_value_to_file {
  local f_value="$1" f_path
  # Do not register cleanup here: callers invoke this in $(...), where an EXIT
  # trap would shred the file before the path reaches them.
  f_path=$(mktemp "${g_config_dir}/.value-XXXXXX") || f_fail "cannot create temp file"
  chmod 0600 "${f_path}" || f_fail "cannot chmod temp file"
  printf '%s' "${f_value}" > "${f_path}" || f_fail "cannot write temp file"
  printf '%s' "${f_path}"
}

function f_cmd_init {
  local f_tmp
  mkdir -p "${g_secret_dir}" || f_fail "cannot create ${g_secret_dir}"
  chmod 0700 "${g_secret_dir}" || f_fail "cannot chmod ${g_secret_dir}"
  mkdir -p "$(dirname "${g_secret_key}")" || f_fail "cannot create key directory"
  chmod 0700 "$(dirname "${g_secret_key}")" || f_fail "cannot chmod key directory"
  if [[ ! -f "${g_secret_key}" ]]
  then
    age-keygen -o "${g_secret_key}" >/dev/null 2>&1 || f_fail "cannot generate identity"
  fi
  chmod 0600 "${g_secret_key}" || f_fail "cannot chmod identity"
  f_tmp=$(mktemp "${g_secret_dir}/.pub-XXXXXX") || f_fail "cannot create temp file"
  f_scratch_register "${f_tmp}"
  age-keygen -y "${g_secret_key}" > "${f_tmp}" 2>/dev/null || f_fail "cannot derive recipient"
  mv -f "${f_tmp}" "${g_secret_pub}" || f_fail "cannot store recipient"
  f_scratch_untrack "${f_tmp}"
  chmod 0644 "${g_secret_pub}" || f_fail "cannot chmod recipient"
  f_audit_event secret init "store"
  g_echo_note "secret store initialized: ${g_secret_dir}"
}

function f_cmd_put {
  local f_name="${1:-}" f_source="" f_value_file
  shift || true
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --file)
        f_source="${2:-}"
        [[ -n "${f_source}" && -f "${f_source}" ]] || f_usage_error "--file needs an existing file"
        shift 2
        ;;
      *) f_usage_error "unknown put option: $1" ;;
    esac
  done
  [[ -n "${f_name}" ]] || f_usage_error "put needs a secret name"
  f_validate_name "${f_name}"
  f_require_initialized
  if [[ -n "${f_source}" ]]
  then
    # A caller that already holds the value in a 0600 file (Ansible, a
    # migration helper) can hand it over by path - still no value in argv.
    f_value_file=$(mktemp "${g_config_dir}/.input-XXXXXX") || f_fail "cannot create temp file"
    f_scratch_register "${f_value_file}"
    chmod 0600 "${f_value_file}" || f_fail "cannot chmod temp file"
    f_value=$(<"${f_source}")
    printf '%s' "${f_value}" > "${f_value_file}" || f_fail "cannot write temp file"
  else
    f_value_file=$(mktemp "${g_config_dir}/.input-XXXXXX") || f_fail "cannot create temp file"
    f_scratch_register "${f_value_file}"
    chmod 0600 "${f_value_file}" || f_fail "cannot chmod temp file"
    f_value=$(cat)
    printf '%s' "${f_value}" > "${f_value_file}" || f_fail "cannot write temp file"
  fi
  f_store_put put "${f_name}" "${f_value_file}"
  shred -u "${f_value_file}" 2>/dev/null || rm -f "${f_value_file}"
  f_scratch_untrack "${f_value_file}"
  g_echo_note "stored: ${f_name}"
}

function f_cmd_get {
  local f_name="${1:-}" f_path="" f_tmp
  shift || true
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --path)
        f_path="${2:-}"
        [[ -n "${f_path}" ]] || f_usage_error "--path needs a file"
        shift 2
        ;;
      *) f_usage_error "unknown get option: $1" ;;
    esac
  done
  [[ -n "${f_name}" ]] || f_usage_error "get needs a secret name"
  f_require_initialized
  if [[ -z "${f_path}" ]]
  then
    f_path=$(mktemp "${g_config_dir}/.secret-get-XXXXXX") || f_fail "cannot create temp file"
  fi
  f_scratch_register "${f_path}"
  : > "${f_path}" || f_fail "cannot write ${f_path}"
  f_store_get "${f_name}" "${f_path}"
  f_scratch_untrack "${f_path}"
  printf '%s\n' "${f_path}"
}

# One-shot value output for the explicit WebUI reveal. The caller must not
# create a job from this command: stdout is the secret itself. The transient
# 0600 file is shredded by the global scratch trap when this process exits.
function f_cmd_show {
  local f_name="${1:-}" f_actor="" f_action="show" f_detail="" f_file
  shift || true
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --actor)
        f_actor="${2:-}"
        [[ -n "${f_actor}" ]] || f_usage_error "--actor needs a user"
        shift 2
        ;;
      *) f_usage_error "unknown show option: $1" ;;
    esac
  done
  [[ -n "${f_name}" ]] || f_usage_error "show needs a secret name"
  f_require_initialized
  f_file=$(mktemp "${g_config_dir}/.secret-show-XXXXXX") || f_fail "cannot create temp file"
  f_scratch_register "${f_file}"
  chmod 0600 "${f_file}" || f_fail "cannot chmod temp file"
  if [[ -n "${f_actor}" ]]
  then
    # The actor is audit data, never a credential. Sanitize it so a malformed
    # username cannot inject extra fields or newlines into the audit line.
    f_actor="${f_actor//[^A-Za-z0-9._@-]/_}"
    f_actor="${f_actor:0:128}"
    f_action="reveal"
    f_detail="secret=${f_name} actor=${f_actor}"
  fi
  f_store_get "${f_name}" "${f_file}" "${f_action}" "${f_detail}"
  cat "${f_file}"
}

function f_cmd_delete {
  local f_name="${1:-}" f_target f_meta
  [[ -n "${f_name}" ]] || f_usage_error "delete needs a secret name"
  f_target="$(f_secret_file "${f_name}")"
  [[ -f "${f_target}" ]] || f_fail "secret not found: ${f_name}"
  f_meta="$(f_meta_file "${f_name}")"
  shred -u "${f_target}" 2>/dev/null || rm -f "${f_target}"
  # A rollback copy would survive as an unlisted old credential after delete.
  if [[ -f "${f_target}.prev" ]]
  then
    shred -u "${f_target}.prev" 2>/dev/null || rm -f "${f_target}.prev"
  fi
  [[ ! -f "${f_meta}" ]] || rm -f "${f_meta}"
  f_audit_event secret delete "${f_name}"
  g_echo_note "deleted: ${f_name}"
}

function f_cmd_list {
  [[ -d "${g_secret_dir}" ]] || f_fail "secret store is not initialized"
  find "${g_secret_dir}" -type f -name '*.age' -printf '%P\n' \
    | sed 's/\.age$//' | sort
  f_audit_event secret list "store"
}

# Rotation metadata is intentionally a flat key=value file per secret: it
# holds no values, needs no extra parser, and can be written atomically.
function f_meta_file {
  local f_name="$1" f_safe
  f_safe="${f_name//\//__}"
  printf '%s\n' "${g_secret_dir}/meta/${f_safe}.meta"
}

function f_meta_get {
  local f_name="$1" f_key="$2" f_file f_line
  f_file="$(f_meta_file "${f_name}")"
  [[ -f "${f_file}" ]] || return 0
  f_line="$(grep -F "${f_key}=" "${f_file}" | head -1)"
  printf '%s' "${f_line#*=}"
}

function f_meta_set {
  local f_name="$1" f_key="$2" f_value="$3" f_file f_tmp
  f_file="$(f_meta_file "${f_name}")"
  mkdir -p "$(dirname "${f_file}")" || f_fail "cannot create secret metadata dir"
  chmod 0700 "$(dirname "${f_file}")" || true
  f_tmp=$(mktemp "${g_secret_dir}/.meta-XXXXXX") || f_fail "cannot create secret metadata temp file"
  f_scratch_register "${f_tmp}"
  if [[ -f "${f_file}" ]]
  then
    grep -v -F "${f_key}=" "${f_file}" > "${f_tmp}" || true
  fi
  printf '%s=%s\n' "${f_key}" "${f_value}" >> "${f_tmp}" || f_fail "cannot write secret metadata"
  chmod 0600 "${f_tmp}" || true
  mv -f "${f_tmp}" "${f_file}" || f_fail "cannot replace secret metadata"
  f_scratch_untrack "${f_tmp}"
}

# A hook receives <name> <new-value-file> <old-value-file>, both 0600 and
# transient. It must exit non-zero if propagation failed so the store can be
# rolled back. Hook names mirror the secret name with slashes replaced.
function f_hook_path {
  local f_name="$1" f_safe
  f_safe="${f_name//\//__}"
  printf '%s\n' "${g_script_dir}/secret-rotation.d/${f_safe}.sh"
}

function f_rotation_lock {
  exec 9>"${g_secret_dir}/.rotation.lock" || f_fail "cannot open rotation lock"
  flock -w 30 9 || f_fail "another secret rotation is running"
}

function f_cmd_status {
  local f_name="${1:-}" f_file f_hook f_type f_policy
  [[ -n "${f_name}" ]] || f_usage_error "status needs a secret name"
  f_validate_name "${f_name}"
  f_require_initialized
  f_file="$(f_secret_file "${f_name}")"
  [[ -f "${f_file}" ]] || f_fail "secret not found: ${f_name}"
  f_hook="$(f_hook_path "${f_name}")"
  f_type="$(f_meta_get "${f_name}" type)"
  [[ -n "${f_type}" ]] || f_type="generated"
  f_policy="$(f_meta_get "${f_name}" policy)"
  [[ -n "${f_policy}" ]] || f_policy="manual"
  printf 'name=%s\n' "${f_name}"
  printf 'type=%s\n' "${f_type}"
  printf 'policy=%s\n' "${f_policy}"
  printf 'consumers=%s\n' "$(f_meta_get "${f_name}" consumers)"
  printf 'last_rotated=%s\n' "$(f_meta_get "${f_name}" last_rotated)"
  if [[ -x "${f_hook}" ]]
  then
    printf 'hook=%s\n' "${f_hook}"
  else
    printf 'hook=none\n'
  fi
  if [[ -f "${f_file}.prev" ]]
  then
    printf 'previous-ciphertext=%s\n' "${f_file}.prev"
  else
    printf 'previous-ciphertext=none\n'
  fi
}

function f_cmd_rotate {
  local f_name="${1:-}" f_mode="plain" f_value f_value_file f_out f_old_file
  local f_hook f_source f_prev f_type f_policy f_consumers
  shift || true
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --plan) f_mode="plan" ;;
      --apply) f_mode="apply" ;;
      --no-apply) f_mode="no-apply" ;;
      *) f_usage_error "unknown rotate option: $1" ;;
    esac
    shift
  done
  [[ -n "${f_name}" ]] || f_usage_error "rotate needs a secret name"
  f_validate_name "${f_name}"
  f_require_initialized

  f_source="$(f_secret_file "${f_name}")"
  [[ -f "${f_source}" ]] || f_fail "secret not found: ${f_name}"
  f_prev="${f_source}.prev"
  f_hook="$(f_hook_path "${f_name}")"
  f_type="$(f_meta_get "${f_name}" type)"
  [[ -n "${f_type}" ]] || f_type="generated"
  f_policy="$(f_meta_get "${f_name}" policy)"
  [[ -n "${f_policy}" ]] || f_policy="manual"
  f_consumers="$(f_meta_get "${f_name}" consumers)"

  if [[ "${f_mode}" == "plan" ]]
  then
    printf 'rotate %s\n' "${f_name}"
    printf 'type=%s policy=%s\n' "${f_type}" "${f_policy}"
    printf 'consumers=%s\n' "${f_consumers:-none}"
    if [[ -x "${f_hook}" ]]
    then
      printf 'hook=%s\n' "${f_hook}"
    else
      printf 'hook=none\n'
    fi
    if [[ -f "${f_prev}" ]]
    then
      printf 'previous-ciphertext=%s\n' "${f_prev}"
    else
      printf 'previous-ciphertext=none\n'
    fi
    return 0
  fi

  # An application-owned credential has to be changed in the application
  # first; use `put` afterwards. Rotating it here would only desynchronise.
  [[ "${f_type}" == "generated" ]] \
    || f_fail "secret ${f_name} is app-owned; change it in the application and use put"

  f_rotation_lock
  f_old_file=$(mktemp "${g_config_dir}/.secret-old-XXXXXX") || f_fail "cannot create rotation temp file"
  f_scratch_register "${f_old_file}"
  f_store_get "${f_name}" "${f_old_file}"
  f_value=$(openssl rand -hex 32) || f_fail "cannot generate a new value"
  f_value_file=$(f_value_to_file "${f_value}")
  f_scratch_register "${f_value_file}"

  if [[ "${f_mode}" == "apply" ]]
  then
    cp -a "${f_source}" "${f_prev}" || f_fail "cannot create rollback copy"
    chmod 0600 "${f_prev}" || true
  fi

  f_store_put rotate "${f_name}" "${f_value_file}"

  if [[ "${f_mode}" == "apply" && -x "${f_hook}" ]]
  then
    if ! "${f_hook}" "${f_name}" "${f_value_file}" "${f_old_file}"
    then
      mv -f "${f_prev}" "${f_source}" || f_fail "hook failed and rollback could not be restored"
      f_fail "propagation hook failed for ${f_name}; store rolled back"
    fi
  fi

  f_meta_set "${f_name}" type "${f_type}"
  f_meta_set "${f_name}" policy "$([[ "${f_mode}" == "apply" ]] && printf event || printf manual)"
  f_meta_set "${f_name}" last_rotated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -z "${f_consumers}" ]] || f_meta_set "${f_name}" consumers "${f_consumers}"

  if [[ "${f_mode}" == "apply" ]]
  then
    if [[ -x "${f_hook}" ]]
    then
      g_echo_note "rotated ${f_name}, propagated by ${f_hook}"
    else
      g_echo_note "rotated ${f_name} (no propagation hook)"
    fi
    return 0
  fi

  f_out=$(mktemp "${g_config_dir}/.secret-rotated-XXXXXX") || f_fail "cannot create temp file"
  f_scratch_register "${f_out}"
  printf '%s' "${f_value}" > "${f_out}" || f_fail "cannot write temp file"
  chmod 0600 "${f_out}" || f_fail "cannot chmod temp file"
  f_scratch_untrack "${f_out}"
  printf '%s\n' "${f_out}"
}

function f_cmd_rollback {
  local f_name="${1:-}" f_source f_prev
  [[ -n "${f_name}" ]] || f_usage_error "rollback needs a secret name"
  f_validate_name "${f_name}"
  f_require_initialized
  f_source="$(f_secret_file "${f_name}")"
  f_prev="${f_source}.prev"
  [[ -f "${f_prev}" ]] || f_fail "no previous ciphertext for ${f_name}"
  f_rotation_lock
  mv -f "${f_prev}" "${f_source}" || f_fail "cannot restore previous ciphertext"
  chmod 0600 "${f_source}" || true
  f_meta_set "${f_name}" rolled_back "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  f_audit_event secret rollback "${f_name}"
  g_echo_note "rolled back ${f_name}; reapply consumers to propagate"
}

function f_cmd_import_env {
  local f_file="${1:-}" f_prefix="" f_dry=0 f_value_file f_name f_key f_value
  shift || true
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --prefix)
        f_prefix="${2:-}"
        [[ -n "${f_prefix}" ]] || f_usage_error "--prefix needs a value"
        shift 2
        ;;
      --dry-run) f_dry=1; shift ;;
      *) f_usage_error "unknown import-env option: $1" ;;
    esac
  done
  [[ -n "${f_file}" && -f "${f_file}" ]] || f_usage_error "import-env needs an existing file"
  [[ -n "${f_prefix}" ]] || f_usage_error "import-env needs --prefix"
  f_validate_name "${f_prefix}"
  f_require_initialized

  # Validate the whole file first: an unsupported line must not leave a
  # partially imported prefix behind.
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    [[ -z "${f_line}" || "${f_line}" == \#* ]] && continue
    [[ "${f_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
      || f_fail "unsupported line in ${f_file}: ${f_line:0:40}"
  done < "${f_file}"

  # Store every value before touching the original file.
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    [[ -z "${f_line}" || "${f_line}" == \#* ]] && continue
    [[ "${f_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    f_key="${f_line%%=*}"
    f_value="${f_line#*=}"
    f_name="${f_prefix}/${f_key}"
    if [[ "${f_dry}" -eq 0 ]]
    then
      f_value_file=$(f_value_to_file "${f_value}")
      f_scratch_register "${f_value_file}"
      f_store_put put "${f_name}" "${f_value_file}"
      shred -u "${f_value_file}" 2>/dev/null || rm -f "${f_value_file}"
      f_scratch_untrack "${f_value_file}"
    fi
    g_echo_note "${f_name}"
  done < "${f_file}"
  [[ "${f_dry}" -eq 1 ]] && return 0

  # Regenerate from the store; abort before replacing if any key is missing.
  f_cmd_export_env "${f_file}" "${f_prefix}"
  g_echo_note "imported ${f_file} into store (prefix ${f_prefix})"
}

function f_cmd_export_env {
  local f_file="${1:-}" f_prefix="${2:-}" f_line f_key f_name f_value_file
  local f_new f_dir f_mode
  [[ -n "${f_file}" && -f "${f_file}" ]] || f_usage_error "export-env needs an existing file"
  f_require_initialized
  if [[ -z "${f_prefix}" ]]
  then
    f_prefix=$(grep -m1 '^# secret-prefix: ' "${f_file}" 2>/dev/null || true)
    f_prefix="${f_prefix#\# secret-prefix: }"
    [[ -n "${f_prefix}" ]] || f_fail "no secret-prefix header in ${f_file}"
  fi
  f_validate_name "${f_prefix}"

  # Check that every key in the file has a stored value first.
  while IFS= read -r f_line || [[ -n "${f_line}" ]]
  do
    [[ -z "${f_line}" || "${f_line}" == \#* ]] && continue
    [[ "${f_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || f_fail "unsupported line in ${f_file}"
    f_key="${f_line%%=*}"
    [[ -f "$(f_secret_file "${f_prefix}/${f_key}")" ]] \
      || f_fail "missing secret: ${f_prefix}/${f_key}"
  done < "${f_file}"

  f_dir="$(dirname "${f_file}")"
  f_mode=$(stat -c '%a' "${f_file}")
  f_new=$(mktemp "${f_dir}/.env-XXXXXX") || f_fail "cannot create temp file"
  f_scratch_register "${f_new}"
  chmod "${f_mode}" "${f_new}" || f_fail "cannot chmod temp file"
  chown --reference="${f_file}" "${f_new}" 2>/dev/null || true

  {
    echo '# Generated by symbios-secret.sh - do not edit.'
    echo "# secret-prefix: ${f_prefix}"
    while IFS= read -r f_line || [[ -n "${f_line}" ]]
    do
      [[ "${f_line}" == '# Generated by symbios-secret.sh'* ]] && continue
      [[ "${f_line}" == '# secret-prefix: '* ]] && continue
      if [[ "${f_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
      then
        f_key="${f_line%%=*}"
        f_value_file=$(mktemp "${g_config_dir}/.value-XXXXXX") || f_fail "cannot create temp file"
        f_scratch_register "${f_value_file}"
        f_store_get "${f_prefix}/${f_key}" "${f_value_file}"
        printf '%s=%s\n' "${f_key}" "$(<"${f_value_file}")"
        shred -u "${f_value_file}" 2>/dev/null || rm -f "${f_value_file}"
        f_scratch_untrack "${f_value_file}"
      else
        printf '%s\n' "${f_line}"
      fi
    done < "${f_file}"
  } > "${f_new}" || f_fail "cannot write ${f_new}"

  # Idempotency: a repeated export must not rewrite the file, otherwise every
  # playbook run would restart the containers that mount it.
  if cmp -s "${f_new}" "${f_file}"
  then
    shred -u "${f_new}" 2>/dev/null || rm -f "${f_new}"
    f_scratch_untrack "${f_new}"
    return 0
  fi

  # Replace the plaintext file; shredding is best-effort on CoW/SSD storage.
  shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"
  mv "${f_new}" "${f_file}" || f_fail "cannot replace ${f_file} (new file: ${f_new})"
  f_scratch_untrack "${f_new}"
  f_audit_event secret export-env "${f_prefix}"
  g_echo_note "regenerated ${f_file} from store (prefix ${f_prefix})"
}

function f_cmd_cleanup {
  local f_file="${1:-}"
  [[ -n "${f_file}" ]] || f_usage_error "cleanup needs a file"
  [[ "${f_file}" == "${g_config_dir}"/.secret-* || "${f_file}" == "${g_config_dir}"/.value-* || "${f_file}" == "${g_config_dir}"/.input-* ]] \
    || f_usage_error "refusing to shred a file outside the transient secret area"
  [[ -f "${f_file}" ]] || f_fail "not a file: ${f_file}"
  shred -u "${f_file}" 2>/dev/null || rm -f "${f_file}"
}

f_store_paths

case "${1:-}" in
  -h|--help) f_usage; exit 0 ;;
  init)
    f_require_tools
    shift
    [[ $# -eq 0 ]] || f_usage_error "init takes no arguments"
    f_cmd_init
    ;;
  put) f_require_tools; shift; f_cmd_put "$@" ;;
  get) f_require_tools; shift; f_cmd_get "$@" ;;
  show) f_require_tools; shift; [[ $# -ge 1 ]] || f_usage_error "show needs a secret name"; f_cmd_show "$@" ;;
  list) f_require_tools; shift; [[ $# -eq 0 ]] || f_usage_error "list takes no arguments"; f_cmd_list ;;
  rotate) f_require_tools; shift; f_cmd_rotate "$@" ;;
  status) f_require_tools; shift; [[ $# -eq 1 ]] || f_usage_error "status needs exactly one name"; f_cmd_status "$1" ;;
  rollback) f_require_tools; shift; [[ $# -eq 1 ]] || f_usage_error "rollback needs exactly one name"; f_cmd_rollback "$1" ;;
  delete) shift; f_cmd_delete "$@" ;;
  import-env) f_require_tools; shift; f_cmd_import_env "$@" ;;
  export-env) f_require_tools; shift; f_cmd_export_env "$@" ;;
  cleanup) shift; f_cmd_cleanup "$@" ;;
  *) f_usage_error "unknown command: ${1:-<none>}" ;;
esac
