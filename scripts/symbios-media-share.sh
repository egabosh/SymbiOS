#!/bin/bash
# SymbiOS - Manage shared group directories below the media root.
#
# A share is a directory <media_root>/shared/<name> owned by an LDAP group
# (default: shared-<name>, auto-created) with mode 2770, so exactly the
# group members can read and write it. Private user dirs
# (<media_root>/home/<uid>, 0700) are managed by symbios-sftp-share-homes.sh.
#
# Usage:
#   symbios-media-share.sh --list
#   symbios-media-share.sh --create --name <share> [--group <group>] [--quota <GiB>]
#   symbios-media-share.sh --delete --name <share>

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [options]

Manage shared group directories below ${g_media_root}/shared.

Options:
  --list                          List shares as JSON
  --create --name <share> [--group <group>] [--quota <GiB>]
                                  Create share dir + LDAP group (default group: shared-<share>,
                                  default quota: media_quota_share from inventory, 0 = unlimited)
  --delete --name <share>         Delete an empty share dir and its auto-created group
  -h, --help                      Show this help and exit
EOF
}

function f_ldap_gid {
  local f_group="$1"
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=${f_group},ou=groups,${f_base_dn}" gidNumber 2>/dev/null \
    | sed -n "s/^gidNumber: //p" | head -1
}

function f_ldap_group_exists {
  local f_group="$1"
  [[ -n "$(f_ldap_gid "${f_group}")" ]]
}

function f_ldap_members {
  local f_group="$1"
  f_symbios_ldap_init
  f_ldap_exec ldapsearch -x -H "${f_ldap_uri}" -D "${f_bind_dn}" -w "${f_admin_pw}" \
    -b "cn=${f_group},ou=groups,${f_base_dn}" memberUid 2>/dev/null \
    | sed -n "s/^memberUid: //p" | sort -u | tr '\n' ' '
}

function f_cmd_list {
  local f_dir f_name f_gid f_group f_mode f_members f_json f_first
  local f_shared="${g_media_root}/shared"
  local f_qline f_qused f_qlimit

  f_json="["
  f_first=1
  if [[ -d "${f_shared}" ]]
  then
    for f_dir in "${f_shared}"/*/
    do
      [[ -d "${f_dir}" ]] || continue
      f_name="$(basename "${f_dir}")"
      f_gid="$(stat -c '%g' "${f_dir}")"
      f_mode="$(stat -c '%a' "${f_dir}")"
      # Convention: the owning group is shared-<name>; fall back to the
      # numeric gid when no such group exists (e.g. custom group removed).
      f_group="shared-${f_name}"
      if ! f_ldap_group_exists "${f_group}"
      then
        f_group=""
      fi
      f_members=""
      if [[ -n "${f_group}" ]]
      then
        f_members="$(f_ldap_members "${f_group}")"
      fi
      # Project quota usage (best-effort, empty when unsupported).
      f_qused=""
      f_qlimit=""
      if command -v repquota >/dev/null 2>&1
      then
        f_qline="$(repquota -P "${g_media_root}" 2>/dev/null | awk -v id="#${f_gid}" '$1 == id {print $3, $5}')"
        f_qused="${f_qline%% *}"
        f_qlimit="${f_qline##* }"
        [[ "${f_qused}" == "${f_qlimit}" ]] && f_qlimit=""
      fi
      if [[ ${f_first} -eq 1 ]]
      then
        f_first=0
      else
        f_json="${f_json},"
      fi
      f_json="${f_json}{\"name\":\"${f_name}\",\"path\":\"${f_dir%/}\",\"group\":\"${f_group}\",\"gid\":\"${f_gid}\",\"mode\":\"${f_mode}\",\"members\":\"${f_members}\",\"quota_used\":\"${f_qused}\",\"quota_limit\":\"${f_qlimit}\"}"
    done
  fi
  f_json="${f_json}]"
  echo "${f_json}"
}

f_action=""
f_name=""
f_group=""
f_quota=""

while [[ $# -gt 0 ]]
do
  case "$1" in
    --list)
      f_action="list"
      shift
      ;;
    --create)
      f_action="create"
      shift
      ;;
    --delete)
      f_action="delete"
      shift
      ;;
    --name)
      f_name="$2"
      shift 2
      ;;
    --group)
      f_group="$2"
      shift 2
      ;;
    --quota)
      f_quota="$2"
      shift 2
      ;;
    -h|--help)
      f_usage
      exit 0
      ;;
    *)
      g_echo_error "Unknown option: $1"
      f_usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${f_action}" ]]
then
  g_echo_error "Missing action (--list, --create, --delete)"
  f_usage >&2
  exit 1
fi

if [[ "${f_action}" == "list" ]]
then
  f_cmd_list
  exit 0
fi

if [[ -z "${f_name}" ]]
then
  g_echo_error "Missing required argument: --name"
  f_usage >&2
  exit 1
fi

if ! [[ "${f_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
then
  g_echo_error "Invalid share name: must start with a letter or digit, then letters, digits, hyphens"
  exit 1
fi

if [[ -z "${f_group}" ]]
then
  f_group="shared-${f_name}"
fi

if ! [[ "${f_group}" =~ ^[a-zA-Z0-9._-]+$ ]]
then
  g_echo_error "Invalid group name: may only contain letters, digits, dots, hyphens, underscores"
  exit 1
fi

f_dir="${g_media_root}/shared/${f_name}"

case "${f_action}" in
  create)
    # Ensure the LDAP group exists (tolerate races: verify afterwards)
    if ! f_ldap_group_exists "${f_group}"
    then
      "${g_script_dir}/symbios-ldap-groups.sh" --create --name "${f_group}" >/dev/null 2>&1 || true
      if ! f_ldap_group_exists "${f_group}"
      then
        g_echo_error "Could not create LDAP group '${f_group}'"
        exit 1
      fi
      g_echo_note "LDAP group '${f_group}' created"
    fi
    f_gid="$(f_ldap_gid "${f_group}")"
    mkdir -p "${f_dir}"
    chown "root:${f_gid}" "${f_dir}"
    chmod 2770 "${f_dir}"
    # Project quota with the owning gid as stable project id: explicit
    # --quota wins, otherwise the inventory default (0 = unlimited).
    if [[ -z "${f_quota}" ]]
    then
      f_quota="$(f_symbios_var media_quota_share 0)"
    fi
    if ! [[ "${f_quota}" =~ ^[0-9]+$ ]]
    then
      g_echo_error "Invalid quota: must be GiB as a number"
      exit 1
    fi
    f_media_quota "${f_gid}" "${f_dir}" "${f_quota}"
    g_echo_note "Share '${f_name}' ready (${f_dir}, group ${f_group})"
    ;;

  delete)
    # Never delete non-empty dirs: rmdir fails instead of wiping data.
    if ! rmdir "${f_dir}" 2>/dev/null
    then
      g_echo_error "Cannot delete share '${f_name}': directory missing or not empty"
      exit 1
    fi
    g_echo_note "Share directory '${f_dir}' removed"
    # Only auto-created groups are removed with the share; custom groups
    # may be used elsewhere and are kept.
    if [[ "${f_group}" == "shared-${f_name}" ]]
    then
      "${g_script_dir}/symbios-ldap-groups.sh" --delete --name "${f_group}" >/dev/null 2>&1 || true
      g_echo_note "LDAP group '${f_group}' removed"
    fi
    ;;
esac
