#!/bin/bash
# SymbiOS - Manage Matrix sender account (homeserver, user, secret, room).
#
# Settings CLI-first architecture: the WebUI page /settings/matrix/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction; empty secrets delete the
# key, same as the WebUI before).
#
# Only the stored configuration lives here. The live homeserver probe
# (/_matrix/client/versions) stays Python in the WebUI container - it needs
# no host access (explicit non-goal, see AGENTS.md). The view runs
# "set --check" first (authoritative validation, no write), then its
# probe, then the real "set".
#
# Secrets (matrix_password, matrix_token) MUST come via --json-stdin, never
# as argv (visible in ps). There are deliberately no --password/--token
# flags.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage the SymbiOS Matrix sender account for notifications.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json; secret
                                  values are never printed, only whether
                                  they are set)
  set [--homeserver URL --user ID --room R | --json-stdin] [--check]
                                  Validate and write to inventory.yml.
                                  Required: homeserver, user (full Matrix
                                  ID like @sender:example.org), room (alias
                                  #... or ID !...), plus a password or an
                                  access token. The URL scheme defaults to
                                  https://. --json-stdin reads
                                  {"matrix_homeserver":..,
                                  "matrix_user":.., "matrix_password":..,
                                  "matrix_token":.., "matrix_room":..} from
                                  stdin (REQUIRED for the secrets). An
                                  empty secret deletes its key.
                                  --check validates only, changes nothing.
  remove [--check]                Delete the account (all matrix_* keys).
                                  --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (matrix-changed / matrix-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
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
  {"name": "matrix_homeserver", "type": "url", "label": "Homeserver URL",
   "required": true, "default": "", "secret": false,
   "placeholder": "https://matrix.example.org"},
  {"name": "matrix_user", "type": "text", "label": "User ID",
   "required": true, "default": "", "secret": false,
   "placeholder": "@sender:example.org"},
  {"name": "matrix_password", "type": "password", "label": "Password",
   "required": false, "default": "", "secret": true,
   "note": "Password or access token is required"},
  {"name": "matrix_token", "type": "password", "label": "Access token",
   "required": false, "default": "", "secret": true},
  {"name": "matrix_room", "type": "text", "label": "Room",
   "required": true, "default": "", "secret": false,
   "placeholder": "#alerts:example.org"}
]
EOF
  exit 0
fi

f_cur_server="$(f_symbios_var matrix_homeserver "")"
f_cur_user="$(f_symbios_var matrix_user "")"
f_cur_room="$(f_symbios_var matrix_room "")"
f_cur_pw_set="no"
[[ -n "$(f_symbios_var matrix_password "")" ]] && f_cur_pw_set="yes"
f_cur_token_set="no"
[[ -n "$(f_symbios_var matrix_token "")" ]] && f_cur_token_set="yes"

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    printf '{"matrix_homeserver": %s, "matrix_user": %s, "matrix_password_set": %s, "matrix_token_set": %s, "matrix_room": %s}\n' \
      "$(printf '%s' "${f_cur_server}" | f_json_escape)" \
      "$(printf '%s' "${f_cur_user}" | f_json_escape)" \
      "$([[ "${f_cur_pw_set}" == "yes" ]] && echo "true" || echo "false")" \
      "$([[ "${f_cur_token_set}" == "yes" ]] && echo "true" || echo "false")" \
      "$(printf '%s' "${f_cur_room}" | f_json_escape)"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_fail_usage
  fi
  echo "matrix_homeserver=${f_cur_server}"
  echo "matrix_user=${f_cur_user}"
  echo "matrix_password_set=${f_cur_pw_set}"
  echo "matrix_token_set=${f_cur_token_set}"
  echo "matrix_room=${f_cur_room}"
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
  f_check_flag=""
  [[ "${f_check}" == "yes" ]] && f_check_flag="--check"
  if ! f_out="$(printf '%s' '{"matrix_homeserver": null, "matrix_user": null, "matrix_password": null, "matrix_token": null, "matrix_room": null, "notify_matrix_enabled": null}' \
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
    g_echo_note "matrix-unchanged"
  else
    g_echo_note "matrix-changed"
  fi
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_server=""
f_user=""
f_room=""
f_new_pw=""
f_given_pw="no"
f_new_token=""
f_given_token="no"
f_json_stdin="no"
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --homeserver)
      [[ $# -ge 2 ]] || f_fail_usage
      f_server="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || f_fail_usage
      f_user="$2"
      shift 2
      ;;
    --room)
      [[ $# -ge 2 ]] || f_fail_usage
      f_room="$2"
      shift 2
      ;;
    --password|--password=*|--token|--token=*)
      f_fail_validation "Matrix secrets must be passed via --json-stdin, never as argv"
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
  for f_field in matrix_homeserver matrix_user matrix_password matrix_token matrix_room
  do
    [[ "${f_json}" == *'"'"${f_field}"'"'* ]] || continue
    f_val="$(f_json_get "${f_json}" "${f_field}")" || f_val=""
    case "${f_field}" in
      matrix_homeserver) f_server="${f_val}" ;;
      matrix_user) f_user="${f_val}" ;;
      matrix_password)
        f_new_pw="${f_val}"
        f_given_pw="yes"
        ;;
      matrix_token)
        f_new_token="${f_val}"
        f_given_token="yes"
        ;;
      matrix_room) f_room="${f_val}" ;;
    esac
  done
fi

# --- validation (same rules the WebUI enforced before) ---------------------------

f_missing=()
[[ -z "${f_server}" ]] && f_missing+=("Homeserver URL")
[[ -z "${f_user}" ]] && f_missing+=("User ID")
[[ -z "${f_room}" ]] && f_missing+=("Room")
# Effective secrets after this change (given values win, empty deletes;
# missing keys keep the stored value).
f_eff_pw="${f_cur_pw_set}"
[[ "${f_given_pw}" == "yes" ]] && {
  [[ -n "${f_new_pw}" ]] && f_eff_pw="yes" || f_eff_pw="no"
}
f_eff_token="${f_cur_token_set}"
[[ "${f_given_token}" == "yes" ]] && {
  [[ -n "${f_new_token}" ]] && f_eff_token="yes" || f_eff_token="no"
}
if [[ "${f_eff_pw}" == "no" && "${f_eff_token}" == "no" ]]
then
  f_missing+=("Password or access token")
fi
if [[ "${#f_missing[@]}" -gt 0 ]]
then
  f_fail_validation "Required fields missing: $(IFS=", "; echo "${f_missing[*]}")"
fi

# Scheme defaults to https (same as the WebUI and its probe).
f_server="${f_server%/}"
if [[ "${f_server}" != http://* && "${f_server}" != https://* ]]
then
  f_server="https://${f_server}"
fi
if [[ "${f_server}" == *$'\n'* ]] || [[ "${f_server}" =~ [[:space:]] ]]
then
  f_fail_validation "Invalid homeserver URL: must be a single line without whitespace"
fi
if ! [[ "${f_user}" =~ ^@[^:@[:space:]]+:[^:[:space:]]+$ ]]
then
  f_fail_validation "User ID must be a full Matrix ID like @sender:example.org"
fi
if [[ "${f_room}" != "#"* && "${f_room}" != "!"* ]]
then
  f_fail_validation "Room must be a room alias (starting with #) or a room ID (starting with !)"
fi

# --- transactional write (empty secrets delete their key) ------------------------

f_merge="$(printf '{"matrix_homeserver": %s, "matrix_user": %s, "matrix_room": %s' \
  "$(printf '%s' "${f_server}" | f_json_escape)" \
  "$(printf '%s' "${f_user}" | f_json_escape)" \
  "$(printf '%s' "${f_room}" | f_json_escape)")"
if [[ "${f_given_pw}" == "yes" ]]
then
  if [[ -n "${f_new_pw}" ]]
  then
    f_merge="${f_merge}, \"matrix_password\": $(printf '%s' "${f_new_pw}" | f_json_escape)"
  else
    f_merge="${f_merge}, \"matrix_password\": null"
  fi
fi
if [[ "${f_given_token}" == "yes" ]]
then
  if [[ -n "${f_new_token}" ]]
  then
    f_merge="${f_merge}, \"matrix_token\": $(printf '%s' "${f_new_token}" | f_json_escape)"
  else
    f_merge="${f_merge}, \"matrix_token\": null"
  fi
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
  g_echo_note "matrix-unchanged"
else
  g_echo_note "matrix-changed"
fi
exit 0
