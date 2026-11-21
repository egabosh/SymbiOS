#!/bin/bash
# SymbiOS - Configure the Nextcloud AI providers from the SymbiOS inventory.
#
# Nextcloud talks to the SymbiOS AI endpoints (Settings -> AI and
# Settings -> AI Speech) through the apps "assistant" (UI) and
# "integration_openai" (provider for the core Task Processing types:
# text generation, translation, speech to text, text to speech).
#
# The apps read their configuration from the Nextcloud app config, not from
# the inventory, so this script reconciles the app config with the values
# ai_server, ai_apikey, ai_stt_* and ai_tts_* on every playbook run.
# Only differences are written, so a converged host reports "unchanged".
#
# Runs from services/nextcloud.yml (after nextcloud.init.sh).

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--check]

Configure the Nextcloud AI providers (app integration_openai) from the
SymbiOS inventory values ai_server, ai_apikey, ai_stt_url, ai_stt_key,
ai_stt_model, ai_tts_url, ai_tts_key and ai_tts_model.

Mapped app config keys:
  ai_server          -> url
  ai_apikey          -> api_key
  ai_server/models   -> default_completion_model_id (first advertised model)
  ai_stt_url         -> stt_url, stt_api_key (ai_stt_key or ai_apikey)
  ai_stt_model       -> default_stt_model_id
  ai_tts_url         -> tts_url, tts_api_key (ai_tts_key or ai_apikey)
  ai_tts_model       -> default_speech_model_id
  -                  -> request_timeout/stt_request_timeout/tts_request_timeout=300

An empty endpoint disables its provider and removes url and key, so the
Assistant does not offer task types that cannot run. Image generation stays
off (the AI host has no OpenAI compatible image endpoint), and the sticker
task type of the assistant app is disabled with it.

The completion model has to be a model the AI server advertises: the app
fills the "model" field of every task with its admin default and validates
it against the live model list, so a default outside that list makes the
Assistant reject every task with HTTP 400. The model list is only read, the
key stays untouched while the AI server is unreachable (compute.lan
suspends when idle).

Options:
  --check             Report what would change, write nothing
  -h, --help          Show this help and exit

Output: one line per key ("<key>: changed|unchanged"), a final line
"nextcloud-ai-changed", "nextcloud-ai-unchanged" or "nextcloud-ai-error".

Exit codes: 0 = ok (changed or unchanged), 1 = technical error, 2 = usage error.
EOF
}

# Defaults and argument parsing
g_check=0
g_changed=0
g_failed=0

while [[ $# -gt 0 ]]
do
  case "$1" in
    -h|--help)
      f_usage
      exit 0
      ;;
    --check)
      g_check=1
      shift
      ;;
    *)
      f_usage >&2
      exit 2
      ;;
  esac
done

# Source shared libraries (absolute paths so a bare cron/PATH call works)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /etc/bash/gaboshlib.include ]]
then
  source /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

# Run occ inside the Nextcloud container
function f_occ {
  docker compose -f "${g_services_root}/nextcloud/docker-compose.yml" \
    exec -T -u www-data nextcloud ./occ "$@"
}

# Read one integration_openai app config key (empty when unset)
function f_app_config_get {
  local f_key="$1"
  local f_value

  f_value=$(f_occ config:app:get integration_openai "$f_key" 2>/dev/null) || f_value=""
  printf '%s' "$f_value"
}

# Write one key only when it differs from the desired value.
# An empty desired value removes the key (no stale secret stays behind).
function f_set_key {
  local f_key="$1"
  local f_value="$2"
  local f_sensitive="${3:-0}"
  local f_current f_rc

  f_current=$(f_app_config_get "$f_key")
  if [[ "$f_current" == "$f_value" ]]
  then
    g_echo_note "${f_key}: unchanged"
    return 0
  fi

  # Dry run: report the difference, change nothing
  if [[ $g_check -eq 1 ]]
  then
    g_echo_note "${f_key}: would change"
    g_changed=1
    return 0
  fi

  # Empty value: delete the key instead of storing an empty string
  if [[ -z "$f_value" ]]
  then
    f_occ config:app:delete integration_openai "$f_key" >/dev/null 2>&1
    f_rc=$?
  elif [[ "$f_sensitive" == "1" ]]
  then
    f_occ config:app:set integration_openai "$f_key" "--value=${f_value}" --sensitive >/dev/null 2>&1
    f_rc=$?
  else
    f_occ config:app:set integration_openai "$f_key" "--value=${f_value}" >/dev/null 2>&1
    f_rc=$?
  fi

  if [[ $f_rc -ne 0 ]]
  then
    g_echo_error "${f_key}: failed"
    g_failed=1
    return 1
  fi

  g_echo_note "${f_key}: changed"
  g_changed=1
  return 0
}

# Read the first model id the AI server advertises. The Task Processing
# "model" enum of integration_openai is exactly this list, so the admin
# default has to be one of these ids.
function f_ai_model {
  local f_url="$1"
  local f_key="$2"
  local f_body f_data f_rest

  if [[ -z "$f_url" || -z "$f_key" ]]
  then
    return 1
  fi

  # The key stays out of argv (ps): curl reads the header from stdin
  f_body=$(printf 'header = "Authorization: Bearer %s"\n' "$f_key" \
    | curl -sf --max-time 10 --config - "${f_url%/}/models" 2>/dev/null) || return 1

  # First "id" of the "data" list, without a JSON parser
  f_data="${f_body#*\"data\":}"
  if [[ "$f_data" == "$f_body" ]]
  then
    return 1
  fi
  f_rest="${f_data#*\"id\":\"}"
  if [[ "$f_rest" == "$f_data" ]]
  then
    return 1
  fi

  printf '%s' "${f_rest%%\"*}"
}

# Disable one Task Processing task type. The state lives in the core app
# config as a JSON map, so the current value is checked before the command
# runs (keeps a converged host at "unchanged").
function f_disable_task_type {
  local f_type="$1"
  local f_json

  f_json=$(f_occ config:app:get core ai.taskprocessing_type_preferences 2>/dev/null) || f_json=""
  if [[ "$f_json" == *"\"${f_type}\":false"* ]]
  then
    g_echo_note "task type ${f_type}: unchanged"
    return 0
  fi

  if [[ $g_check -eq 1 ]]
  then
    g_echo_note "task type ${f_type}: would change"
    g_changed=1
    return 0
  fi

  if ! f_occ taskprocessing:task-type:set-enabled "$f_type" 0 >/dev/null 2>&1
  then
    g_echo_error "task type ${f_type}: failed"
    g_failed=1
    return 1
  fi

  g_echo_note "task type ${f_type}: changed"
  g_changed=1
  return 0
}

# Reconcile the app config with the inventory
function f_nextcloud_ai {
  local f_ai_server f_ai_apikey f_model
  local f_stt_url f_stt_key f_stt_model
  local f_tts_url f_tts_key f_tts_model
  local f_apps

  # Nothing to do when Nextcloud is not installed
  if [[ ! -f "${g_services_root}/nextcloud/docker-compose.yml" ]]
  then
    return 0
  fi

  # The provider app only exists when this host configured an AI endpoint at
  # install time (services/nextcloud.yml installs it conditionally)
  f_apps=$(f_occ app:list 2>/dev/null) || f_apps=""
  if [[ "$f_apps" != *"integration_openai:"* ]]
  then
    g_echo_note "integration_openai is not installed - nothing to configure"
    return 0
  fi

  # Inventory values (read on the host, never passed as argv)
  f_ai_server=$(f_symbios_var ai_server)
  f_ai_apikey=$(f_secret_var ai_apikey)
  f_stt_url=$(f_symbios_var ai_stt_url)
  f_stt_key=$(f_secret_var ai_stt_key)
  f_stt_model=$(f_symbios_var ai_stt_model)
  f_tts_url=$(f_symbios_var ai_tts_url)
  f_tts_key=$(f_secret_var ai_tts_key)
  f_tts_model=$(f_symbios_var ai_tts_model)

  # Speech keys have no fallback to api_key inside the app
  if [[ -z "$f_stt_key" ]]
  then
    f_stt_key="$f_ai_apikey"
  fi
  if [[ -z "$f_tts_key" ]]
  then
    f_tts_key="$f_ai_apikey"
  fi

  # Text generation and translation (chat, summarize, headline, ...)
  if [[ -n "$f_ai_server" ]]
  then
    f_set_key url "$f_ai_server"
    f_set_key api_key "$f_ai_apikey" 1
    f_set_key request_timeout 300
    f_set_key llm_provider_enabled 1

    # The app's admin default model becomes the "model" value of every task
    # and is validated against the model list of the AI server, so it has to
    # be a model that server really serves
    f_model=$(f_ai_model "$f_ai_server" "$f_ai_apikey") || f_model=""
    if [[ -n "$f_model" ]]
    then
      f_set_key default_completion_model_id "$f_model"
    else
      g_echo_warn "AI server model list not readable - default_completion_model_id left unchanged"
    fi
  else
    f_set_key llm_provider_enabled 0
    f_set_key url ""
    f_set_key api_key "" 1
  fi

  # Image generation stays off: the AI host runs ComfyUI, which has no
  # OpenAI compatible /images/generations endpoint. The sticker task type of
  # the assistant app needs text to image, so it would only fail after the
  # user submitted it - keep it out of the Assistant menu.
  f_set_key t2i_provider_enabled 0
  if [[ "$f_apps" == *"assistant:"* ]]
  then
    f_disable_task_type "assistant:text2sticker"
  fi

  # Speech to text (dictation, recording transcription in Talk)
  if [[ -n "$f_stt_url" ]]
  then
    f_set_key stt_url "$f_stt_url"
    f_set_key stt_api_key "$f_stt_key" 1
    f_set_key stt_request_timeout 300
    f_set_key stt_provider_enabled 1
    if [[ -n "$f_stt_model" ]]
    then
      f_set_key default_stt_model_id "$f_stt_model"
    fi
  else
    f_set_key stt_provider_enabled 0
    f_set_key stt_url ""
    f_set_key stt_api_key "" 1
  fi

  # Text to speech (Assistant reads text aloud)
  if [[ -n "$f_tts_url" ]]
  then
    f_set_key tts_url "$f_tts_url"
    f_set_key tts_api_key "$f_tts_key" 1
    f_set_key tts_request_timeout 300
    f_set_key tts_provider_enabled 1
    if [[ -n "$f_tts_model" ]]
    then
      f_set_key default_speech_model_id "$f_tts_model"
    fi
  else
    f_set_key tts_provider_enabled 0
    f_set_key tts_url ""
    f_set_key tts_api_key "" 1
  fi

  return 0
}

f_nextcloud_ai
f_rc=$?

# Final state token for changed_when in the playbook
if [[ $g_failed -ne 0 || $f_rc -ne 0 ]]
then
  echo "nextcloud-ai-error"
  exit 1
fi
if [[ $g_changed -ne 0 ]]
then
  echo "nextcloud-ai-changed"
else
  echo "nextcloud-ai-unchanged"
fi
exit 0
