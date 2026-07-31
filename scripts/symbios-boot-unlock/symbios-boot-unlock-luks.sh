#!/bin/bash
# SymbiOS - LUKS boot unlock helper (called by unlock.py or standalone)
#
# Actions:
#   check       — JSON status: needs_unlock, device, error
#   unlock      — read passphrase from stdin, unlock LUKS, mount /symbios
#   close       — unmount /symbios, close LUKS

g_luks_label="CRYPT_LUKS_SYMBIOS_DATA"
g_mapper_name="symbios-luks"

function f_find_luks {
  local f_dev
  f_dev=$(lsblk -n -l -o FSTYPE,LABEL,NAME 2>/dev/null | \
    awk -v label="$g_luks_label" \
      '$1 == "crypto_LUKS" && ($2 == label || $2 == "") {print $3; exit}')
  if [[ -z "$f_dev" ]]
  then
    f_dev=$(lsblk -n -l -o FSTYPE,NAME 2>/dev/null | \
      awk '$1 == "crypto_LUKS" {print $2; exit}')
  fi
  echo "$f_dev"
}

function f_luks_is_open {
  cryptsetup status "$g_mapper_name" 2>/dev/null | head -1 | grep -q "is active"
}

function f_json_escape {
  local f_s
  IFS= read -r f_s
  f_s="${f_s//\\/\\\\}"
  f_s="${f_s//\"/\\\"}"
  f_s="${f_s//$'\t'/\\t}"
  f_s="${f_s//$'\n'/\\n}"
  f_s="${f_s//$'\r'/\\r}"
  printf '"%s"' "$f_s"
}

function f_json_error {
  local f_msg="$1"
  printf '{"ok":false,"error":%s}\n' "$(echo "$f_msg" | f_json_escape)"
  exit 1
}

g_action="${1:-}"

case "$g_action" in

  # ------------------------------------------------------------------
  check)
    local f_dev f_needs="false" f_error=""
    f_dev=$(f_find_luks)
    if [[ -z "$f_dev" ]]
    then
      f_error="No LUKS device found"
    elif f_luks_is_open
    then
      f_needs="false"
    else
      f_needs="true"
    fi
    printf '{"needs_unlock":%s,"device":"%s","error":%s}\n' \
      "$f_needs" "$f_dev" "$(echo "$f_error" | f_json_escape)"
    ;;

  # ------------------------------------------------------------------
  unlock)
    local f_dev f_passphrase
    f_dev=$(f_find_luks)
    [[ -z "$f_dev" ]] && f_json_error "No LUKS device found"

    f_luks_is_open && {
      printf '{"ok":true,"message":"Already unlocked"}\n'
      exit 0
    }

    IFS= read -r f_passphrase
    [[ -z "$f_passphrase" ]] && f_json_error "Empty passphrase"

    echo "$f_passphrase" | cryptsetup open "/dev/$f_dev" "$g_mapper_name" 2>&1 || {
      f_json_error "Wrong passphrase or device error"
    }

    mkdir -p /symbios
    mount "/dev/mapper/$g_mapper_name" /symbios 2>&1 || {
      cryptsetup close "$g_mapper_name" 2>/dev/null || true
      f_json_error "Mount failed"
    }

    printf '{"ok":true,"message":"/symbios unlocked successfully"}\n'
    ;;

  # ------------------------------------------------------------------
  close)
    umount /symbios 2>/dev/null || true
    cryptsetup close "$g_mapper_name" 2>/dev/null || true
    printf '{"ok":true,"message":"/symbios unmounted and LUKS closed"}\n'
    ;;

  *)
    echo "Usage: $0 {check|unlock|close}" >&2
    exit 1
    ;;
esac
