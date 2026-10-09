#!/bin/bash
# SymbiOS - Manage the 8G swapfile on the encrypted data disk.
#
# The data disk unlocks late (manual boot-unlock), so the swapfile lives on
# it instead of the root filesystem. Called from base-services/basics.yml.
# Prints a token line only when something changed (Ansible changed_when).

function f_usage {
  cat << EOF
Usage: $(basename "$0") <create|activate|cleanup-legacy> [data_root]

  create          Create an 8G swapfile when missing or wrong (prints swapfile-created)
  activate        swapon the swapfile unless already active (prints swapon-ran)
  cleanup-legacy  Remove /var/swap once the new swapfile is active (prints old-swap-removed)

data_root defaults to the inventory value (symbios-lib.sh).

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_swap_create {
  local f_root="${1}"
  if [[ "$(stat -c%s "${f_root}/swapfile" 2>/dev/null)" != "8589934592" ]] \
     || ! blkid -s TYPE -o value "${f_root}/swapfile" 2>/dev/null | grep -qx swap
  then
    swapoff "${f_root}/swapfile" 2>/dev/null || true
    fallocate -l 8G "${f_root}/swapfile"
    chmod 600 "${f_root}/swapfile"
    mkswap "${f_root}/swapfile"
    echo "swapfile-created"
  fi
}

function f_swap_activate {
  local f_root="${1}"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${f_root}/swapfile"
  then
    echo "already-active"
  else
    swapon "${f_root}/swapfile" && echo "swapon-ran"
  fi
}

function f_swap_cleanup_legacy {
  local f_root="${1}"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${f_root}/swapfile"
  then
    swapoff /var/swap 2>/dev/null || true
    rm -f /var/swap
    echo "old-swap-removed"
  else
    echo "new swap not active, keeping /var/swap" >&2
    return 1
  fi
}

# Main: parse subcommand and data root
f_cmd="${1:-}"
f_root="${2:-${g_data_root}}"
case "${f_cmd}" in
  create)
    f_swap_create "${f_root}"
    ;;
  activate)
    f_swap_activate "${f_root}"
    ;;
  cleanup-legacy)
    f_swap_cleanup_legacy "${f_root}"
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
