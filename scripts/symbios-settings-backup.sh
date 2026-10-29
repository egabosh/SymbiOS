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
       --enabled true|false --exclude-stdin
       --keep-daily N --keep-weekly N --keep-monthly N
       --servers '<json>'] [--check]
                                   Validate and write to inventory.yml.
                                   --enabled switches the nightly backup on
                                   or off (off by default).
                                   Options left out keep their current value;
                                   an empty --port/--user falls back to 22 /
                                   root (same as the WebUI). --exclude-stdin
                                   reads rsync patterns from stdin (empty
                                   lines and # comments skipped).
                                   --keep-* set the restic retention of the
                                   primary target (non-negative integers,
                                   0 = disabled, default 7/4/9999).
                                   --servers replaces the list of additional
                                   backup servers (JSON array of objects with
                                   name,host,port,user,path,keep_daily,
                                   keep_weekly,keep_monthly; host and path
                                   required, everything else optional); '[]'
                                   removes all of them.
                                   --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  apply [--dry-run]               Resolve consuming playbooks (or show them
                                  with --dry-run) and run each in order.
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

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="backup_enabled"

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
  get|set|schema|apply)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "apply" ]]
then
  f_ss_apply_cmd "$@"
  exit $?
fi

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
  {"name": "backup_enabled", "type": "bool", "label": "Nightly backup",
   "required": true, "default": false, "secret": false,
   "note": "The backup job only runs when this is switched on."},
  {"name": "backup_keep_daily", "type": "number", "label": "Keep daily snapshots",
   "required": false, "default": "7", "secret": false},
  {"name": "backup_keep_weekly", "type": "number", "label": "Keep weekly snapshots",
   "required": false, "default": "4", "secret": false},
  {"name": "backup_keep_monthly", "type": "number", "label": "Keep monthly snapshots",
   "required": false, "default": "9999", "secret": false},
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
f_cur_enabled="$(f_symbios_var backup_enabled "false")"
if [[ "${f_cur_enabled}" == "True" || "${f_cur_enabled}" == "true" ]]
then
  f_cur_enabled="true"
else
  f_cur_enabled="false"
fi
# The exclude list and the additional server list are YAML lists - the
# grep-based f_symbios_var cannot read them, so use the inventory CLI (JSON).
f_cur_excludes_json="$("$g_symbios_dir/symbios-inventory.py" \
  --inventory "${g_inventory}" get --json backup_exclude 2>/dev/null)" || f_cur_excludes_json="[]"
f_cur_servers_json="$("$g_symbios_dir/symbios-inventory.py" \
  --inventory "${g_inventory}" get --json backup_servers 2>/dev/null)" || f_cur_servers_json="[]"
f_cur_keep_daily="$(f_symbios_var backup_keep_daily "7")"
f_cur_keep_weekly="$(f_symbios_var backup_keep_weekly "4")"
f_cur_keep_monthly="$(f_symbios_var backup_keep_monthly "9999")"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"backup_server_host": %s, "backup_server_port": %s, "backup_server_user": %s, "backup_server_path": %s, "backup_encryption": %s, "backup_enabled": %s, "backup_exclude": %s, "backup_servers": %s, "backup_keep_daily": %s, "backup_keep_weekly": %s, "backup_keep_monthly": %s}\n' \
      "$(printf '%s' "${f_cur_host}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_port}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_user}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_path}" | f_json_escape)" \
      "${f_cur_enc}" \
      "${f_cur_enabled}" \
      "${f_cur_excludes_json}" \
      "${f_cur_servers_json}" \
      "$(printf '%s' "${f_cur_keep_daily}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_keep_weekly}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_keep_monthly}" | f_json_escape)"
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
  echo "backup_enabled=${f_cur_enabled}"
  echo "backup_keep_daily=${f_cur_keep_daily}"
  echo "backup_keep_weekly=${f_cur_keep_weekly}"
  echo "backup_keep_monthly=${f_cur_keep_monthly}"
  echo "backup_exclude=${f_cur_excludes_json}"
  echo "backup_servers=${f_cur_servers_json}"
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_host=""
f_new_port=""
f_new_user=""
f_new_path=""
f_new_enc=""
f_new_enabled=""
f_new_keep_daily=""
f_new_keep_weekly=""
f_new_keep_monthly=""
f_new_servers=""
f_given_host="no"
f_given_port="no"
f_given_user="no"
f_given_path="no"
f_given_enc="no"
f_given_enabled="no"
f_given_keep_daily="no"
f_given_keep_weekly="no"
f_given_keep_monthly="no"
f_given_servers="no"
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
    --enabled)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_enabled="$2"
      f_given_enabled="yes"
      shift 2
      ;;
    --keep-daily)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_keep_daily="$2"
      f_given_keep_daily="yes"
      shift 2
      ;;
    --keep-weekly)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_keep_weekly="$2"
      f_given_keep_weekly="yes"
      shift 2
      ;;
    --keep-monthly)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_keep_monthly="$2"
      f_given_keep_monthly="yes"
      shift 2
      ;;
    --servers)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_servers="$2"
      f_given_servers="yes"
      shift 2
      ;;
    --json-stdin)
      # Full field object for generic callers (e.g. the schema renderer).
      # backup_exclude arrives as a newline string, split like the
      # --exclude-stdin textarea lines.
      f_json="$(cat)"
      for f_field in backup_server_host backup_server_port backup_server_user backup_server_path backup_encryption backup_enabled backup_exclude
      do
        [[ "${f_json}" == *'"'"${f_field}"'"'* ]] || continue
        if [[ "${f_field}" == "backup_exclude" ]]
        then
          f_excl_text="$(f_json_get "${f_json}" "${f_field}")" || f_excl_text=""
          # JSON escapes newlines as \n - restore real line breaks.
          # (printf %s, never %b: patterns may hold literal backslashes.)
          f_excl_text="${f_excl_text//\\n/$'\n'}"
          f_stdin_patterns=()
          while IFS= read -r f_line || [[ -n "${f_line}" ]]
          do
            f_trimmed="${f_line#"${f_line%%[![:space:]]*}"}"
            f_trimmed="${f_trimmed%"${f_trimmed##*[![:space:]]}"}"
            [[ -z "${f_trimmed}" || "${f_trimmed}" == \#* ]] && continue
            f_stdin_patterns+=("${f_trimmed}")
          done <<< "${f_excl_text}"
          f_excludes_json="["
          f_first="yes"
          for f_pat in ${f_stdin_patterns[@]+"${f_stdin_patterns[@]}"}
          do
            [[ "${f_first}" == "yes" ]] || f_excludes_json="${f_excludes_json}, "
            f_first="no"
            f_excludes_json="${f_excludes_json}$(printf '%s' "${f_pat}" | f_json_escape)"
          done
          f_excludes_json="${f_excludes_json}]"
          f_given_excludes="yes"
          continue
        fi
        f_val="$(f_json_get "${f_json}" "${f_field}")" || f_val=""
        # Booleans arrive unquoted - match generously.
        if [[ "${f_field}" == "backup_encryption" || "${f_field}" == "backup_enabled" ]]
        then
          f_onoff="$(grep -o "\"${f_field}\"[[:space:]]*:[[:space:]]*[^,}]*" <<< "${f_json}" | head -1)"
          f_onoff="${f_onoff##*:}"
          f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
          f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
          f_onoff="${f_onoff%\"}"
          f_onoff="${f_onoff#\"}"
          if [[ "${f_field}" == "backup_enabled" ]]
          then
            f_new_enabled="${f_onoff}"
            f_given_enabled="yes"
          else
            f_new_enc="${f_onoff}"
            f_given_enc="yes"
          fi
          continue
        fi
        case "${f_field}" in
          backup_server_host)
            f_new_host="${f_val}"
            f_given_host="yes"
            ;;
          backup_server_port)
            f_new_port="${f_val}"
            f_given_port="yes"
            ;;
          backup_server_user)
            f_new_user="${f_val}"
            f_given_user="yes"
            ;;
          backup_server_path)
            f_new_path="${f_val}"
            f_given_path="yes"
            ;;
        esac
      done
      shift
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
   && "${f_given_enc}" == "no" && "${f_given_enabled}" == "no" \
   && "${f_given_excludes}" == "no" && "${f_given_keep_daily}" == "no" \
   && "${f_given_keep_weekly}" == "no" && "${f_given_keep_monthly}" == "no" \
   && "${f_given_servers}" == "no" ]]
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
[[ "${f_given_enabled}" == "no" ]] && f_new_enabled="${f_cur_enabled}"
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
case "${f_new_enabled,,}" in
  true|1|yes|on)
    f_new_enabled="true"
    ;;
  false|0|no|off)
    f_new_enabled="false"
    ;;
  *)
    f_ss_fail_validation "Invalid --enabled value: ${f_new_enabled} (expected true|false)"
    ;;
esac

# Retention values: non-negative integers (0 disables that level).
if [[ "${f_given_keep_daily}" == "yes" ]] \
  && { ! [[ "${f_new_keep_daily}" =~ ^[0-9]+$ ]] || [[ "10#${f_new_keep_daily}" -gt 99999 ]]; }
then
  f_ss_fail_validation "Invalid --keep-daily: ${f_new_keep_daily} (expected 0-99999)"
fi
if [[ "${f_given_keep_weekly}" == "yes" ]] \
  && { ! [[ "${f_new_keep_weekly}" =~ ^[0-9]+$ ]] || [[ "10#${f_new_keep_weekly}" -gt 99999 ]]; }
then
  f_ss_fail_validation "Invalid --keep-weekly: ${f_new_keep_weekly} (expected 0-99999)"
fi
if [[ "${f_given_keep_monthly}" == "yes" ]] \
  && { ! [[ "${f_new_keep_monthly}" =~ ^[0-9]+$ ]] || [[ "10#${f_new_keep_monthly}" -gt 99999 ]]; }
then
  f_ss_fail_validation "Invalid --keep-monthly: ${f_new_keep_monthly} (expected 0-99999)"
fi

# Additional servers: validate and normalize the JSON list (python does the
# JSON handling, bash only passes the normalized result into the merge).
if [[ "${f_given_servers}" == "yes" ]]
then
  if ! f_servers_norm="$(printf '%s' "${f_new_servers}" | python3 -c '
import json, sys

def num(value, default):
    if value in (None, ""):
        return str(default)
    try:
        v = int(value)
    except (TypeError, ValueError):
        return str(default)
    return str(v if 0 <= v <= 99999 else default)

try:
    data = json.load(sys.stdin) or []
except Exception:
    sys.exit(2)
if not isinstance(data, list):
    sys.exit(2)
out = []
for srv in data:
    if not isinstance(srv, dict):
        sys.exit(2)
    host = str(srv.get("host") or "").strip()
    path = str(srv.get("path") or "").strip()
    user = str(srv.get("user") or "").strip() or "root"
    name = str(srv.get("name") or "").strip() or host
    if not host or not path:
        sys.exit(2)
    if any(ch.isspace() for ch in (host + user + name)):
        sys.exit(2)
    if not path.startswith("/"):
        path = "/" + path
    out.append({"name": name, "host": host, "port": num(srv.get("port"), 22),
                "user": user, "path": path,
                "keep_daily": int(num(srv.get("keep_daily"), 7)),
                "keep_weekly": int(num(srv.get("keep_weekly"), 4)),
                "keep_monthly": int(num(srv.get("keep_monthly"), 9999))})
print(json.dumps(out))
')"
  then
    f_ss_fail_validation "Invalid --servers JSON (expected an array of objects with host and path)"
  fi
fi

# --- transactional write -------------------------------------------------------

f_merge="$(printf '{"backup_server_host": %s, "backup_server_port": %s, "backup_server_user": %s, "backup_server_path": %s, "backup_encryption": %s, "backup_enabled": %s' \
  "$(printf '%s' "${f_new_host}" | f_json_escape)" \
  "$(printf '%s' "${f_new_port}" | f_json_escape)" \
  "$(printf '%s' "${f_new_user}" | f_json_escape)" \
  "$(printf '%s' "${f_new_path}" | f_json_escape)" \
  "${f_new_enc}" \
  "${f_new_enabled}")"
# Optional fields are only written when given (current value stays otherwise)
if [[ "${f_given_keep_daily}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_keep_daily\": ${f_new_keep_daily}"
fi
if [[ "${f_given_keep_weekly}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_keep_weekly\": ${f_new_keep_weekly}"
fi
if [[ "${f_given_keep_monthly}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_keep_monthly\": ${f_new_keep_monthly}"
fi
if [[ "${f_given_servers}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_servers\": ${f_servers_norm}"
fi
if [[ "${f_given_excludes}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_exclude\": ${f_excludes_json}}"
else
  f_merge="${f_merge}}"
fi

f_ss_merge "${f_merge}" "backup" "${f_check}"
exit 0
