#!/bin/bash

# SymbiOS - Full uninstall cleanup for Mastodon.
#
# Removes the per-instance LDAP groups and the named Authelia OIDC client and
# policy blocks. Called by the uninstall harness (full mode only); safe to run
# manually. Service files, Traefik provider and healthchecks are removed by
# the uninstall harness itself.

function f_usage {
  cat << EOF
Usage: $(basename "$0") [all|groups|authelia]

Clean up SymbiOS state of all Mastodon instances.

Modes:
  all         remove LDAP groups and Authelia blocks (default)
  groups      remove only the per-instance LDAP groups
  authelia    remove only the OIDC client and policy blocks

Options:
  -h, --help  Show this help and exit

Examples:
  symbios-mastodon-cleanup.sh groups
  symbios-mastodon-cleanup.sh authelia

Output:
  One status line per removed state item.

Exit codes:
  0   cleanup finished
  2   usage error
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

if [[ $# -gt 1 ]]
then
  f_usage >&2
  exit 2
fi

if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include
fi
g_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -r "$g_script_dir/symbios-lib.sh" ]]
then
  source "$g_script_dir/symbios-lib.sh"
fi

g_config_dir="${g_config_dir:-/symbios/base-services/symbios-ui/config}"
g_base_services_root="${g_base_services_root:-/symbios/base-services}"
g_instances_file="${g_config_dir}/services/mastodon/instances.yml"
g_authelia_config="${g_base_services_root}/authelia/authelia-data/configuration.yml"
g_mode="${1:-all}"

function f_strip_authelia_markers {
  local f_kind="$1"
  local f_file f_tmp f_changed

  f_file="$g_authelia_config"
  if [[ ! -f "$f_file" ]]
  then
    return 0
  fi

  f_tmp=$(mktemp)
  if [[ "$f_kind" == "clients" ]]
  then
    awk '
      /^# BEGIN ANSIBLE MANAGED BLOCK OIDC mastodon-/ { skip=1; next }
      skip && /^# END ANSIBLE MANAGED BLOCK OIDC mastodon-/ { skip=0; next }
      !skip { print }
    ' "$f_file" > "$f_tmp"
  else
    awk '
      /^# BEGIN ANSIBLE MANAGED BLOCK OIDC POLICY mastodon-/ { skip=1; next }
      skip && /^# END ANSIBLE MANAGED BLOCK OIDC POLICY mastodon-/ { skip=0; next }
      !skip { print }
    ' "$f_file" > "$f_tmp"
  fi

  if cmp -s "$f_file" "$f_tmp"
  then
    rm -f "$f_tmp"
    return 0
  fi
  f_changed=1
  cat "$f_tmp" > "$f_file"
  rm -f "$f_tmp"
  g_echo_note "Removed Mastodon $f_kind blocks from $f_file"
  return 0
}

case "$g_mode" in
  all|groups|authelia)
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac

if [[ "$g_mode" == "all" || "$g_mode" == "groups" ]]
then
  if [[ -f "$g_instances_file" ]]
  then
    while IFS= read -r f_name
    do
      [[ "$f_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
      for f_group in "mastodon-${f_name}-users" "mastodon-${f_name}-admins"
      do
        "$g_script_dir/symbios-ldap-groups.sh" --delete --name "$f_group" >/dev/null 2>&1 || true
        g_echo_note "Removed LDAP group $f_group"
      done
    done < <(yq eval -r '.[].name' "$g_instances_file" 2>/dev/null)
  fi
fi

if [[ "$g_mode" == "all" || "$g_mode" == "authelia" ]]
then
  # Clients first: Authelia would reject the configuration while a client
  # still references a policy that no longer exists.
  f_strip_authelia_markers clients
  f_strip_authelia_markers policies
  (cd "$g_base_services_root/authelia" && docker compose restart) >/dev/null 2>&1 || true
fi

g_echo_ok "Mastodon cleanup finished ($g_mode)"
