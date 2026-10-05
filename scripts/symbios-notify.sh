#!/bin/bash
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# symbios-notify.sh - SymbiOS notification dispatcher (Mail + Matrix).
#
# SymbiOS port of the classic /usr/local/bin/notify.sh (see linux-setups
# debian/basics). Deployed as /usr/local/bin/notify.sh (real file copy) by
# base-services/notifications.yml, so the gaboshlib helpers g_echo_error
# and g_echo_warn deliver every warning/error automatically.
#
# Usage: <producer> | symbios-notify.sh [-s subject] [-m mail] [-t to] [-g group] [-h host]
#   -s  subject line (used for mail subject and matrix headline)
#   -m  explicit mail recipient (sent even when notify_mail_enabled is false)
#   -t  accepted for compatibility, ignored (no Signal on SymbiOS)
#   -g  accepted for compatibility, ignored (single notify room)
#   -h  accepted for compatibility, ignored (no remote relay on SymbiOS)
#
# Configuration comes from /etc/symbios-notify.conf (written by
# base-services/notifications.yml from the inventory.yml notification
# and matrix variables, no per-host notify.conf anymore):
#   notify_mail_enabled / notify_mail_to (fallback: smtp_from)
#   notify_level ('warn' = warnings + errors, 'error' = errors only)
#   notify_matrix_enabled (delivery into the matrix-client FIFO)
#
# Design notes:
# - No g_echo_error/g_echo_warn in here: this script IS the gaboshlib
#   notify backend, using them would loop back into itself.
# - No g_lockfile: it exits when another instance runs, which would drop
#   concurrent notifications. FIFO writes below PIPE_BUF are atomic and
#   mail sends are independent, so no lock is needed.
# - The FIFO open-for-write blocks while the matrix-client daemon is down;
#   it is wrapped in timeout so a dead daemon can never stall the caller
#   (e.g. a postfix pipe for root mails).

# Message comes from stdin (gaboshlib pipes the log line, postfix the mail).
f_message="$(cat)"
f_orig_message="${f_message}"
[ "${f_message}" = "''" ] && exit 0
[ -z "${f_message}" ] && exit 0

while getopts s:t:g:h:m: f_o
do
  case "${f_o}" in
    s) f_subj="${OPTARG}";;
    t) f_to="${OPTARG}";;
    g) f_togroup="${OPTARG}";;
    h) f_tohost="${OPTARG}";;
    m) f_tomail="${OPTARG}";;
  esac
done

# Read notification config. Primary source is /etc/symbios-notify.conf
# (world-readable, written by base-services/notifications.yml) because the
# postfix root alias executes this script as an unprivileged user that
# cannot read the 0600 inventory.yml. Fallback is symbios-lib (root runs).
if [[ -r /etc/symbios-notify.conf ]]
then
  # shellcheck disable=SC1091
  source /etc/symbios-notify.conf
  f_mail_enabled="${notify_mail_enabled:-false}"
  f_mail_to="${notify_mail_to:-}"
  f_level="${notify_level:-warn}"
  f_matrix_enabled="${notify_matrix_enabled:-false}"
  f_fifo="${notify_fifo:-/usr/local/share/matrix-room-notify.fifo}"
elif command -v symbios-lib.sh >/dev/null 2>&1
then
  source symbios-lib.sh
  f_mail_enabled="$(f_symbios_var notify_mail_enabled "false")"
  f_mail_to="$(f_symbios_var notify_mail_to "")"
  [ -z "${f_mail_to}" ] && f_mail_to="$(f_symbios_var smtp_from "")"
  f_level="$(f_symbios_var notify_level "warn")"
  f_matrix_enabled="$(f_symbios_var notify_matrix_enabled "false")"
  f_fifo="/usr/local/share/matrix-room-notify.fifo"
else
  f_mail_enabled="false"
  f_mail_to=""
  f_level="warn"
  f_matrix_enabled="false"
  f_fifo="/usr/local/share/matrix-room-notify.fifo"
fi

# Severity of this message: gaboshlib prefixes piped lines with
# "ERROR:" or "WARNING:". System mails carry no prefix and always pass.
f_sev="info"
if [[ "${f_message}" == *"ERROR:"* ]]
then
  f_sev="error"
elif [[ "${f_message}" == *"WARNING:"* ]]
then
  f_sev="warn"
fi
if [[ "${f_sev}" == "warn" && "${f_level}" == "error" ]]
then
  exit 0
fi

f_rc=0

# --- Mail (via local postfix relay from base-services/smtp.yml) ---
# Loop guard: when the recipient routes back through the notifying alias
# (e.g. notify_mail_to=root), the piped message carries our own marker
# header and must not be mailed again. Matrix delivery has no re-entry
# path and is unaffected.
if printf '%s' "${f_message}" | grep -qi '^X-SymbiOS-Notify:'
then
  f_mail_loop=1
else
  f_mail_loop=0
fi
if [[ "${f_mail_loop}" -eq 0 && ( -n "${f_tomail:-}" || "${f_mail_enabled}" == "true" ) ]]
then
  f_recipients=""
  [[ -n "${f_tomail:-}" ]] && f_recipients="${f_tomail}"
  if [[ "${f_mail_enabled}" == "true" && -n "${f_mail_to}" ]]
  then
    [[ -n "${f_recipients}" ]] && f_recipients="${f_recipients} ${f_mail_to}" || f_recipients="${f_mail_to}"
  fi
  if [[ -n "${f_recipients}" ]]
  then
    # Header-safe subject (no CR/LF injection into sendmail headers).
    f_safe_subj="${f_subj:-notification}"
    f_safe_subj="${f_safe_subj//$'\n'/ }"
    f_safe_subj="${f_safe_subj//$'\r'/ }"
    # Absolute paths: the postfix alias pipe runs with a minimal PATH.
    # sendmail instead of mail(1) so the loop-guard header above survives
    # (sender_canonical rewriting to smtp_from still applies).
    f_env_to="${f_recipients// /,}"
    {
      printf 'From: root\nTo: %s\nSubject: SymbiOS notify: %s\nX-SymbiOS-Notify: 1\n\n' \
        "${f_env_to}" "${f_safe_subj}"
      printf '%s\n' "${f_message}"
      # shellcheck disable=SC2086
    } | /usr/sbin/sendmail -oi ${f_env_to}
    if [[ "${PIPESTATUS[1]:-1}" -ne 0 ]]
    then
      echo "symbios-notify.sh: mail delivery failed" >&2
      f_rc=1
    fi
  elif [[ -n "${f_tomail:-}" || "${f_mail_enabled}" == "true" ]]
  then
    echo "symbios-notify.sh: mail requested but no recipient configured" >&2
    f_rc=1
  fi
fi

# --- Matrix (E2EE via the matrix-client pipes-runner daemon) ---
if [[ "${f_matrix_enabled}" == "true" ]]
then
  if [[ -p "${f_fifo}" ]]
  then
    # Minimal HTML escaping for the matrix headline/body wrapper.
    f_esc_subj="$(printf '%s' "${f_subj:-SymbiOS notification}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    f_esc_msg="$(printf '%s' "${f_orig_message}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    f_matrix_message="<h3>${f_esc_subj}</h3><pre>${f_esc_msg}</pre>"
    if ! printf '%s' "${f_matrix_message}" | /usr/bin/perl -pe 's/\n/<br>/g' | /usr/bin/timeout 10 bash -c "cat > \"${f_fifo}\""
    then
      echo "symbios-notify.sh: matrix delivery failed (daemon down?)" >&2
      f_rc=1
    fi
  else
    echo "symbios-notify.sh: matrix requested but ${f_fifo} missing (matrix-client not running?)" >&2
    f_rc=1
  fi
fi

exit "${f_rc}"
