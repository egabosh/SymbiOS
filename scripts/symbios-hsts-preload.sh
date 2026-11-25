#!/bin/bash
# SymbiOS - HSTS preload status, preflight and opt-in submission.
#
# The WebUI DNS setting hsts_preload enables the www.<base_domain> redirect
# provider (base-services/hsts-preload.yml) and calls `configure` once after
# the inventory write. The daily cron only refreshes the snapshot; submitting
# a domain is always an explicit opt-in action and is audit-logged.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command>

Check and submit the configured base domain to the browser HSTS preload list.
The result is written atomically to <log>/hsts-preload.json for the
symbios-healthcheck-hsts-preload.check runcheck.

Commands:
  status                Print the current snapshot
  preflight             Run local and hstspreload.org preflight checks
  submit                Preflight and submit the domain (requires opt-in)
  configure             Idempotent opt-in helper used by the DNS settings page
  run                   Daily status refresh from cron (never submits)
  -h, --help            Show this help and exit

Output: human status lines; snapshot JSON lives in <log>/hsts-preload.json.

Examples:
  $(basename "$0") preflight
  $(basename "$0") submit

Exit codes:
  0  ok, or nothing to do
  2  validation/preflight error (opt-in missing, preflight failed)
  1  technical error (API unavailable, inventory unreadable)
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

[[ -r /etc/bash/gaboshlib.include ]] && source /etc/bash/gaboshlib.include || true
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"

f_command="${1:-}"
case "${f_command}" in
  status|preflight|submit|configure|run)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_usage >&2
    exit 2
    ;;
esac
if [[ $# -gt 0 ]]
then
  echo "Unknown argument: $1" >&2
  f_usage >&2
  exit 2
fi

g_lockfile
g_api_base="https://hstspreload.org/api/v2"
g_snapshot="${g_log_dir}/hsts-preload.json"
g_tmpdir="$(mktemp -d "${g_tmp:-/tmp}/hsts-preload.XXXXXX")"
g_domain=""
g_enabled="false"

# Read the configured domain and opt-in flag. The domain guard keeps the
# installer fallback out of an external submission.
function f_hsts_load_config {
  g_domain="$(f_symbios_var base_domain "")"
  g_enabled="$(f_symbios_var hsts_preload "false")"
  case "${g_enabled,,}" in
    true|1|yes|on)
      g_enabled="true"
      ;;
    *)
      g_enabled="false"
      ;;
  esac
  if [[ -z "${g_domain}" || "${g_domain}" == "symbios.local" ]]
  then
    g_echo_error "No public base_domain configured - refusing HSTS preload"
    return 2
  fi
  return 0
}

# Call the hstspreload.org API with bounded retries for rate limits and
# transient server errors. Usage: f_hsts_api <endpoint> <domain> <out-file>
function f_hsts_api {
  local f_endpoint="$1" f_domain="$2" f_out="$3"
  local f_code f_retry=0 f_domain_enc
  f_domain_enc="$(jq -rn --arg d "${f_domain}" '$d | @uri')"
  while :
  do
    f_code="$(curl -sS -m 20 -o "${f_out}" -w '%{http_code}' \
      "${g_api_base}/${f_endpoint}?domain=${f_domain_enc}" 2>/dev/null || echo 000)"
    case "${f_code}" in
      200)
        return 0
        ;;
      429|503|529)
        if [[ "${f_retry}" -ge 3 ]]
        then
          return 1
        fi
        f_retry=$(( f_retry + 1 ))
        sleep $(( 5 * f_retry ))
        ;;
      *)
        return 1
        ;;
    esac
  done
}

# Translate an API/preflight code into a message a non-specialist can act on.
function f_hsts_explain {
  local f_code="$1"
  case "${f_code}" in
    domain.tls.cannot_connect)
      printf 'Crawler cannot reach https://%s over HTTPS.' "${g_domain}"
      ;;
    domain.www.no_tls)
      printf 'www.%s has no working HTTPS certificate.' "${g_domain}"
      ;;
    domain.http.no_redirect)
      printf 'http://%s does not redirect to HTTPS.' "${g_domain}"
      ;;
    domain.hsts.header_missing|domain.hsts.no_header)
      printf 'The HSTS header is missing on %s.' "${g_domain}"
      ;;
    domain.hsts.max_age_too_short)
      printf 'The HSTS max-age on %s is shorter than one year.' "${g_domain}"
      ;;
    domain.hsts.missing_include_subdomains_directive)
      printf 'The HSTS header on %s lacks includeSubDomains.' "${g_domain}"
      ;;
    domain.hsts.missing_preload_directive)
      printf 'The HSTS header on %s lacks preload.' "${g_domain}"
      ;;
    api.unavailable)
      printf 'hstspreload.org preflight API is unavailable.'
      ;;
    *)
      printf 'Preflight issue: %s' "${f_code}"
      ;;
  esac
}

# Run the local checks plus the external preflight API. Results are compact
# JSON arrays in g_preflight_errors / g_preflight_warnings.
function f_hsts_preflight {
  local f_local_file="${g_tmpdir}/local.json" f_api_file="${g_tmpdir}/preloadable.json"
  local f_hsts_header f_max_age f_redirect f_errors='[]'
  g_preflight_errors='[]'
  g_preflight_warnings='[]'

  # Apex must answer over HTTPS with a trusted certificate.
  if ! curl -fsS -m 15 -o /dev/null "https://${g_domain}/" >/dev/null 2>&1
  then
    f_errors="$(jq -c '. + ["domain.tls.cannot_connect"]' <<< "${f_errors}")"
  fi

  # The exact header required by the preload list: >= 1 year, subdomains,
  # preload. Traefik's secHeaders middleware normally provides all three.
  f_hsts_header="$(curl -sSI -m 15 "https://${g_domain}/" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1) == "strict-transport-security:" { print tolower($0); exit }')"
  if [[ "${f_hsts_header}" =~ max-age=([0-9]+) ]]
  then
    f_max_age="${BASH_REMATCH[1]}"
  else
    f_max_age="0"
  fi
  if (( f_max_age < 31536000 )) \
    || [[ "${f_hsts_header}" != *includesubdomains* ]] \
    || [[ "${f_hsts_header}" != *preload* ]]
  then
    f_errors="$(jq -c '. + ["domain.hsts.header_missing"]' <<< "${f_errors}")"
  fi

  # HTTP must redirect on the same host; the entrypoint redirect in
  # traefik.yml normally handles this.
  f_redirect="$(curl -sS -m 15 -o /dev/null -w '%{http_code} %{redirect_url}' \
    "http://${g_domain}/" 2>/dev/null || true)"
  if [[ ! "${f_redirect}" =~ ^(301|302|307|308)[[:space:]]+https:// ]]
  then
    f_errors="$(jq -c '. + ["domain.http.no_redirect"]' <<< "${f_errors}")"
  fi

  # The preload crawler checks www when DNS resolves it; the wildcard CNAME
  # on deSEC domains means we must provide a real TLS host there.
  if ! curl -fsS -m 15 -o /dev/null "https://www.${g_domain}/" >/dev/null 2>&1
  then
    f_errors="$(jq -c '. + ["domain.www.no_tls"]' <<< "${f_errors}")"
  fi

  printf '%s\n' "${f_errors}" >"${f_local_file}"

  if f_hsts_api "preloadable" "${g_domain}" "${f_api_file}"
  then
    g_preflight_errors="$(jq -c '[.errors[]? | if type == "string" then . else (.code // tostring) end]' "${f_api_file}" 2>/dev/null || echo '[]')"
    g_preflight_warnings="$(jq -c '[.warnings[]? | if type == "string" then . else (.code // tostring) end]' "${f_api_file}" 2>/dev/null || echo '[]')"
  else
    g_preflight_errors='["api.unavailable"]'
    g_preflight_warnings='[]'
  fi
  g_preflight_errors="$(jq -cn --argjson a "${f_errors}" --argjson b "${g_preflight_errors}" \
    '$a + $b | unique')"
}

# Write the snapshot atomically so the 5-minute runcheck never reads a
# partial file. Usage: f_hsts_write_snapshot <snapshot-status> <preload-status>
# <errors-json> <warnings-json> [technical-error]
function f_hsts_write_snapshot {
  local f_status="$1" f_preload_status="$2" f_errors="$3" f_warnings="$4"
  local f_error="${5:-}" f_tmp="${g_snapshot}.tmp.$$"
  mkdir -p "$(dirname "${g_snapshot}")"
  if jq -n \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg domain "${g_domain}" \
    --arg enabled "${g_enabled}" \
    --arg status "${f_status}" \
    --arg preload_status "${f_preload_status}" \
    --arg error "${f_error}" \
    --argjson errors "${f_errors}" \
    --argjson warnings "${f_warnings}" \
    '{generated: $generated, domain: $domain, enabled: $enabled,
      status: $status, preload_status: $preload_status, error: $error,
      errors: $errors, warnings: $warnings}' >"${f_tmp}"
  then
    mv "${f_tmp}" "${g_snapshot}"
  else
    g_echo_error "Could not write HSTS preload snapshot ${g_snapshot}"
    rm -f "${f_tmp}"
    return 1
  fi
  return 0
}

# Read the current browser-list status. The API returns a JSON string or an
# object with a status field depending on the endpoint version.
function f_hsts_status {
  local f_file="${g_tmpdir}/status.json" f_value
  if ! f_hsts_api "status" "${g_domain}" "${f_file}"
  then
    return 1
  fi
  f_value="$(jq -r 'if type == "string" then . elif type == "object" then (.status // "unknown") else "unknown" end' "${f_file}" 2>/dev/null || true)"
  if [[ -z "${f_value}" || "${f_value}" == "null" ]]
  then
    f_value="$(tr -d '\r\n"' <"${f_file}")"
  fi
  [[ -n "${f_value}" ]] || f_value="unknown"
  printf '%s' "${f_value}"
}

f_hsts_load_config || exit $?

case "${f_command}" in
  status)
    if [[ ! -s "${g_snapshot}" ]]
    then
      g_echo_error "HSTS preload snapshot missing: ${g_snapshot}"
      rm -rf "${g_tmpdir}"
      exit 1
    fi
    jq . "${g_snapshot}"
    ;;
  preflight)
    f_hsts_preflight
    g_echo "Domain: ${g_domain}"
    if [[ "$(jq 'length' <<< "${g_preflight_errors}")" -eq 0 ]]
    then
      g_echo_ok "Preflight passed"
    else
      g_echo_error "Preflight failed:"
      while IFS= read -r f_code
      do
        [[ -n "${f_code}" ]] || continue
        g_echo_error "- $(f_hsts_explain "${f_code}") (${f_code})"
      done < <(jq -r '.[]' <<< "${g_preflight_errors}")
    fi
    while IFS= read -r f_code
    do
      [[ -n "${f_code}" ]] || continue
      g_echo_warn "Warning: $(f_hsts_explain "${f_code}") (${f_code})"
    done < <(jq -r '.[]' <<< "${g_preflight_warnings}")
    f_hsts_write_snapshot "ok" "$(f_hsts_status || echo unknown)" \
      "${g_preflight_errors}" "${g_preflight_warnings}" || exit 1
    if [[ "$(jq 'length' <<< "${g_preflight_errors}")" -gt 0 ]]
    then
      rm -rf "${g_tmpdir}"
      exit 2
    fi
    ;;
  submit|configure)
    if [[ "${g_enabled}" != "true" ]]
    then
      g_echo_error "HSTS preload is not enabled - tick the checkbox in Settings -> DNS first"
      rm -rf "${g_tmpdir}"
      exit 2
    fi
    g_preflight_errors='[]'
    g_preflight_warnings='[]'
    f_hsts_preflight
    if [[ "$(jq 'length' <<< "${g_preflight_errors}")" -gt 0 ]]
    then
      g_echo_error "Refusing to submit ${g_domain}: preflight failed"
      while IFS= read -r f_code
      do
        [[ -n "${f_code}" ]] || continue
        g_echo_error "- $(f_hsts_explain "${f_code}") (${f_code})"
      done < <(jq -r '.[]' <<< "${g_preflight_errors}")
      f_hsts_write_snapshot "error" "unknown" "${g_preflight_errors}" \
        "${g_preflight_warnings}" "preflight failed" || true
      rm -rf "${g_tmpdir}"
      exit 2
    fi

    f_current_status="$(f_hsts_status || echo unknown)"
    case "${f_current_status}" in
      pending|preloaded|pending-removal|pending-automated-removal)
        g_echo_note "HSTS preload status for ${g_domain} is ${f_current_status} - no new submission"
        f_hsts_write_snapshot "ok" "${f_current_status}" "${g_preflight_errors}" \
          "${g_preflight_warnings}" || exit 1
        ;;
      *)
        # The API v2 submit endpoint takes the domain as a URL parameter,
        # not as form data. A 2xx response can still contain server-side
        # issues, so inspect the JSON before reporting success.
        f_submit_file="${g_tmpdir}/submit.txt"
        f_domain_enc="$(jq -rn --arg d "${g_domain}" '$d | @uri')"
        f_submit_code="$(curl -sS -m 20 -X POST \
          -o "${f_submit_file}" -w '%{http_code}' \
          "${g_api_base}/submit?domain=${f_domain_enc}" 2>/dev/null || echo 000)"
        case "${f_submit_code}" in
          200|201|202)
            f_submit_errors="$(jq -c '[.errors[]? | if type == "string" then . else (.code // tostring) end]' \
              "${f_submit_file}" 2>/dev/null || echo '[]')"
            f_submit_warnings="$(jq -c '[.warnings[]? | if type == "string" then . else (.code // tostring) end]' \
              "${f_submit_file}" 2>/dev/null || echo '[]')"
            g_preflight_warnings="$(jq -cn --argjson a "${g_preflight_warnings}" --argjson b "${f_submit_warnings}" \
              '$a + $b | unique')"
            if [[ "$(jq 'length' <<< "${f_submit_errors}")" -gt 0 ]]
            then
              f_submit_detail="$(jq -r '[.errors[]? | (.message // .summary // tostring)] | join("; ")' \
                "${f_submit_file}" 2>/dev/null || true)"
              g_echo_error "HSTS preload submission rejected for ${g_domain}: ${f_submit_detail}"
              f_hsts_write_snapshot "error" "${f_current_status}" "${f_submit_errors}" \
                "${g_preflight_warnings}" "submit rejected" || true
              rm -rf "${g_tmpdir}"
              exit 2
            fi
            f_already="$(jq -r '[.warnings[]? | if type == "string" then . else (.code // tostring) end] | (index("server.preload.already_pending") != null or index("server.preload.already_preloaded") != null)' \
              "${f_submit_file}" 2>/dev/null || echo false)"
            if [[ "${f_already}" == "true" ]]
            then
              g_echo_note "HSTS preload already pending for ${g_domain} - no new submission"
            else
              f_audit_event cli "hsts-preload submit" "${g_domain} http=${f_submit_code}"
              g_echo_ok "Submitted ${g_domain} to the HSTS preload list"
            fi
            f_current_status="$(f_hsts_status || echo pending)"
            # The status endpoint can lag behind a fresh submission. A
            # server-side already_pending warning is authoritative here.
            if [[ "${f_already}" == "true" && "${f_current_status}" == "unknown" ]]
            then
              f_current_status="pending"
            fi
            f_hsts_write_snapshot "ok" "${f_current_status}" "${g_preflight_errors}" \
              "${g_preflight_warnings}" || exit 1
            ;;
          *)
            f_submit_body="$(tr -d '\r\n' <"${f_submit_file}" 2>/dev/null || true)"
            g_echo_error "HSTS preload submission failed (HTTP ${f_submit_code}): ${f_submit_body}"
            f_hsts_write_snapshot "error" "${f_current_status}" "${g_preflight_errors}" \
              "${g_preflight_warnings}" "submit failed (HTTP ${f_submit_code})" || true
            rm -rf "${g_tmpdir}"
            exit 1
            ;;
        esac
        ;;
    esac
    ;;
  run)
    if [[ "${g_enabled}" != "true" ]]
    then
      f_hsts_write_snapshot "disabled" "disabled" '[]' '[]' || exit 1
      g_echo_note "HSTS preload is disabled for ${g_domain}"
      rm -rf "${g_tmpdir}"
      exit 0
    fi
    f_hsts_preflight
    f_current_status="$(f_hsts_status || echo unknown)"
    f_hsts_write_snapshot "ok" "${f_current_status}" "${g_preflight_errors}" \
      "${g_preflight_warnings}" || exit 1
    g_echo_ok "HSTS preload snapshot written to ${g_snapshot} (${f_current_status})"
    ;;
esac

rm -rf "${g_tmpdir}"
exit 0
