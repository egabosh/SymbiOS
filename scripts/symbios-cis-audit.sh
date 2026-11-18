#!/bin/bash
# SymbiOS - read-only CIS Debian 13 Level 1 Server audit (curated subset).
#
# The audit never changes the host. It writes a JSON report to <log>/cis-audit.json
# which is consumed by the healthcheck card. Waived controls must be documented
# in SECURITY.md; undocumented waivers are reported as such.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Read-only CIS benchmark audit for the curated SymbiOS control subset.
Baseline: CIS Debian Linux 13 Benchmark v1.1.0, Level 1 Server.

Commands:
  run [--json]        Run all controls, write <log>/cis-audit.json and print
                      a short summary (or the full JSON with --json).
  show                Print the cached JSON report.
  -h, --help          Show this help and exit.

Waivers are read from scripts/runchecks.d/cis-audit.conf. Every waived CIS ID
must have a row in SECURITY.md under "CIS Benchmark Scope and Deviations".

Exit codes:
  0  audit completed (findings are reported in the JSON, not the exit code)
  1  technical error (missing tool, unreadable config, write failed)
  2  usage error
EOF
}

case "${1:-}" in
  -h | --help)
    f_usage
    exit 0
    ;;
  run | show)
    g_cis_command="$1"
    shift
    ;;
  "")
    echo "Missing command (run, show or --help)." >&2
    f_usage >&2
    exit 2
    ;;
  *)
    echo "Unknown command: $1" >&2
    f_usage >&2
    exit 2
    ;;
esac

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

g_cis_conf="${g_git_root}/scripts/runchecks.d/cis-audit.conf"
g_cis_security="${g_git_root}/SECURITY.md"
g_cis_report="${g_log_dir}/cis-audit.json"
g_cis_benchmark="CIS Debian Linux 13 v1.1.0 L1 Server (curated subset)"

# Replace separators that are used by the intermediate TSV format.
function f_cis_clean {
  local f_text="$1"
  printf '%s' "$f_text" | tr '\t\n' '  ' | cut -c1-240
}

# Compare a single sysctl value with the expected value.
function f_cis_sysctl {
  local f_key="$1"
  local f_expected="$2"
  local f_actual
  f_actual="$(sysctl -n "$f_key" 2> /dev/null || true)"
  if [[ "$f_actual" == "$f_expected" ]]
  then
    printf '%s=%s' "$f_key" "$f_actual"
    return 0
  fi
  printf '%s=%s (expected %s)' "$f_key" "${f_actual:-unset}" "$f_expected"
  return 1
}

# Compare a sysctl that exists per interface (all/default/eth*/...).
function f_cis_sysctl_all {
  local f_key="$1"
  local f_expected="$2"
  local f_bad
  f_bad="$(sysctl -a 2> /dev/null \
    | awk -v key="$f_key" -v expected="$f_expected" \
        '$1 ~ ("\\." key "$") && $3 != expected {print $1 "=" $3}' \
    | head -3 | paste -sd, -)"
  if [[ -z "$f_bad" ]]
  then
    printf 'all %s=%s' "$f_key" "$f_expected"
    return 0
  fi
  printf 'deviating: %s' "$f_bad"
  return 1
}

# Check that all required options are present on a mount point.
function f_cis_mount_opts {
  local f_target="$1"
  local f_required="$2"
  local f_opts
  local f_opt
  local f_missing=""
  f_opts="$(findmnt -T "$f_target" -n -o OPTIONS 2> /dev/null | head -1)"
  for f_opt in ${f_required//,/ }
  do
    if ! grep -qw "$f_opt" <<< "$f_opts"
    then
      f_missing="${f_missing:+$f_missing,}$f_opt"
    fi
  done
  if [[ -z "$f_missing" ]]
  then
    printf '%s: %s' "$f_target" "$f_opts"
    return 0
  fi
  printf '%s missing %s (options: %s)' "$f_target" "$f_missing" "${f_opts:-none}"
  return 1
}

# Read one effective sshd setting via sshd -T (includes drop-in configs).
function f_cis_sshd {
  local f_key="$1"
  local f_expected="$2"
  local f_actual
  f_actual="$(/usr/sbin/sshd -T 2> /dev/null \
    | awk -v key="$f_key" 'tolower($1) == key {print $2; exit}')"
  if [[ "$f_actual" == "$f_expected" ]]
  then
    printf '%s=%s' "$f_key" "$f_actual"
    return 0
  fi
  printf '%s=%s (expected %s)' "$f_key" "${f_actual:-unset}" "$f_expected"
  return 1
}

# Individual controls. Each prints one result message and returns 0 on pass.
function f_cis_1_1_2 {
  f_cis_mount_opts /tmp noexec,nodev,nosuid
}

function f_cis_1_1_3 {
  f_cis_mount_opts /dev/shm noexec,nodev,nosuid
}

function f_cis_1_5_1 {
  local f_suid
  local f_limits
  f_suid="$(sysctl -n fs.suid_dumpable 2> /dev/null || true)"
  f_limits="$(grep -RhE '^[[:space:]]*\*[[:space:]]+hard[[:space:]]+core[[:space:]]+0([[:space:]]|$)' \
    /etc/security/limits.conf /etc/security/limits.d/ 2> /dev/null | head -1)"
  if [[ "$f_suid" == "0" && -n "$f_limits" ]]
  then
    printf 'fs.suid_dumpable=0, hard core limit 0'
    return 0
  fi
  printf 'fs.suid_dumpable=%s, hard core limit %s' "${f_suid:-unset}" "${f_limits:-unset}"
  return 1
}

function f_cis_1_5_2 {
  f_cis_sysctl kernel.randomize_va_space 2
}

function f_cis_3_2_1 {
  # Docker requires IP forwarding; this control is waived in the default config.
  f_cis_sysctl net.ipv4.ip_forward 0
}

function f_cis_3_2_2 {
  f_cis_sysctl_all accept_redirects 0
}

function f_cis_3_2_3 {
  f_cis_sysctl_all send_redirects 0
}

function f_cis_3_2_4 {
  f_cis_sysctl_all accept_source_route 0
}

function f_cis_3_2_5 {
  f_cis_sysctl net.ipv4.tcp_syncookies 1
}

function f_cis_4_2_1 {
  local f_status
  f_status="$(ufw status verbose 2> /dev/null)"
  if grep -q '^Status: active' <<< "$f_status" \
    && grep -q 'Default: deny (incoming)' <<< "$f_status"
  then
    printf 'ufw active, default deny (incoming)'
    return 0
  fi
  printf 'ufw is not active with default deny (incoming)'
  return 1
}

function f_cis_5_1_6 {
  f_cis_sshd x11forwarding no
}

function f_cis_5_1_7 {
  local f_value
  f_value="$(/usr/sbin/sshd -T 2> /dev/null \
    | awk 'tolower($1) == "maxauthtries" {print $2; exit}')"
  if [[ "$f_value" =~ ^[0-9]+$ && "$f_value" -le 4 ]]
  then
    printf 'MaxAuthTries=%s' "$f_value"
    return 0
  fi
  printf 'MaxAuthTries=%s (expected <= 4)' "${f_value:-unset}"
  return 1
}

function f_cis_5_1_8 {
  f_cis_sshd ignorerhosts yes
}

function f_cis_5_1_9 {
  f_cis_sshd hostbasedauthentication no
}

function f_cis_5_1_10 {
  # SymbiOS uses prohibit-password; the waiver documents the deviation from CIS "no".
  f_cis_sshd permitrootlogin no
}

function f_cis_5_1_11 {
  f_cis_sshd permitemptypasswords no
}

function f_cis_5_1_12 {
  f_cis_sshd permituserenvironment no
}

function f_cis_5_1_13 {
  local f_ssh
  local f_weak
  f_ssh="$(/usr/sbin/sshd -T 2> /dev/null)"
  f_weak="$(grep -iE '^(kexalgorithms|ciphers|macs)[[:space:]].*(diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|3des-cbc|arcfour|hmac-md5|hmac-sha1)' <<< "$f_ssh" | head -2)"
  if [[ -z "$f_weak" ]] && grep -qiE '^kexalgorithms[[:space:]]+.*curve25519' <<< "$f_ssh"
  then
    printf 'no weak Kex/Cipher/MAC algorithms'
    return 0
  fi
  printf 'weak or missing algorithm configuration: %s' "${f_weak:-incomplete}"
  return 1
}

function f_cis_5_3 {
  local f_members
  f_members="$(getent group shadow 2> /dev/null | cut -d: -f4)"
  if [[ -z "$f_members" ]]
  then
    printf 'shadow group has no members'
    return 0
  fi
  printf 'shadow group members: %s' "$f_members"
  return 1
}

function f_cis_5_4 {
  local f_empty
  f_empty="$(awk -F: '($2 == "") {print $1}' /etc/shadow 2> /dev/null | paste -sd, -)"
  if [[ -z "$f_empty" ]]
  then
    printf 'no empty password fields'
    return 0
  fi
  printf 'empty password fields: %s' "$f_empty"
  return 1
}

function f_cis_5_6 {
  local f_dir
  local f_bad=""
  local -a f_parts
  IFS=: read -ra f_parts <<< "$PATH"
  for f_dir in "${f_parts[@]}"
  do
    if [[ -z "$f_dir" || "$f_dir" == "." ]]
    then
      f_bad="${f_bad:+$f_bad,}empty-or-relative"
      continue
    fi
    if find "$f_dir" -maxdepth 0 -type d -perm -0002 2> /dev/null | grep -q .
    then
      f_bad="${f_bad:+$f_bad,}$f_dir"
    fi
  done
  if [[ -z "$f_bad" ]]
  then
    printf 'no world-writable or relative PATH entries'
    return 0
  fi
  printf 'unsafe PATH entries: %s' "$f_bad"
  return 1
}

function f_cis_6_1_1 {
  # SymbiOS uses its own audit log instead of auditd; waived by default.
  if systemctl is-enabled auditd 2> /dev/null | grep -q '^enabled$' \
    && systemctl is-active auditd 2> /dev/null | grep -q '^active$'
  then
    printf 'auditd enabled and active'
    return 0
  fi
  printf 'auditd is not enabled and active'
  return 1
}

function f_cis_6_2_1 {
  if systemctl is-active systemd-journald 2> /dev/null | grep -q '^active$'
  then
    printf 'systemd-journald active'
    return 0
  fi
  printf 'systemd-journald is not active'
  return 1
}

function f_cis_7_2_1 {
  local f_user
  local f_max
  local f_bad=""
  for f_user in $(awk -F: '($3 >= 1000 && $3 < 65534 && $1 != "nobody") {print $1}' /etc/passwd 2> /dev/null)
  do
    f_max="$(chage -l "$f_user" 2> /dev/null \
      | sed -n 's/^Maximum number of days between password change[[:space:]]*:[[:space:]]*//p')"
    if [[ ! "$f_max" =~ ^[0-9]+$ || "$f_max" -gt 365 ]]
    then
      f_bad="${f_bad:+$f_bad,}$f_user:${f_max:-unset}"
    fi
  done
  if [[ -z "$f_bad" ]]
  then
    printf 'local users have password aging <= 365 days'
    return 0
  fi
  printf 'password aging missing or too long: %s' "$f_bad"
  return 1
}

# A waived control is only acceptable when SECURITY.md carries the same ID.
function f_cis_documented {
  local f_id="$1"
  grep -Fq "| ${f_id} |" "$g_cis_security" 2> /dev/null && printf 'true' || printf 'false'
}

function f_cis_load_waivers {
  g_cis_waiver_ids=()
  [[ -r "$g_cis_conf" ]] || return 1
  command -v yq > /dev/null || return 1
  while IFS= read -r f_id
  do
    [[ -n "$f_id" ]] && g_cis_waiver_ids+=("$f_id")
  done < <(yq -r '.waivers | keys | .[]' "$g_cis_conf" 2> /dev/null)
  return 0
}

function f_cis_waiver_reason {
  local f_id="$1"
  yq -r --arg id "$f_id" '.waivers[$id]' "$g_cis_conf" 2> /dev/null
}

function f_cis_run {
  local f_json=0
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      --json)
        f_json=1
        ;;
      *)
        echo "Unknown option: $1" >&2
        f_usage >&2
        return 2
        ;;
    esac
    shift
  done

  command -v jq > /dev/null || { g_echo_error "jq is required for the CIS audit."; return 1; }
  f_cis_load_waivers || { g_echo_error "Cannot read waiver config: $g_cis_conf"; return 1; }

  g_lockfile

  # id | title | control function
  local -a g_cis_controls=(
    "1.1.2|/tmp mount options|f_cis_1_1_2"
    "1.1.3|/dev/shm mount options|f_cis_1_1_3"
    "1.5.1|Core dumps restricted|f_cis_1_5_1"
    "1.5.2|ASLR enabled|f_cis_1_5_2"
    "3.2.1|IP forwarding disabled|f_cis_3_2_1"
    "3.2.2|ICMP redirects not accepted|f_cis_3_2_2"
    "3.2.3|ICMP redirects not sent|f_cis_3_2_3"
    "3.2.4|Source routing disabled|f_cis_3_2_4"
    "3.2.5|TCP SYN cookies enabled|f_cis_3_2_5"
    "4.2.1|UFW active with default deny|f_cis_4_2_1"
    "5.1.6|SSH X11 forwarding disabled|f_cis_5_1_6"
    "5.1.7|SSH MaxAuthTries <= 4|f_cis_5_1_7"
    "5.1.8|SSH IgnoreRhosts enabled|f_cis_5_1_8"
    "5.1.9|SSH hostbased authentication off|f_cis_5_1_9"
    "5.1.10|SSH root login disabled|f_cis_5_1_10"
    "5.1.11|SSH empty passwords disabled|f_cis_5_1_11"
    "5.1.12|SSH user environment disabled|f_cis_5_1_12"
    "5.1.13|Strong SSH algorithms|f_cis_5_1_13"
    "5.3|Shadow group empty|f_cis_5_3"
    "5.4|No empty password fields|f_cis_5_4"
    "5.6|Root PATH integrity|f_cis_5_6"
    "6.1.1|auditd enabled|f_cis_6_1_1"
    "6.2.1|systemd-journald active|f_cis_6_2_1"
    "7.2.1|Password aging for local users|f_cis_7_2_1"
  )

  local f_spec
  local f_id
  local f_title
  local f_func
  local f_status
  local f_message
  local f_reason
  local f_documented
  local -a f_rows=()

  for f_spec in "${g_cis_controls[@]}"
  do
    IFS='|' read -r f_id f_title f_func <<< "$f_spec"
    f_reason=""
    f_documented="true"
    if [[ " ${g_cis_waiver_ids[*]} " == *" ${f_id} "* ]]
    then
      f_status="waived"
      f_reason="$(f_cis_waiver_reason "$f_id")"
      f_documented="$(f_cis_documented "$f_id")"
      f_message="waived: ${f_reason}"
    else
      f_message="$("$f_func" 2> /dev/null)"
      if [[ $? -eq 0 ]]
      then
        f_status="pass"
      else
        f_status="fail"
      fi
    fi
    f_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
      "$(f_cis_clean "$f_id")" \
      "$(f_cis_clean "$f_title")" \
      "$f_status" \
      "$(f_cis_clean "$f_message")" \
      "$(f_cis_clean "$f_reason")" \
      "$f_documented")")
  done

  local f_checks
  f_checks="$(printf '%s\n' "${f_rows[@]}" | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t") | {
        id: .[0],
        title: .[1],
        status: .[2],
        message: .[3],
        reason: .[4],
        documented: (.[5] == "true")
      })')" || { g_echo_error "Failed to build CIS JSON report."; return 1; }

  local f_report
  f_report="$(jq -n \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg benchmark "$g_cis_benchmark" \
    --argjson checks "$f_checks" \
    '{
      timestamp: $timestamp,
      benchmark: $benchmark,
      checks: $checks,
      summary: {
        total: ($checks | length),
        passed: ([$checks[] | select(.status == "pass")] | length),
        failed: ([$checks[] | select(.status == "fail")] | length),
        waived: ([$checks[] | select(.status == "waived")] | length),
        undocumented: ([$checks[] | select(.status == "waived" and .documented == false)] | length)
      }
    }')" || { g_echo_error "Failed to render CIS JSON report."; return 1; }

  printf '%s\n' "$f_report" > "${g_cis_report}.tmp" \
    && mv -f "${g_cis_report}.tmp" "$g_cis_report" \
    || { g_echo_error "Failed to write $g_cis_report"; return 1; }
  chmod 0644 "$g_cis_report" 2> /dev/null || true

  if [[ "$f_json" -eq 1 ]]
  then
    cat "$g_cis_report"
  else
    g_echo "CIS audit: $(jq -r '.summary.passed' "$g_cis_report")/$(jq -r '.summary.total' "$g_cis_report") passed, $(jq -r '.summary.failed' "$g_cis_report") failed, $(jq -r '.summary.waived' "$g_cis_report") waived, $(jq -r '.summary.undocumented' "$g_cis_report") undocumented."
    g_echo "Report: $g_cis_report"
  fi
  return 0
}

function f_cis_show {
  [[ -r "$g_cis_report" ]] || { g_echo_error "No CIS report yet: $g_cis_report"; return 1; }
  cat "$g_cis_report"
  return 0
}

case "$g_cis_command" in
  run)
    f_cis_run "$@"
    ;;
  show)
    if [[ $# -gt 0 ]]
    then
      echo "Unknown option: $1" >&2
      f_usage >&2
      exit 2
    fi
    f_cis_show
    ;;
esac
