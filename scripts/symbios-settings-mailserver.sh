#!/bin/bash
# SymbiOS - Manage SMTP relay settings (server, user, password, sender).
#
# Settings CLI-first architecture: the WebUI page /settings/mailserver/ is
# a thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction).
#
# Only the stored configuration lives here. The live SMTP connection test
# and the plain/SSL/TLS mail sending stay Python in the WebUI container
# (smtplib probes, no host access needed - explicit non-goal, see
# AGENTS.md). The view runs "set --check" first (authoritative validation,
# no write), then its live probe, then the real "set".
#
# Secrets (smtp_password) MUST come via --json-stdin, never as argv
# (visible in ps). There is deliberately no --password flag.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS SMTP relay settings (outgoing mail server).

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json; the
                                  password value is never printed, only
                                  whether one is set)
  set [--server H --port P --user U --from A --tls T
       | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  Required: server, port, from (email
                                  format), password (an empty password is
                                  rejected; omit the key to keep the stored
                                  one). %EMAILADDRESS% and
                                  %EMAILLOCALPART% in the user are expanded
                                  from the sender address. --json-stdin
                                  reads {"smtp_server":.., "smtp_port":..,
                                  "smtp_user":.., "smtp_password":..,
                                  "smtp_from":.., "smtp_tls":..} from stdin
                                  (REQUIRED for the password).
                                  --check validates only, changes nothing.
  remove [--check]                Delete all smtp_* keys. Refused while 2FA
                                  or mail notifications are enabled (they
                                  need a sender). --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (mailserver-changed / mailserver-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (missing field, bad email/port, ...)
  1  technical error (inventory unreadable, ...)
EOF
}

function f_fail_usage {
  f_usage >&2
  exit 2
}

function f_fail_validation {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 2
}

function f_fail_technical {
  g_echo_error "$1" || echo "Error: $1" >&2
  exit 1
}

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|remove|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_fail_usage
    ;;
esac

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "smtp_server", "type": "text", "label": "SMTP server",
   "required": true, "default": "", "secret": false,
   "placeholder": "mail.example.com"},
  {"name": "smtp_port", "type": "number", "label": "SMTP port",
   "required": true, "default": "587", "secret": false},
  {"name": "smtp_user", "type": "text", "label": "SMTP username",
   "required": false, "default": "%EMAILADDRESS%", "secret": false},
  {"name": "smtp_password", "type": "password", "label": "SMTP password",
   "required": true, "default": "", "secret": true},
  {"name": "smtp_from", "type": "text", "label": "Sender address",
   "required": true, "default": "", "secret": false,
   "placeholder": "symbios@example.com"},
  {"name": "smtp_tls", "type": "select", "label": "Encryption",
   "required": false, "default": "", "secret": false,
   "options": ["", "starttls", "tls"]}
]
EOF
  exit 0
fi

f_cur_server="$(f_symbios_var smtp_server "")"
f_cur_port="$(f_symbios_var smtp_port "")"
f_cur_user="$(f_symbios_var smtp_user "")"
f_cur_from="$(f_symbios_var smtp_from "")"
f_cur_tls="$(f_symbios_var smtp_tls "")"
f_cur_pw_set="no"
[[ -n "$(f_symbios_var smtp_password "")" ]] && f_cur_pw_set="yes"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"smtp_server": %s, "smtp_port": %s, "smtp_user": %s, "smtp_password_set": %s, "smtp_from": %s, "smtp_tls": %s}\n' \
      "$(printf '%s' "${f_cur_server}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_port}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_user}" | f_json_escape)" \
      "$([[ "${f_cur_pw_set}" == "yes" ]] && echo "true" || echo "false")" \
      "$(printf '%s' "${f_cur_from}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_tls}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  echo "smtp_server=${f_cur_server}"
  echo "smtp_port=${f_cur_port}"
  echo "smtp_user=${f_cur_user}"
  echo "smtp_password_set=${f_cur_pw_set}"
  echo "smtp_from=${f_cur_from}"
  echo "smtp_tls=${f_cur_tls}"
  exit 0
fi

# --- subcommand: remove ----------------------------------------------------------

if [[ "${f_command}" == "remove" ]]
then
  f_check="no"
  while [[ $# -gt 0 ]]
  do
    case "$1" in
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
        f_fail_usage
        ;;
    esac
  done
  # Guards (same rules the WebUI enforced before): 2FA and mail
  # notifications both need a sender address.
  f_twofa="$(f_symbios_var twofa_enabled "")"
  if [[ "${f_twofa}" == "True" || "${f_twofa}" == "true" ]]
  then
    f_fail_validation "Cannot delete SMTP configuration while 2-Factor Authentication (2FA) is enabled - disable 2FA under Settings Auth first"
  fi
  if [[ -n "$(f_symbios_var notify_mail_enabled "")" ]] \
    && [[ "$(f_symbios_var notify_mail_enabled "")" == "True" \
      || "$(f_symbios_var notify_mail_enabled "")" == "true" ]]
  then
    f_fail_validation "Cannot delete SMTP configuration while mail notifications are enabled - disable them under Settings Notifications first"
  fi
  f_check_flag=""
  [[ "${f_check}" == "yes" ]] && f_check_flag="--check"
  if ! f_out="$(printf '%s' '{"smtp_server": null, "smtp_port": null, "smtp_user": null, "smtp_password": null, "smtp_from": null, "smtp_tls": null}' \
    | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge ${f_check_flag} 2>&1)"
  then
    f_fail_technical "Failed to write inventory: ${f_out}"
  fi
  g_echo "${f_out}"
  if [[ "${f_check}" == "yes" ]]
  then
    g_echo_note "Check mode - nothing was changed"
    exit 0
  fi
  if grep -q "^unchanged$" <<< "${f_out}"
  then
    g_echo_note "mailserver-unchanged"
  else
    g_echo_note "mailserver-changed"
  fi
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_server=""
f_port=""
f_user=""
f_given_user="no"
f_from=""
f_tls=""
f_given_tls="no"
f_new_pw=""
f_given_pw="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || f_fail_usage
      f_server="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || f_fail_usage
      f_port="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || f_fail_usage
      f_user="$2"
      f_given_user="yes"
      shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || f_fail_usage
      f_from="$2"
      shift 2
      ;;
    --tls)
      [[ $# -ge 2 ]] || f_fail_usage
      f_tls="$2"
      f_given_tls="yes"
      shift 2
      ;;
    --password|--password=*)
      f_fail_validation "smtp_password is a secret and must be passed via --json-stdin, never as argv"
      ;;
    --json-stdin)
      f_json_stdin="yes"
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
      f_fail_usage
      ;;
  esac
done

if [[ "${f_json_stdin}" == "yes" ]]
then
  f_json="$(cat)"
  for f_field in smtp_server smtp_port smtp_user smtp_password smtp_from smtp_tls
  do
    [[ "${f_json}" == *'"'"${f_field}"'"'* ]] || continue
    f_val="$(f_json_get "${f_json}" "${f_field}")" || f_val=""
    case "${f_field}" in
      smtp_server) f_server="${f_val}" ;;
      smtp_port) f_port="${f_val}" ;;
      smtp_user)
        f_user="${f_val}"
        f_given_user="yes"
        ;;
      smtp_password)
        f_new_pw="${f_val}"
        f_given_pw="yes"
        ;;
      smtp_from) f_from="${f_val}" ;;
      smtp_tls)
        f_tls="${f_val}"
        f_given_tls="yes"
        ;;
    esac
  done
fi

# --- validation (same rules the WebUI enforced before) ---------------------------

f_missing=()
[[ -z "${f_server}" ]] && f_missing+=("SMTP Server")
[[ -z "${f_port}" ]] && f_missing+=("SMTP Port")
[[ -z "${f_from}" ]] && f_missing+=("Email Address")
# The password field is pre-filled by the WebUI form, so an explicitly
# empty password means "cleared by the user" and is rejected (same as the
# WebUI before). Only a missing key keeps the stored password (CLI use).
if [[ -z "${f_new_pw}" ]]
then
  f_missing+=("Password")
fi
if [[ "${#f_missing[@]}" -gt 0 ]]
then
  f_fail_validation "Required fields missing: $(IFS=", "; echo "${f_missing[*]}")"
fi

if ! [[ "${f_from}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
then
  f_fail_validation "Invalid email address format (expected user@domain.tld)"
fi
if ! [[ "${f_port}" =~ ^[0-9]+$ ]] || [[ "10#${f_port}" -lt 1 || "10#${f_port}" -gt 65535 ]]
then
  f_fail_validation "Invalid SMTP port: ${f_port} (expected 1-65535)"
fi
if [[ -n "${f_server}" ]] \
  && { [[ "${f_server}" == *$'\n'* ]] || [[ "${f_server}" =~ [[:space:]] ]]; }
then
  f_fail_validation "Invalid SMTP server: must be a single line without whitespace"
fi
if [[ "${f_given_tls}" == "yes" ]]
then
  case "${f_tls}" in
    ""|starttls|tls)
      ;;
    *)
      f_fail_validation "Invalid encryption: ${f_tls} (expected empty, starttls or tls)"
      ;;
  esac
else
  f_tls="${f_cur_tls}"
fi
[[ "${f_given_user}" == "yes" ]] || f_user="${f_cur_user}"

# Expand %EMAILADDRESS% / %EMAILLOCALPART% in the user from the sender.
f_user="${f_user//\%EMAILADDRESS\%/${f_from}}"
f_user="${f_user//\%EMAILLOCALPART\%/${f_from%%@*}}"

# --- transactional write (empty password keeps the stored one) -------------------

f_merge="$(printf '{"smtp_server": %s, "smtp_port": %s, "smtp_user": %s, "smtp_from": %s, "smtp_tls": %s' \
  "$(printf '%s' "${f_server}" | f_json_escape)" \
  "$(printf '%s' "${f_port}" | f_json_escape)" \
  "$(printf '%s' "${f_user}" | f_json_escape)" \
  "$(printf '%s' "${f_from}" | f_json_escape)" \
  "$(printf '%s' "${f_tls}" | f_json_escape)")"
if [[ "${f_given_pw}" == "yes" ]]
then
  f_merge="${f_merge}, \"smtp_password\": $(printf '%s' "${f_new_pw}" | f_json_escape)"
fi
f_merge="${f_merge}}"

f_check_flag=""
[[ "${f_check}" == "yes" ]] && f_check_flag="--check"

if ! f_out="$(printf '%s' "${f_merge}" \
  | "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge ${f_check_flag} 2>&1)"
then
  f_fail_technical "Failed to write inventory: ${f_out}"
fi

g_echo "${f_out}"

if [[ "${f_check}" == "yes" ]]
then
  g_echo_note "Check mode - nothing was changed"
  exit 0
fi

if grep -q "^unchanged$" <<< "${f_out}"
then
  g_echo_note "mailserver-unchanged"
else
  g_echo_note "mailserver-changed"
fi
exit 0
