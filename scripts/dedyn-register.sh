#!/bin/bash

# deSEC account registration and API token management
# Usage:
#   dedyn-register.sh captcha
#   dedyn-register.sh register <email> <password> [domain]
#   dedyn-register.sh register-with-captcha <email> <password> <captcha_id> <captcha_solution> [domain]
#   dedyn-register.sh login <email> <password>
#   dedyn-register.sh create-token <email> <password> [name]
#   dedyn-register.sh create-domain <token> <domain>
#   dedyn-register.sh setup <email> <password> [domain]
#   dedyn-register.sh activate <code> [captcha_id captcha_solution]
#   dedyn-register.sh check-activation <email> <password>

g_desec_base="https://desec.io/api/v1"

# Source gaboshlib
. /etc/bash/gaboshlib.include

function f_usage {
  echo "Usage:"
  echo "  $0 captcha"
  echo "  $0 register <email> <password> [domain]"
  echo "  $0 register-with-captcha <email> <password> <captcha_id> <captcha_solution> [domain]"
  echo "  $0 login <email> <password>"
  echo "  $0 create-token <email> <password> [name]"
  echo "  $0 create-domain <token> <domain>"
  echo "  $0 setup <email> <password> [domain]"
  echo "  $0 activate <code> [captcha_id captcha_solution]"
  echo "  $0 check-activation <email> <password>"
}

function f_request {
  local f_method="$1"
  local f_url="$2"
  local f_auth="$3"
  local f_data="$4"
  local f_headers="Content-Type: application/json"
  if [[ -n "${f_auth}" ]]
  then
    f_headers="${f_headers}\nAuthorization: Token ${f_auth}"
  fi
  if [[ -n "${f_data}" ]]
  then
    curl -s -X "${f_method}" "${f_url}" \
      --header "Content-Type: application/json" \
      ${f_auth:+--header "Authorization: Token ${f_auth}"} \
      --data "${f_data}" \
      -w "\n%{http_code}"
  else
    curl -s -X "${f_method}" "${f_url}" \
      --header "Content-Type: application/json" \
      ${f_auth:+--header "Authorization: Token ${f_auth}"} \
      -w "\n%{http_code}"
  fi
}

function f_captcha {
  local f_response
  f_response=$(curl -s -X POST "${g_desec_base}/captcha/" \
    --header "Content-Type: application/json" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "201" ]]
  then
    echo "${f_body}"
    return 0
  else
    g_echo_error "Failed to get captcha (HTTP ${f_http_code}): ${f_body}"
    return 1
  fi
}

function f_register {
  local f_email="$1"
  local f_password="$2"
  local f_domain="${3:-}"
  local f_captcha_id="${4:-}"
  local f_captcha_solution="${5:-}"
  local f_data
  if [[ -n "${f_captcha_id}" ]] && [[ -n "${f_captcha_solution}" ]]
  then
    if [[ -n "${f_domain}" ]]
    then
      f_data=$(jq -n --arg email "${f_email}" --arg pass "${f_password}" \
        --arg cid "${f_captcha_id}" --arg csol "${f_captcha_solution}" \
        --arg dom "${f_domain}" \
        '{email: $email, password: $pass, captcha: {id: $cid, solution: $csol}, domain: $dom}')
    else
      f_data=$(jq -n --arg email "${f_email}" --arg pass "${f_password}" \
        --arg cid "${f_captcha_id}" --arg csol "${f_captcha_solution}" \
        '{email: $email, password: $pass, captcha: {id: $cid, solution: $csol}}')
    fi
  else
    if [[ -n "${f_domain}" ]]
    then
      f_data=$(jq -n --arg email "${f_email}" --arg pass "${f_password}" \
        --arg dom "${f_domain}" \
        '{email: $email, password: $pass, domain: $dom}')
    else
      f_data=$(jq -n --arg email "${f_email}" --arg pass "${f_password}" \
        '{email: $email, password: $pass}')
    fi
  fi
  local f_response
  f_response=$(curl -s -X POST "${g_desec_base}/auth/" \
    --header "Content-Type: application/json" \
    --data "${f_data}" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "202" ]]
  then
    g_echo_ok "Account registration initiated for ${f_email}"
    echo "${f_body}"
    return 0
  else
    g_echo_error "Registration failed (HTTP ${f_http_code}): ${f_body}"
    echo "${f_body}"
    return 1
  fi
}

function f_login {
  local f_email="$1"
  local f_password="$2"
  local f_data
  f_data=$(jq -n --arg email "${f_email}" --arg pass "${f_password}" \
    '{email: $email, password: $pass}')
  local f_response
  f_response=$(curl -s -X POST "${g_desec_base}/auth/login/" \
    --header "Content-Type: application/json" \
    --data "${f_data}" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "200" ]]
  then
    echo "${f_body}"
    return 0
  else
    g_echo_error "Login failed (HTTP ${f_http_code})"
    echo "${f_body}"
    return 1
  fi
}

function f_create_token {
  local f_login_token="$1"
  local f_name="${2:-symbios-ddns}"
  local f_data
  f_data=$(jq -n --arg name "${f_name}" \
    '{name: $name, perm_create_domain: true, perm_delete_domain: true, perm_manage_tokens: false, max_unused_period: "36500 00:00:00"}')
  local f_response
  f_response=$(curl -s -X POST "${g_desec_base}/auth/tokens/" \
    --header "Content-Type: application/json" \
    --header "Authorization: Token ${f_login_token}" \
    --data "${f_data}" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "201" ]]
  then
    echo "${f_body}"
    return 0
  else
    g_echo_error "Token creation failed (HTTP ${f_http_code}): ${f_body}"
    echo "${f_body}"
    return 1
  fi
}

function f_create_domain {
  local f_token="$1"
  local f_domain="$2"
  local f_data
  f_data=$(jq -n --arg dom "${f_domain}" '{name: $dom}')
  local f_response
  f_response=$(curl -s -X POST "${g_desec_base}/domains/" \
    --header "Content-Type: application/json" \
    --header "Authorization: Token ${f_token}" \
    --data "${f_data}" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "201" ]]
  then
    g_echo_ok "Domain ${f_domain} created"
    echo "${f_body}"
    return 0
  else
    g_echo_error "Domain creation failed (HTTP ${f_http_code}): ${f_body}"
    echo "${f_body}"
    return 1
  fi
}

function f_activate {
  local f_code="$1"
  local f_captcha_id="${2:-}"
  local f_captcha_solution="${3:-}"
  local f_data="{}"
  if [[ -n "${f_captcha_id}" ]] && [[ -n "${f_captcha_solution}" ]]
  then
    f_data=$(jq -n --arg cid "${f_captcha_id}" --arg csol "${f_captcha_solution}" \
      '{captcha: {id: $cid, solution: $csol}}')
  fi
  local f_response
  f_response=$(curl -s -X POST \
    "https://desec.io/api/v1/v/activate-account/${f_code}/" \
    --header "Content-Type: application/json" \
    --data "${f_data}" \
    -w "\n%{http_code}")
  local f_http_code
  f_http_code=$(echo "${f_response}" | tail -1)
  local f_body
  f_body=$(echo "${f_response}" | sed '$d')
  if [[ "${f_http_code}" == "200" ]]
  then
    g_echo_ok "Account activated successfully"
    echo "${f_body}"
    return 0
  else
    g_echo_error "Activation failed (HTTP ${f_http_code}): ${f_body}"
    echo "${f_body}"
    return 1
  fi
}

function f_check_activation {
  local f_email="$1"
  local f_password="$2"
  if f_login "${f_email}" "${f_password}" >/dev/null 2>&1
  then
    g_echo_ok "Account is active (login succeeded)"
    return 0
  else
    g_echo_note "Account not yet activated (login failed)"
    return 1
  fi
}

function f_setup {
  local f_email="$1"
  local f_password="$2"
  local f_domain="${3:-}"
  local f_register_output
  local f_login_token
  local f_token_data
  local f_api_token
  local f_domain_name

  # Step 1: Register (no captcha)
  g_echo_note "Step 1/4: Registering account for ${f_email}..."
  f_register_output=$(f_register "${f_email}" "${f_password}" "${f_domain}" 2>&1)
  local f_rv=$?
  if [[ "${f_rv}" -ne 0 ]]
  then
    g_echo_error "Registration failed"
    echo "${f_register_output}"
    return 1
  fi
  g_echo_ok "Registration initiated. Check your email for the verification link."

  # Step 2: Wait for activation (polling loop)
  g_echo_note "Step 2/4: Waiting for email verification..."
  local f_attempts=0
  local f_max_attempts=60
  while [[ "${f_attempts}" -lt "${f_max_attempts}" ]]
  do
    if f_check_activation "${f_email}" "${f_password}" >/dev/null 2>&1
    then
      g_echo_ok "Account activated!"
      break
    fi
    f_attempts=$((f_attempts + 1))
    sleep 10
  done
  if [[ "${f_attempts}" -ge "${f_max_attempts}" ]]
  then
    g_echo_error "Timed out waiting for account activation (10 minutes)"
    g_echo_note "Please check your email (including spam) and click the verification link."
    return 1
  fi

  # Step 3: Login to get token
  g_echo_note "Step 3/4: Logging in to create API token..."
  f_token_data=$(f_login "${f_email}" "${f_password}")
  f_login_token=$(echo "${f_token_data}" | jq -r '.token')
  if [[ -z "${f_login_token}" ]] || [[ "${f_login_token}" == "null" ]]
  then
    g_echo_error "Failed to obtain login token"
    echo "${f_token_data}"
    return 1
  fi

  # Create permanent API token
  local f_api_token_data
  f_api_token_data=$(f_create_token "${f_login_token}" "symbios-ddns")
  f_api_token=$(echo "${f_api_token_data}" | jq -r '.token')
  if [[ -z "${f_api_token}" ]] || [[ "${f_api_token}" == "null" ]]
  then
    g_echo_error "Failed to create API token"
    echo "${f_api_token_data}"
    return 1
  fi
  g_echo_ok "API token created"

  # Step 4: Create domain if specified
  if [[ -n "${f_domain}" ]]
  then
    g_echo_note "Step 4/4: Creating domain ${f_domain}..."
    f_create_domain "${f_api_token}" "${f_domain}" || true
  else
    g_echo_note "Step 4/4: Skipped (no domain specified)"
  fi

  # Output the API token
  echo "---"
  g_echo_ok "Setup complete! API token: ${f_api_token}"
  echo "{\"token\": \"${f_api_token}\"}"
}

# --- Main ---
g_action="${1:-}"
shift 2>/dev/null || true

case "${g_action}" in
  captcha)
    f_captcha
    ;;
  register)
    f_register "$1" "$2" "$3"
    ;;
  register-with-captcha)
    f_register "$1" "$2" "$5" "$3" "$4"
    ;;
  login)
    f_login "$1" "$2"
    ;;
  create-token)
    local f_tmp
    f_tmp=$(f_login "$1" "$2")
    local f_login_tok
    f_login_tok=$(echo "${f_tmp}" | jq -r '.token')
    if [[ -z "${f_login_tok}" ]] || [[ "${f_login_tok}" == "null" ]]
    then
      g_echo_error "Login failed"
      echo "${f_tmp}"
      exit 1
    fi
    f_create_token "${f_login_tok}" "${3:-symbios-ddns}"
    ;;
  create-domain)
    f_create_domain "$1" "$2"
    ;;
  activate)
    f_activate "$1" "$2" "$3"
    ;;
  check-activation)
    f_check_activation "$1" "$2"
    ;;
  setup)
    f_setup "$1" "$2" "$3"
    ;;
  *)
    f_usage
    exit 1
    ;;
esac
