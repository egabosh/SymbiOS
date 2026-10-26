#!/bin/bash
# SymbiOS - Hermes Agent runtime configuration via docker exec.
#
# The LLM provider is written into hermes' own config.yaml through the
# `hermes config set` CLI inside the container, so hermes stays the single
# writer of its config (the playbook must not edit the file directly).
# Values travel via environment (HERMES_LLM_*), never as argv. The subcommand
# prints a machine-readable token as its last line for Ansible changed_when:
#   llm    sync the local-llm provider from Settings -> AI
#          (prints hermes-agent-llm-changed | hermes-agent-llm-unchanged)

function f_usage {
  cat << EOF
Usage: $(basename "$0") <subcommand>

  llm    Sync the local-llm LLM provider in the hermes container from
         HERMES_LLM_BASE_URL (required), HERMES_LLM_API_KEY, optional
         HERMES_LLM_PROVIDER (default local-llm) and HERMES_LLM_MODEL
         (default llamacpp-default).

Output: last line is a machine-readable token:
  hermes-agent-llm-changed    provider settings were updated
  hermes-agent-llm-unchanged  settings already match

Exit codes: 0 ok, 1 technical error (container not ready), 2 validation error.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
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

# Container name (see services/hermes-agent.yml)
g_container="symbios-hermes-agent"

function f_hermes_config {
  # Run a hermes config subcommand inside the container (hermes config get/set).
  # The image's exec shim drops to the hermes user, so files under /opt/data
  # get correct ownership.
  local f_cmd=("$@")
  docker exec "${g_container}" /opt/hermes/.venv/bin/hermes config "${f_cmd[@]}"
}

function f_hermes_get {
  # Read one resolved config value; empty output means unset. --raw keeps
  # api_key-shaped values unmasked so the drift comparison works.
  f_hermes_config get "$1" --raw 2>/dev/null || true
}

function f_apply_llm {
  # Apply all provider values in one batch. A failure here usually means the
  # container is not ready yet (stage2 has not chowned /opt/data).
  local f_provider="${HERMES_LLM_PROVIDER:-local-llm}"
  local f_model="${HERMES_LLM_MODEL:-llamacpp-default}"
  f_hermes_config set "providers.${f_provider}.base_url" "${HERMES_LLM_BASE_URL}" || return 1
  f_hermes_config set "providers.${f_provider}.api_key" "${HERMES_LLM_API_KEY:-}" || return 1
  f_hermes_config set "model.provider" "${f_provider}" || return 1
  f_hermes_config set "model.default" "${f_provider}/${f_model}" || return 1
  # Clear a model-level base_url so the provider-level one applies.
  f_hermes_config set "model.base_url" "" || return 1
  # Give local LLMs (and WoL wake-ups) more headroom for the first response;
  # best effort because the key may not exist in every hermes version.
  f_hermes_config set "model.timeout" 180 || g_echo_warn "model.timeout not accepted by this hermes version (skipped)"
}

function f_sync_llm {
  local f_provider="${HERMES_LLM_PROVIDER:-local-llm}"
  local f_model="${HERMES_LLM_MODEL:-llamacpp-default}"
  local f_base_url="${HERMES_LLM_BASE_URL:-}"
  local f_api_key="${HERMES_LLM_API_KEY:-}"
  local f_wait=0
  local f_cur f_key f_want f_changed=0

  if [[ -z "${f_base_url}" ]]
  then
    g_echo_error "HERMES_LLM_BASE_URL is empty (Settings -> AI: ai_server)"
    return 2
  fi

  # Wait until the container is running and the hermes CLI answers. The full
  # apply below doubles as the readiness probe for a writable /opt/data.
  while ! docker exec "${g_container}" /opt/hermes/.venv/bin/hermes --version >/dev/null 2>&1
  do
    f_wait=$((f_wait + 1))
    if [[ ${f_wait} -ge 60 ]]
    then
      g_echo_error "hermes container '${g_container}' did not become ready within 300s"
      return 1
    fi
    sleep 5
  done

  # Compare resolved values with the desired ones; apply only on drift so a
  # second run is a no-op (no config rewrite, no restart needed).
  for f_pair in "providers.${f_provider}.base_url|${f_base_url}" \
                "providers.${f_provider}.api_key|${f_api_key}" \
                "model.provider|${f_provider}" \
                "model.default|${f_provider}/${f_model}"
  do
    f_key="${f_pair%%|*}"
    f_want="${f_pair#*|}"
    f_cur="$(f_hermes_get "${f_key}")"
    if [[ "${f_cur}" != "${f_want}" ]]
    then
      f_changed=1
      break
    fi
  done

  # A model-level base_url must stay empty (provider-level one applies).
  if [[ -n "$(f_hermes_get "model.base_url")" ]]
  then
    f_changed=1
  fi

  if [[ ${f_changed} -eq 0 ]]
  then
    echo "hermes-agent-llm-unchanged"
    return 0
  fi

  # Apply with retries: the first run can race with stage2 (volume chown).
  f_wait=0
  while ! f_apply_llm
  do
    f_wait=$((f_wait + 1))
    if [[ ${f_wait} -ge 60 ]]
    then
      g_echo_error "could not apply the LLM provider config to '${g_container}'"
      return 1
    fi
    sleep 5
  done

  echo "hermes-agent-llm-changed"
}

case "${1:-}" in
  llm)
    f_sync_llm
    ;;
  *)
    g_echo_error "unknown subcommand: ${1:-<none>}"
    f_usage
    exit 1
    ;;
esac
