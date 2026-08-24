#!/bin/bash

# SymbiOS autoupdate dispatcher - runs all .update scripts from autoupdate.d/
#
# Optional arguments limit the run to single modules (basename without the
# .update suffix), e.g.:
#   autoupdate.sh                  # run everything (cron default)
#   autoupdate.sh debian           # only the operating system module
#   autoupdate.sh docker symbios   # only Docker apps and SymbiOS itself
. /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
g_nice
g_lockfile
g_all-to-syslog
DISPLAY=""
set -o pipefail

# Append everything to a persistent update log for the WebUI log viewer.
# Must come after g_all-to-syslog so the tee chains into the syslog pipes.
# SYMBIOS_UPDATE_LOG tells child scripts (e.g. symbios-update.sh) that the
# log is already being written here, preventing double entries.
g_autoupdate_log="${g_log_dir}/autoupdate.log"
export SYMBIOS_UPDATE_LOG="${g_autoupdate_log}"
if mkdir -p "${g_log_dir}" 2>/dev/null || [[ -d "${g_log_dir}" ]]
then
  # Keep the growing log bounded (the cron job appends every day)
  if [[ -f "${g_autoupdate_log}" ]] && [[ "$(wc -l < "${g_autoupdate_log}")" -gt 10000 ]]
  then
    tail -n 4000 "${g_autoupdate_log}" > "${g_autoupdate_log}.tmp" \
      && mv "${g_autoupdate_log}.tmp" "${g_autoupdate_log}"
  fi
  exec > >(tee -a "${g_autoupdate_log}") 2>&1
fi

# Build the optional module filter: only .update files whose basename matches
# one of the arguments are executed (the ".update" suffix is optional).
g_only=" "
for g_arg in "$@"
do
  g_arg="${g_arg%.update}"
  g_only="${g_only}${g_arg} "
done

# Run every matching .update script; failed modules are collected so the
# status summary written at the end reflects them.
g_ran_json=""
g_failed_json=""
for g_update in $(find /usr/local/sbin/autoupdate.d ${g_data_root}/autoupdate.d ${g_git_root}/scripts/autoupdate.d -name "*.update" -type f 2>/dev/null | sort)
do
  g_module="$(basename "${g_update}" .update)"
  if [[ "${g_only// /}" != "" ]] && [[ "${g_only}" != *" ${g_module} "* ]]
  then
    continue
  fi
  g_echo "Running: $g_update"
  [[ -n "${g_ran_json}" ]] && g_ran_json="${g_ran_json}, "
  g_ran_json="${g_ran_json}\"${g_module}\""
  if ! . "$g_update"
  then
    g_echo_error "Module ${g_module} reported an error"
    [[ -n "${g_failed_json}" ]] && g_failed_json="${g_failed_json}, "
    g_failed_json="${g_failed_json}\"${g_module}\""
  fi
done

# Warn when a requested module does not exist (nothing was executed)
if [[ "${g_only// /}" != "" ]] && [[ -z "${g_ran_json}" ]]
then
  g_echo_error "No update module matched:${g_only}"
fi

# Write a small status JSON for the WebUI Updates page (read via /log mount)
if mkdir -p "${g_log_dir}" 2>/dev/null || [[ -d "${g_log_dir}" ]]
then
  printf '{"last_run": %s, "ok": %s, "modules": [%s], "failed": [%s]}\n' \
    "$(printf '%s' "$(date --iso-8601=seconds)" | f_json_escape)" \
    "$(if [[ -z "${g_failed_json}" ]]
       then
         echo true
       else
         echo false
       fi)" \
    "${g_ran_json}" \
    "${g_failed_json}" \
    > "${g_log_dir}/autoupdate-last.json.tmp" \
    && mv "${g_log_dir}/autoupdate-last.json.tmp" "${g_log_dir}/autoupdate-last.json"
fi

g_echo_note "Autoupdate finished at $(date)"

# Wind down the output chain gracefully: closing our standard outputs sends
# EOF through tee and the syslog FIFO readers, so they terminate by themselves.
# Without this, gaboshlib's exit trap SIGKILLs the still-blocked readers, which
# prints an ugly "Killed ... while read line" notice into the job/UI output.
sleep 0.2
exec 1>&- 2>&-
for i in 1 2 3 4 5 6 7 8 9 10
do
  [[ -z "$(jobs -p)" ]] && break
  sleep 0.2
done

exit ${g_rc:-0}
