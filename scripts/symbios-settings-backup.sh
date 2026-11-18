#!/bin/bash
# SymbiOS - Manage backup target settings (servers, retention, excludes).
#
# Settings CLI-first architecture: the WebUI page /settings/backup/ (main
# form) is a thin wrapper around this script, which owns validation and
# the inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction).
#
# Only the target configuration lives here. Snapshot listing, repository
# password handling, restore planning/execution and manual runs stay with
# their dedicated scripts (symbios-backup-list.sh, symbios-backup.sh,
# symbios-restore.sh, backup.sh) and the thin WebUI endpoints calling them.
#
# Secrets note: the restic repository password is NOT an inventory var -
# it lives in the config dir, generated and shown via
# "symbios-backup.sh gen-restic-password|get-restic-password", so it never
# appears in argv, JSON answers or audit logs. This script therefore needs
# no --json-stdin. Backups are always encrypted (restic repository format).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS backup target settings (backup servers, restic retention,
exclude patterns).

Commands:
  get [--json]                    Print current values (key=value lines;
                                  backup_exclude one extra pattern per line;
                                  or a JSON object with --json)
  set [--host H --port P --user U --path P
       --enabled true|false --exclude-stdin
       --keep-daily N --keep-weekly N --keep-monthly N
       --servers '<json>'] [--check]
                                   Validate and write to inventory.yml.
                                   --enabled switches the nightly backup on
                                   or off (off by default).
                                   Options left out keep their current value;
                                   an empty --port/--user falls back to 22 /
                                   root (same as the WebUI). --exclude-stdin
                                   reads extra restic exclude patterns from
                                   stdin (empty lines and # comments skipped);
                                   they are applied in addition to the
                                   built-in excludes, not instead of them.
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
  $(basename "$0") set --host backup.example.com --user root --path /backups/symbios
  printf '%s\n' '*.tmp' 'cache/' | $(basename "$0") set --exclude-stdin

Options:
  --no-apply                      Skip the automatic playbook apply after a
                                  real inventory change (smoke tests).

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
  {"name": "backup_enabled", "type": "bool", "label": "Nightly backup",
   "required": true, "default": false, "secret": false,
   "note": "The backup job only runs when this is switched on."},
  {"name": "backup_keep_daily", "type": "number", "label": "Keep daily snapshots",
   "required": false, "default": "7", "secret": false},
  {"name": "backup_keep_weekly", "type": "number", "label": "Keep weekly snapshots",
   "required": false, "default": "4", "secret": false},
  {"name": "backup_keep_monthly", "type": "number", "label": "Keep monthly snapshots",
   "required": false, "default": "9999", "secret": false},
  {"name": "backup_exclude", "type": "multiline", "label": "Extra exclude patterns",
   "required": false, "default": [], "secret": false,
   "note": "One restic exclude pattern per line, # comments allowed. Applied in addition to the built-in excludes (docker/containerd, the swap file, caches, Nextcloud trash/previews/versions, the backup repository itself)."}
]
EOF
  exit 0
fi

f_cur_host="$(f_symbios_var backup_server_host "")"
f_cur_port="$(f_symbios_var backup_server_port "22")"
f_cur_user="$(f_symbios_var backup_server_user "root")"
f_cur_path="$(f_symbios_var backup_server_path "")"
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
    f_cur_name="$(f_symbios_var backup_server_name "")"
    printf '{"backup_server_host": %s, "backup_server_port": %s, "backup_server_user": %s, "backup_server_path": %s, "backup_server_name": %s, "backup_enabled": %s, "backup_exclude": %s, "backup_servers": %s, "backup_keep_daily": %s, "backup_keep_weekly": %s, "backup_keep_monthly": %s}\n' \
      "$(printf '%s' "${f_cur_host}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_port}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_user}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_path}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_name}" | f_json_escape)" \
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
f_new_name=""
f_new_enabled=""
f_new_keep_daily=""
f_new_keep_weekly=""
f_new_keep_monthly=""
f_new_servers=""
f_given_host="no"
f_given_port="no"
f_given_user="no"
f_given_path="no"
f_given_name="no"
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
    --name)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_name="$2"
      f_given_name="yes"
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
      for f_field in backup_server_host backup_server_port backup_server_user backup_server_path backup_enabled backup_exclude
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
        if [[ "${f_field}" == "backup_enabled" ]]
        then
          f_onoff="$(grep -o "\"${f_field}\"[[:space:]]*:[[:space:]]*[^,}]*" <<< "${f_json}" | head -1)"
          f_onoff="${f_onoff##*:}"
          f_onoff="${f_onoff#"${f_onoff%%[![:space:]]*}"}"
          f_onoff="${f_onoff%"${f_onoff##*[![:space:]]}"}"
          f_onoff="${f_onoff%\"}"
          f_onoff="${f_onoff#\"}"
          f_new_enabled="${f_onoff}"
          f_given_enabled="yes"
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
    --no-apply)
      g_ss_no_apply="yes"
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
   && "${f_given_enabled}" == "no" \
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
[[ "${f_given_enabled}" == "no" ]] && f_new_enabled="${f_cur_enabled}"
# Without these the omitted retention would fall back to the defaults in the
# unified-list builder (7/4/9999) and a single-field set would silently reset
# the stored retention.
[[ "${f_given_keep_daily}" == "no" ]] && f_new_keep_daily="${f_cur_keep_daily}"
[[ "${f_given_keep_weekly}" == "no" ]] && f_new_keep_weekly="${f_cur_keep_weekly}"
[[ "${f_given_keep_monthly}" == "no" ]] && f_new_keep_monthly="${f_cur_keep_monthly}"
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

# Additional servers: validate and normalize the JSON list with jq, then pass
# the normalized result into the single inventory merge below.
if [[ "${f_given_servers}" == "yes" ]]
then
  if ! f_servers_norm="$(printf '%s' "${f_new_servers}" | jq -c '
    def s:
      if . == null or . == false or . == 0 or . == "" or . == [] or . == {}
      then "" else (tostring | gsub("^\\s+|\\s+$"; "")) end;
    def num($default):
      if . == null or . == "" then $default
      else (tonumber? // $default) as $n
      | if $n >= 0 and $n <= 99999 then ($n | floor) else $default end end;
    def bad: ("invalid server entry" | halt_error(2));
    if type != "array" then bad else . end
    | [ .[] as $srv
        | if ($srv | type) != "object" then bad else $srv end
        | ($srv.host | s) as $host
        | ($srv.path | s) as $path
        | ($srv.user | s) as $user
        | ($srv.name | s) as $name
        | if $host == "" or $path == "" then bad else . end
        | if (($host + $user + $name) | test("\\s")) then bad else . end
        | (if $path | startswith("/") then $path else "/" + $path end) as $path
        | { name: (if $name == "" then $host else $name end),
            host: $host,
            port: ($srv.port | num(22) | tostring),
            user: (if $user == "" then "root" else $user end),
            path: $path,
            keep_daily: ($srv.keep_daily | num(7)),
            keep_weekly: ($srv.keep_weekly | num(4)),
            keep_monthly: ($srv.keep_monthly | num(9999)) }
      ]
  ' 2>/dev/null)"
  then
    f_ss_fail_validation "Invalid --servers JSON (expected an array of objects with host and path)"
  fi
fi

# --- transactional write -------------------------------------------------------

# Build the unified backup_servers array: the primary target first, then the
# additional servers. When --servers was given its entries are the base list
# (the WebUI sends the primary as its first row); otherwise the currently
# stored list is kept so a CLI update of single fields never drops other
# servers. The primary is upserted by host+path, so re-saving is idempotent.
f_base_servers="${f_cur_servers_json}"
if [[ "${f_given_servers}" == "yes" ]]
then
  f_base_servers="${f_servers_norm}"
fi
# The primary is only upserted when host and path were given explicitly. If
# --servers was given instead, its list is authoritative (the WebUI sends the
# primary as its first row) - the fallback to the stored legacy values must
# not resurrect a stale primary in that case.
if [[ -n "${f_new_host}" && -n "${f_new_path}" ]] \
  && { [[ "${f_given_servers}" == "no" ]] \
       || [[ "${f_given_host}" == "yes" || "${f_given_path}" == "yes" ]]; }
then
  f_primary_name="${f_new_name:-}"
  [[ -z "${f_primary_name}" ]] && f_primary_name="$(f_symbios_var backup_server_name "$(hostname)")"
  if ! f_unified_json="$(jq -c -n \
      --arg name "${f_primary_name}" --arg host "${f_new_host}" \
      --arg port "${f_new_port}" --arg user "${f_new_user}" \
      --arg path "${f_new_path}" \
      --arg kd "${f_new_keep_daily:-7}" --arg kw "${f_new_keep_weekly:-4}" \
      --arg km "${f_new_keep_monthly:-9999}" \
      --arg base "${f_base_servers}" '
    def s($default): if . == null or . == "" then $default else . end;
    def intval($default):
      if test("^[0-9]+$") then tonumber else $default end;
    ($base | fromjson) as $base_list
    | [ { name: ($name | s($host)), host: $host, port: ($port | s("22")),
          user: ($user | s("root")), path: $path,
          keep_daily: ($kd | intval(7)), keep_weekly: ($kw | intval(4)),
          keep_monthly: ($km | intval(9999)) } ]
    + [ $base_list[]?
        | select((type == "object") and (.host != null) and (.host != "")
                 and (.path != null) and (.path != ""))
        | select(.host != $host or .path != $path)
      ]
  ' 2>/dev/null)"
  then
    f_ss_fail_validation "Failed to build the unified server list"
  fi
else
  f_unified_json="${f_base_servers}"
fi

# Keep the legacy primary keys in sync with the first entry of the array, so
# older readers (and the backward-compat fallback in symbios-backup-lib.sh)
# never see a stale or ghost target. Explicitly given retention values and
# names win over the derived ones. The result is a JSON fragment that is
# spliced into the merge object below.
if ! f_legacy_frag="$(jq -r -n \
    --arg unified "${f_unified_json}" \
    --arg gkd "${f_given_keep_daily}" --arg kd "${f_new_keep_daily}" \
    --arg gkw "${f_given_keep_weekly}" --arg kw "${f_new_keep_weekly}" \
    --arg gkm "${f_given_keep_monthly}" --arg km "${f_new_keep_monthly}" \
    --arg gname "${f_given_name}" --arg name "${f_new_name}" '
  def sval($default): if . == null or . == "" then $default else tostring end;
  def intv($default):
    if type == "number" then .
    elif (tostring | test("^[0-9]+$")) then (tostring | tonumber)
    else $default end;
  ($unified | fromjson) as $list
  | (if ($list | type) == "array" and ($list | length) > 0
        and (($list[0] | type) == "object")
     then $list[0] else {} end) as $s
  | { backup_server_name: ($s.name | sval("")),
      backup_server_host: ($s.host | sval("")),
      backup_server_port: ($s.port | sval("22")),
      backup_server_user: ($s.user | sval("root")),
      backup_server_path: ($s.path | sval("")),
      backup_keep_daily: ($s.keep_daily | intv(7)),
      backup_keep_weekly: ($s.keep_weekly | intv(4)),
      backup_keep_monthly: ($s.keep_monthly | intv(9999)) }
  | if $gkd == "yes" then .backup_keep_daily = ($kd | tonumber) else . end
  | if $gkw == "yes" then .backup_keep_weekly = ($kw | tonumber) else . end
  | if $gkm == "yes" then .backup_keep_monthly = ($km | tonumber) else . end
  | if ($gname == "yes" and $name != "") then .backup_server_name = $name else . end
  # Same shape as json.dumps(...)[1:-1]: key/value pairs without the braces.
  | to_entries | map("\(.key | @json): \(.value | @json)") | join(", ")
' 2>/dev/null)"
  then
  f_ss_fail_validation "Failed to derive the legacy primary keys"
fi

# "backup_encryption": null removes the retired key from inventories that
# still carry it (rsync-era toggle; restic repositories are always encrypted).
f_merge="$(printf '{"backup_servers": %s, "backup_enabled": %s, "backup_encryption": null, %s' \
  "${f_unified_json}" \
  "${f_new_enabled}" \
  "${f_legacy_frag}")"

if [[ "${f_given_excludes}" == "yes" ]]
then
  f_merge="${f_merge}, \"backup_exclude\": ${f_excludes_json}}"
else
  f_merge="${f_merge}}"
fi

f_ss_merge "${f_merge}" "backup" "${f_check}"
f_ss_finish
exit $?
