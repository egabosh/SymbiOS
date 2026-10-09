#!/bin/bash
# SymbiOS - Manage backup target settings (server, encryption, excludes).
#
# Settings CLI-first architecture: the WebUI page /settings/backup/ (main
# form) is a thin wrapper around this script, which owns validation and
# the inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction).
#
# Only the target configuration lives here. Snapshot listing, passphrase
# handling, restore planning/execution and manual runs stay with their
# dedicated scripts (symbios-backup-list.sh, symbios-backup.sh,
# symbios-restore.sh, backup.sh) and the thin WebUI endpoints calling them.
#
# Secrets note: the backup encryption passphrase is NOT an inventory var -
# it lives in the config dir, generated and shown via
# "symbios-backup.sh gen-passphrase|get-passphrase", so it never appears
# in argv, JSON answers or audit logs. This script therefore needs no
# --json-stdin.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS backup target settings (backup server, encryption flag,
rsync exclude patterns).

Commands:
  get [--json]                    Print current values (key=value lines;
                                  backup_exclude one pattern per line;
                                  or a JSON object with --json)
  set [--host H --port P --user U --path P --encryption true|false
       --exclude-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  Options left out keep their current value;
                                  an empty --port/--user falls back to 22 /
                                  root (same as the WebUI). --exclude-stdin
                                  reads rsync patterns from stdin (empty
                                  lines and # comments skipped).
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (backup-changed / backup-unchanged).

Examples:
  $(basename "$0") get
  $(basename "$0") set --host backup.example.com --user root --path /backups/symbios --encryption true
  printf '%s\n' '*.tmp' 'cache/' | $(basename "$0") set --exclude-stdin

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (bad port, bad boolean, ...)
  1  technical error (inventory unreadable, ...)
EOF
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

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "backup_server_host", "type": "text", "label": "Backup server host",
   "required": false, "default": "", "secret": false,
   "placeholder": "backup.example.com"},
  {"name": "backup_server_port", "type": "number", "label": "SSH port",
   "required": false, "default": "22", "secret": false},
  {"name": "backup_server_user", "type": "text", "label": "SSH user",
   "required": false, "default": "root", "secret": false},
  {"name": "backup_server_path", "type": "text", "label": "Target path",
   "required": false, "default": "", "secret": false,
   "placeholder": "/backups/symbios"},
  {"name": "backup_encryption", "type": "bool", "label": "Encrypt backups",
   "required": true, "default": false, "secret": false},
  {"name": "backup_exclude", "type": "multiline", "label": "Exclude patterns",
   "required": false, "default": [], "secret": false,
   "note": "One rsync pattern per line, # comments allowed"}
]
EOF
  exit 0
fi

f_cur_host="$(f_symbios_var backup_server_host "")"
f_cur_port="$(f_symbios_var backup_server_port "22")"
f_cur_user="$(f_symbios_var backup_server_user "root")"
f_cur_path="$(f_symbios_var backup_server_path "")"
f_cur_enc="$(f_symbios_var backup_encryption "")"
if [[ "${f_cur_enc}" == "True" || "${f_cur_enc}" == "true" ]]
then
  f_cur_enc="true"
else
  f_cur_enc="false"
fi
# The exclude list is a YAML list - the grep-based f_symbios_var cannot
# read it, so use the inventory CLI (JSON) instead.
f_cur_excludes_json="$("$g_symbios_dir/symbios-inventory.py" \
  --inventory "${g_inventory}" get --json backup_exclude 2>/dev/null)" || f_cur_excludes_json="[]"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"backup_server_host": %s, "backup_server_port": %s, "backup_server_user": %s, "backup_server_path": %s, "backup_encryption": %s, "backup_exclude": %s}\n' \
      "$(printf '%s' "${f_cur_host}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_port}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_user}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_path}" | f_json_escape)" \
      "${f_cur_enc}" \
      "${f_cur_excludes_json}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  echo "backup_server_host=${f_cur_host}"
  echo "backup_server_port=${f_cur_port}"
  echo "backup_server_user=${f_cur_user}"
  echo "backup_server_path=${f_cur_path}"
  echo "backup_encryption=${f_cur_enc}"
  echo "backup_exclude=${f_cur_excludes_json}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_host=""
f_new_port=""
f_new_user=""
f_new_path=""
f_new_enc=""
f_given_host="no"
f_given_port="no"
f_given_user="no"
f_given_path="no"
f_given_enc="no"
f_given_excludes="no"
f_excludes_json="[]"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_host="$2"
      f_given_host="yes"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_port="$2"
      f_given_port="yes"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_user="$2"
      f_given_user="yes"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_path="$2"
      f_given_path="yes"
      shift 2
      ;;
    --encryption)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_enc="$2"
      f_given_enc="yes"
      shift 2
      ;;
    --exclude-stdin)
      f_given_excludes="yes"
      f_stdin_patterns=()
      while IFS= read -r f_line || [[ -n "${f_line}" ]]
      do
        f_trimmed="${f_line#"${f_line%%[![:space:]]*}"}"
        f_trimmed="${f_trimmed%"${f_trimmed##*[![:space:]]}"}"
        [[ -z "${f_trimmed}" || "${f_trimmed}" == \#* ]] && continue
        f_stdin_patterns+=("${f_trimmed}")
      done
      f_excludes_json="["
      f_first="yes"
      for f_pat in ${f_stdin_patterns[@]+"${f_stdin_patterns[@]}"}
      do
        [[ "${f_first}" == "yes" ]] || f_excludes_json="${f_excludes_json}, "
        f_first="no"
        f_excludes_json="${f_excludes_json}$(printf '%s' "${f_pat}" | f_json_escape)"
      done
      f_excludes_json="${f_excludes_json}]"
      shift
      ;;
    --check)
      f_check="yes"
      shift
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      f_ss_fail_usage
      ;;
  esac
done

if [[ "${f_given_host}" == "no" && "${f_given_port}" == "no" \
   && "${f_given_user}" == "no" && "${f_given_path}" == "no" \
   && "${f_given_enc}" == "no" && "${f_given_excludes}" == "no" ]]
then
  f_ss_fail_validation "Nothing to set - pass at least one field option"
fi

# Options left out keep their current value. An explicitly empty port/user
# falls back to the WebUI defaults (22 / root).
[[ "${f_given_host}" == "no" ]] && f_new_host="${f_cur_host}"
[[ "${f_given_port}" == "no" ]] && f_new_port="${f_cur_port}"
[[ "${f_given_user}" == "no" ]] && f_new_user="${f_cur_user}"
[[ "${f_given_path}" == "no" ]] && f_new_path="${f_cur_path}"
[[ "${f_given_enc}" == "no" ]] && f_new_enc="${f_cur_enc}"
[[ -z "${f_new_port}" ]] && f_new_port="22"
[[ -z "${f_new_user}" ]] && f_new_user="root"

# --- validation ---------------------------------------------------------------

if [[ -n "${f_new_host}" ]] \
  && { [[ "${f_new_host}" == *$'\n'* ]] || [[ "${f_new_host}" =~ [[:space:]] ]]; }
then
  f_ss_fail_validation "Invalid --host: must be a single line without whitespace"
fi
if ! [[ "${f_new_port}" =~ ^[0-9]+$ ]] \
  || [[ "10#${f_new_port}" -lt 1 || "10#${f_new_port}" -gt 65535 ]]
then
  f_ss_fail_validation "Invalid --port: ${f_new_port} (expected 1-65535)"
fi
if [[ "${f_new_user}" == *$'\n'* ]] || [[ "${f_new_user}" =~ [[:space:]] ]]
then
  f_ss_fail_validation "Invalid --user: must be a single line without whitespace"
fi
if [[ -n "${f_new_path}" && "${f_new_path}" == *$'\n'* ]]
then
  f_ss_fail_validation "Invalid --path: must be a single line"
fi
case "${f_new_enc,,}" in
  true|1|yes|on)
    f_new_enc="true"
    ;;
  false|0|no|off)
    f_new_enc="false"
    ;;
  *)
    f_ss_fail_validation "Invalid --encryption value: ${f_new_enc} (expected true|false)"
    ;;
esac

# --- transactional write -------------------------------------------------------

f_merge="$(printf '{"backup_server_host": %s, "backup_server_port": %s, "backup_server_user": %s, "backup_server_path": %s, "backup_encryption": %s' \
  "$(printf '%s' "${f_new_host}" | f_json_escape)" \
  "$(printf '%s' "${f_new_port}" | f_json_escape)" \
  "$(printf '%s' "${f_new_user}" | f_json_escape)" \
  "$(printf '%s' "${f_new_path}" | f_json_escape)" \
  "${f_new_enc}")"
if [[ "${f_given_excludes}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_exclude\": ${f_excludes_json}}"
else
  f_merge="${f_merge}}"
fi

f_ss_merge "${f_merge}" "backup" "${f_check}"
exit 0
