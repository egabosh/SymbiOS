#!/bin/bash
# SymbiOS - Manage Traefik host access (global default plus per-service override).
#
# Settings CLI-first architecture: the WebUI page /settings/access/ and the
# network-access selector on service detail pages are thin wrappers around this
# script. It owns validation and the transactional inventory.yml write.
#
# Effective mode of a service: traefik_service_access[service] when set to
# internal/internet, otherwise traefik_default_access (default: internal).
# "internal" makes the playbooks attach the existing allowlocalipsonly@file
# middleware to the service's Traefik router.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage which Traefik hosts accept internet traffic.

Commands:
  get [--json] [--service NAME]
                                   Print the global default and, with --service,
                                   the effective mode and its source.
  set --default internal|internet  Set the global default.
  set --service NAME --mode default|internal|internet
                                   Set or clear (mode=default) one override.
      Both set forms accept --check (dry run) and --no-apply.
  set --json-stdin                 Read {"traefik_default_access": ..,
                                   "traefik_service_access": {..}} from stdin.
  schema                           Print the field description as JSON.
  apply [--dry-run]                Resolve consuming playbooks (or show them
                                   with --dry-run) and run each in order.
  -h, --help                       Show this help and exit

Output: human status lines; the final line carries a machine-readable token
(access-changed / access-unchanged). get --json prints one JSON object.

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error
  1  technical error (inventory unreadable, ...)
EOF
}

# Inventory keys managed here (for apply + coverage check).
f_managed_vars="traefik_default_access traefik_service_access"

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

function f_valid_mode {
  case "${1:-}" in
    default|internal|internet)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

function f_current_default {
  local f_val
  # Read through symbios-inventory.py: the shipped inventory line carries an
  # inline comment that a plain scalar read would keep.
  f_val="$(f_symbios_var_json traefik_default_access | jq -r 'select(type == "string")' 2>/dev/null)"
  case "${f_val}" in
    internal|internet)
      echo "${f_val}"
      ;;
    *)
      echo "internal"
      ;;
  esac
}

function f_current_map {
  local f_map
  f_map="$(f_symbios_var_json traefik_service_access)"
  # A stored scalar is not a valid override map; fall back to an empty one.
  if ! jq -e 'type == "object"' <<< "${f_map}" >/dev/null 2>&1
  then
    echo "{}"
  else
    echo "${f_map}"
  fi
}

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
  {"name": "traefik_default_access", "type": "select",
   "label": "Internet access for Traefik hosts",
   "required": true, "default": "internal", "secret": false,
   "options": [
     {"value": "internal", "label": "Internal only (LAN/VPN)"},
     {"value": "internet", "label": "Internet"}
   ],
   "note": "Applies to all services unless a service overrides it. Authelia stays reachable from outside for login."}
]
EOF
  exit 0
fi

f_default="$(f_current_default)"
f_map="$(f_current_map)"

if [[ "${f_command}" == "get" ]]
then
  f_service=""
  f_json="no"
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --service)
        [[ $# -ge 2 ]] || f_ss_fail_usage
        f_service="$2"
        shift 2
        ;;
      --service=*)
        f_service="${1#--service=}"
        shift
        ;;
      --json)
        f_json="yes"
        shift
        ;;
      -h|--help)
        f_usage
        exit 0
        ;;
      *)
        echo "Unknown option for get: $1" >&2
        f_ss_fail_usage
        ;;
    esac
  done

  if [[ -n "${f_service}" ]]
  then
    f_override="$(jq -r --arg k "${f_service}" '.[$k] // "default"' <<< "${f_map}")"
    f_source="default"
    f_mode="${f_default}"
    [[ "${f_override}" != "default" ]] && f_source="override" && f_mode="${f_override}"
    if [[ "${f_json}" == "yes" ]]
    then
      jq -n --arg default "${f_default}" --arg service "${f_service}" \
        --arg mode "${f_mode}" --arg source "${f_source}" \
        '{traefik_default_access: $default, service: $service, mode: $mode, source: $source}'
    else
      echo "traefik_default_access=${f_default}"
      echo "service=${f_service}"
      echo "mode=${f_mode}"
      echo "source=${f_source}"
    fi
    exit 0
  fi

  if [[ "${f_json}" == "yes" ]]
  then
    jq -n --arg default "${f_default}" --argjson map "${f_map}" \
      '{traefik_default_access: $default, traefik_service_access: $map}'
  else
    echo "traefik_default_access=${f_default}"
    jq -r 'to_entries[] | "service=\(.key) mode=\(.value)"' <<< "${f_map}"
  fi
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_new_default=""
f_given_default="no"
f_new_service=""
f_new_mode=""
f_check="no"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --default)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_default="$2"
      f_given_default="yes"
      shift 2
      ;;
    --default=*)
      f_new_default="${1#--default=}"
      f_given_default="yes"
      shift
      ;;
    --service)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_service="$2"
      shift 2
      ;;
    --service=*)
      f_new_service="${1#--service=}"
      shift
      ;;
    --mode)
      [[ $# -ge 2 ]] || f_ss_fail_usage
      f_new_mode="$2"
      shift 2
      ;;
    --mode=*)
      f_new_mode="${1#--mode=}"
      shift
      ;;
    --json-stdin)
      f_json="$(cat)"
      if jq -e 'has("traefik_default_access")' <<< "${f_json}" >/dev/null 2>&1
      then
        f_new_default="$(jq -r '.traefik_default_access' <<< "${f_json}")"
        f_given_default="yes"
      fi
      if jq -e 'has("traefik_service_access")' <<< "${f_json}" >/dev/null 2>&1
      then
        if ! jq -e '.traefik_service_access | type == "object"' <<< "${f_json}" >/dev/null 2>&1
        then
          f_ss_fail_validation "traefik_service_access must be an object"
        fi
        if ! jq -e 'all((.traefik_service_access | to_entries[]);
                       (.key | test("^[a-z0-9][a-z0-9-]*$")) and
                       (.value == "default" or .value == "internal" or .value == "internet"))' \
          <<< "${f_json}" >/dev/null 2>&1
        then
          f_ss_fail_validation "traefik_service_access entries need a service key and default|internal|internet"
        fi
        f_map="$(jq -c '.traefik_service_access' <<< "${f_json}")"
      fi
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

if [[ "${f_given_default}" == "no" && -z "${f_new_service}" ]]
then
  f_ss_fail_validation "Nothing to set - pass --default, --service/--mode or --json-stdin"
fi

if [[ -n "${f_new_service}" ]]
then
  if [[ ! "${f_new_service}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  then
    f_ss_fail_validation "Invalid service name: ${f_new_service}"
  fi
  if ! f_valid_mode "${f_new_mode}"
  then
    f_ss_fail_validation "Invalid --mode: ${f_new_mode} (expected default|internal|internet)"
  fi
fi

if [[ "${f_given_default}" == "yes" ]] \
  && [[ "${f_new_default}" != "internal" && "${f_new_default}" != "internet" ]]
then
  f_ss_fail_validation "Invalid --default: ${f_new_default} (expected internal|internet)"
fi

# --- transactional write (both keys in one load/merge/dump cycle) -------------

f_eff_default="${f_default}"
[[ "${f_given_default}" == "yes" ]] && f_eff_default="${f_new_default}"

f_eff_map="${f_map}"
if [[ -n "${f_new_service}" ]]
then
  if [[ "${f_new_mode}" == "default" ]]
  then
    f_eff_map="$(jq -c --arg k "${f_new_service}" 'del(.[$k])' <<< "${f_map}")"
  else
    f_eff_map="$(jq -c --arg k "${f_new_service}" --arg v "${f_new_mode}" '.[$k] = $v' <<< "${f_map}")"
  fi
fi

f_ss_merge "$(printf '{"traefik_default_access": %s, "traefik_service_access": %s}' \
  "$(printf '%s' "${f_eff_default}" | f_json_escape)" "${f_eff_map}")" \
  "access" "${f_check}" "default=${f_eff_default}"
f_ss_finish
exit $?
