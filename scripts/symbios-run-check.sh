#!/bin/bash
# SymbiOS - Run a single health check and output JSON result.
# Used by the WebUI to allow on-demand re-checking of individual checks.
#
# Usage: symbios-run-check.sh <check-name>
#   <check-name>   The check name as shown in the health UI (e.g. "df", "ssl", "containers")
#
# Output: JSON on stdout with fields: name, status, message, title, desc, detail, category, script

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

# Find the .check file for a given name
function f_find_check {
  local f_name="$1"
  for f_dir in /usr/local/sbin/runchecks.d "${g_git_root}/scripts/runchecks.d"
  do
    if [[ -f "${f_dir}/${f_name}.check" ]]
    then
      echo "${f_dir}/${f_name}.check"
      return 0
    fi
    if [[ -f "${f_dir}/symbios-healthcheck-${f_name}.check" ]]
    then
      echo "${f_dir}/symbios-healthcheck-${f_name}.check"
      return 0
    fi
  done
  return 1
}

# JSON-escape a string
function f_jescape {
  echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

# --- Main ---

if [[ -z "$1" ]]
then
  echo '{"error":"Usage: symbios-run-check.sh <check-name>"}'
  exit 1
fi

g_check_name="$1"
g_check_file=$(f_find_check "$g_check_name")

if [[ -z "$g_check_file" ]]
then
  echo '{"name":"'"$(f_jescape "$g_check_name")"'","status":"error","message":"Check not found: '"$(f_jescape "$g_check_name")"'"}'
  exit 1
fi

# Override g_echo_error to capture failures (same as runchecks.sh)
function g_echo_error {
  g_current_check_failed=1
  g_current_check_error="$*"
}

g_current_check_failed=0
g_current_check_error=""

# Run check in subshell - bypasses f_check_cache, captures output
g_check_output=$( {
  . "$g_check_file"
} 2>&1 )
g_exit=$?

# Extract metadata from the check file
g_title=$(grep '^CHECK_TITLE=' "$g_check_file" 2>/dev/null | head -1 | sed 's/^CHECK_TITLE=//; s/^"//; s/"$//')
g_desc=$(grep '^CHECK_DESC=' "$g_check_file" 2>/dev/null | head -1 | sed 's/^CHECK_DESC=//; s/^"//; s/"$//')
g_detail=$(grep '^CHECK_DETAIL=' "$g_check_file" 2>/dev/null | head -1 | sed 's/^CHECK_DETAIL=//; s/^"//; s/"$//')
g_category=$(grep '^CHECK_CATEGORY=' "$g_check_file" 2>/dev/null | head -1 | sed 's/^CHECK_CATEGORY=//; s/^"//; s/"$//')

# JSON-escape all metadata
g_title=$(f_jescape "$g_title")
g_desc=$(f_jescape "$g_desc")
g_detail=$(f_jescape "$g_detail")
g_category=$(f_jescape "$g_category")

# Determine status
if [[ "$g_current_check_failed" -eq 1 ]]
then
  g_status="error"
  g_msg=$(f_jescape "$g_current_check_error")
else
  g_status="ok"
  g_msg=""
fi

g_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf '{"name":"%s","status":"%s","message":"%s","title":"%s","desc":"%s","detail":"%s","category":"%s","script":"%s","checked":"%s"}\n' \
  "$(f_jescape "$g_check_name")" \
  "$g_status" \
  "$g_msg" \
  "$g_title" \
  "$g_desc" \
  "$g_detail" \
  "$g_category" \
  "$(f_jescape "$g_check_file")" \
  "$g_ts"
