#!/bin/bash
# SymbiOS - Comprehensive service test script
#
# Dynamically reads # docs: metadata from each services/*.yml playbook
# and runs all defined actions (install, stop, start, restart, uninstall, etc.).
#
# Also performs Authelia integration tests for services that declare access
# groups in their # docs metadata:
#   - Unauth redirect (HTTP 302 to Authelia)
#   - admin login via /api/firstfactor + service access
#   - ephemeral test user (symbios-dev-testuser created with a random pwgen
#     password, added to the service user group -> access granted, removed from
#     the group -> access denied)
# The test user and its group memberships are cleaned up at the end.
#
# This script runs DIRECTLY ON the SymbiOS host (no SSH involved). The
# hostname argument is optional; base_domain defaults to the value from
# /symbios/base-services/symbios-ui/config/inventory.yml.
#
# Usage:
#   symbios-dev-check-all.sh [--service <name>] [--list-services]
#
# Examples:
#   symbios-dev-check-all.sh
#   symbios-dev-check-all.sh --service dabo
#   symbios-dev-check-all.sh --list-services

source /etc/bash/gaboshlib.include 2>/dev/null || true

# --- Color codes ---
f_red='\033[0;31m'
f_green='\033[0;32m'
f_yellow='\033[0;33m'
f_blue='\033[0;34m'
f_bold='\033[1m'
f_reset='\033[0m'

# --- Global state ---
g_hostname=""
g_base_domain=""
g_insecure=(-k -s)
g_log_dir="/tmp/symbios-check-$$"
g_total=0
g_pass=0
g_fail=0
g_skip=0
declare -A g_results
g_filter_services=()
g_services_json=""
# Track the most recent long-running child PID so Ctrl+C can kill it.
g_cur_pid=""
# Set to 1 when an interrupt arrives; loops check it to bail out fast.
g_interrupted=0

# --- Helper: Local command execution ---
# The script runs directly on the SymbiOS host (no SSH needed). The hostname
# argument is kept for backwards compatibility but only used for display /
# domain logic.

function f_exec {
  local f_cmd="$1"
  eval "$f_cmd" 2>/dev/null
}

function f_exec_try {
  # Run a command. As root the wrapper is just an eval; kept as a named
  # function so checks stay terse and a future non-root mode is possible.
  local f_cmd="$1"
  local f_result
  f_result=$(f_exec "$f_cmd" 2>&1)
  local f_rc=$?
  echo "$f_result"
  return $f_rc
}

# --- Interrupt handling ---
# Without a trap, SIGINT only kills the foreground child (e.g. the running
# ansible-playbook) while the rest of the script keeps going, so Ctrl+C feels
# useless. This handler kills the tracked child and aborts the whole script.
function f_handle_signal {
  local f_sig="${1:-INT}"
  g_interrupted=1
  echo ""
  echo -e "${f_red}=== ${f_sig} received - aborting SymbiOS dev check ===${f_reset}"
  if [[ -n "$g_cur_pid" ]]
  then
    # Kill the current child process group first, then the process itself
    # ('-' prefix works when job control is enabled, plain kill otherwise).
    kill -TERM -- "-$g_cur_pid" 2>/dev/null
    kill -TERM "$g_cur_pid" 2>/dev/null
    sleep 1
    kill -KILL -- "-$g_cur_pid" 2>/dev/null
    kill -KILL "$g_cur_pid" 2>/dev/null
    g_cur_pid=""
  fi
  exit 130
}
trap f_handle_signal INT TERM HUP

# --- Helper: Display ---

function f_usage {
  echo "Usage: $(basename "$0") [--service <name>] [--list-services]"
  echo ""
  echo "Runs directly on the SymbiOS host (no SSH)."
  echo ""
  echo "Arguments:"
  echo "  --service X       Only test service X (can be repeated)"
  echo "  --list-services   List discovered services and exit (no tests)"
  echo ""
  echo "Discovers services dynamically from services/*.yml playbook # docs: blocks."
  echo "Admin password for Authelia tests: test1234"
}

function f_result {
  local f_test="$1"
  local f_status="$2"
  local f_detail="${3:-}"
  g_total=$((g_total + 1))
  case "$f_status" in
    PASS)
      g_pass=$((g_pass + 1))
      echo -e "  ${f_green}PASS${f_reset}  $f_test"
      g_results["$f_test"]="PASS"
      ;;
    FAIL)
      g_fail=$((g_fail + 1))
      echo -e "  ${f_red}FAIL${f_reset}  $f_test"
      [[ -n "$f_detail" ]] && echo -e "        ${f_yellow}$f_detail${f_reset}"
      g_results["$f_test"]="FAIL"
      ;;
    SKIP)
      g_skip=$((g_skip + 1))
      echo -e "  ${f_yellow}SKIP${f_reset}  $f_test"
      [[ -n "$f_detail" ]] && echo -e "        $f_detail"
      g_results["$f_test"]="SKIP"
      ;;
  esac
}

function f_section {
  echo ""
  echo -e "${f_bold}${f_blue}=== $1 ===${f_reset}"
}

# --- Helper: Service metadata extraction ---

function f_extract_services_json {
  # Write extraction script to temp file, SCP to host, execute
  local f_script
  f_script=$(mktemp /tmp/symbios-extract-XXXXXX.sh)
  cat > "$f_script" <<'EXTRACT_SCRIPT'
#!/bin/bash
export PATH="/symbios/git/SymbiOS/scripts:$PATH"
g_repo="/symbios/git/SymbiOS"
g_domain="$(yq -r .all.vars.base_domain /symbios/base-services/symbios-ui/config/inventory.yml 2>/dev/null || echo "")"

echo "["
f_first=1
for f_playbook in "$g_repo"/services/*.yml
do
  [[ ! -f "$f_playbook" ]] && continue
  f_basename="$(basename "$f_playbook" .yml)"

  f_tmp=$(mktemp)
  f_in_docs=0
  while IFS= read -r f_line
  do
    f_stripped="${f_line#"${f_line%%[![:space:]]*}"}"
    if [[ "$f_in_docs" -eq 1 ]]
    then
      if [[ "$f_stripped" == \#* ]]
      then
        echo "${f_stripped}" | sed 's/^#[ ]\?//' >> "$f_tmp"
      else
        break
      fi
    elif [[ "$f_stripped" == "# docs:"* ]]
    then
      f_in_docs=1
    fi
  done < "$f_playbook"

  if [[ ! -s "$f_tmp" ]]
  then
    rm -f "$f_tmp"
    continue
  fi

  f_json=$(yq -o=json '.' "$f_tmp" 2>/dev/null)
  rm -f "$f_tmp"

  if [[ -z "$f_json" || "$f_json" == "null" ]]
  then
    continue
  fi

  f_json=$(echo "$f_json" | yq -o=json ".playbook = \"$f_basename\" | .domain = \"$g_domain\"" 2>/dev/null)

  if [[ -n "$g_domain" ]]
  then
    f_json=$(echo "$f_json" | yq -o=json '(.url // "") |= sub("{{ base_domain }}"; "'"$g_domain"'")' 2>/dev/null)
  fi

  [[ $f_first -eq 0 ]] && echo ","
  echo "$f_json"
  f_first=0
done
echo "]"
EXTRACT_SCRIPT
  chmod +x "$f_script"

  # Run the extraction script locally (script runs directly on the host)
  bash "$f_script"
  rm -f "$f_script"
}

function f_json_get {
  local f_json="$1"
  local f_path="$2"
  local f_default="${3:-}"
  local f_result
  # Convert yq path notation to jq path: .foo.bar[0].baz -> .foo.bar[0].baz
  # jq uses same notation for most cases
  f_result=$(echo "$f_json" | jq -r "$f_path // \"$f_default\"" 2>/dev/null)
  if [[ -z "$f_result" || "$f_result" == "null" || "$f_result" == "" ]]
  then
    echo "$f_default"
  else
    echo "$f_result"
  fi
}

function f_json_get_array {
  local f_json="$1"
  local f_path="$2"
  echo "$f_json" | jq -r "$f_path[]? // empty" 2>/dev/null
}

# --- Helper: Docker/Compose ---

function f_wait_containers {
  local f_compose_file="${1:-}"
  local f_max_wait=120
  local f_elapsed=0
  sleep 10
  while [[ $f_elapsed -lt $f_max_wait ]]
  do
    if [[ "$g_interrupted" == "1" ]]
    then
      return 1
    fi
    if [[ -n "$f_compose_file" ]]
    then
      local f_up
      f_up=$(f_exec_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
      f_up="${f_up//[^0-9]/}"
      if [[ -n "$f_up" && "$f_up" -gt 0 ]]
      then
        return 0
      fi
    else
      local f_bad
      f_bad=$(f_exec_try "docker ps -a --format '{{.Status}}' 2>/dev/null | grep -c -E '(Restarting|Exited)' || true" 2>/dev/null)
      f_bad="${f_bad//[^0-9]/}"
      if [[ "$f_bad" == "0" || -z "$f_bad" ]]
      then
        return 0
      fi
    fi
    sleep 10
    f_elapsed=$((f_elapsed + 10))
  done
  return 1
}

function f_check_compose_up {
  local f_compose_file="$1"
  local f_result
  f_result=$(f_exec_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
  f_result="${f_result//[^0-9]/}"
  [[ -n "$f_result" && "$f_result" -gt 0 ]]
}

function f_check_no_containers {
  local f_compose_file="$1"
  local f_result
  f_result=$(f_exec_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
  f_result="${f_result//[^0-9]/}"
  [[ -z "$f_result" || "$f_result" == "0" ]]
}

function f_check_container_running {
  local f_name="$1"
  local f_result
  f_result=$(f_exec_try "docker ps --format '{{.Names}}' | grep -w '$f_name' || true" 2>/dev/null)
  [[ -n "$f_result" ]]
}

# --- Helper: Playbook/Service ---

function f_run_playbook {
  local f_playbook="$1"
  f_exec_try "symbios-run-playbook.sh '$f_playbook'" 2>&1
}

function f_uninstall_service {
  local f_playbook="$1"
  local f_mode="$2"
  f_exec_try "symbios-uninstall.sh '$f_playbook' '$f_mode'" 2>&1
}

function f_check_no_dir {
  local f_path="$1"
  f_exec_try "test ! -d '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_no_path {
  local f_path="$1"
  f_exec_try "test ! -e '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_dir_exists {
  local f_path="$1"
  f_exec_try "test -d '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_file_exists {
  local f_path="$1"
  f_exec_try "test -f '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_dir_empty {
  local f_path="$1"
  f_exec_try "find '$f_path' -maxdepth 1 -mindepth 1 -print -quit 2>/dev/null | grep -q . || echo empty" 2>/dev/null | grep -q "empty"
}

function f_http_check {
  local f_url="$1"
  local f_expected="${2:-200}"
  local f_code
  f_code=$(f_exec_try "curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 '$f_url' 2>/dev/null" 2>/dev/null)
  f_code="${f_code//[^0-9]/}"
  [[ "$f_code" == "$f_expected" ]]
}

# --- Helper: Authelia authentication tests ---

function f_authelia_login {
  # Authenticate against Authelia API (first factor) and save session cookie.
  # Usage: f_authelia_login <username> <password> <authelia_domain> <cookie_jar>
  # Returns HTTP status code of the /api/firstfactor response.
  local f_user="$1"
  local f_pass="$2"
  local f_auth_domain="$3"
  local f_cookie="$4"
  local f_code
  # Escape single quotes in password for shell safety
  local f_safe_pass="${f_pass//\'/\'\\\'\'}"
  f_code=$(f_exec_try "curl -sk -o /dev/null -w '%{http_code}' \
    -c '$f_cookie' \
    -X POST 'https://${f_auth_domain}/api/firstfactor' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d '{\"username\":\"${f_user}\",\"password\":\"${f_safe_pass}\",\"keepMeLoggedIn\":false}' \
    --connect-timeout 10 --max-time 15 2>/dev/null" 2>/dev/null)
  f_code="${f_code//[^0-9]/}"
  echo "$f_code"
}

function f_auth_check {
  # Test access to a service URL using a session cookie.
  # Usage: f_auth_check <url> <cookie_jar> [expected_code]
  # Returns the actual HTTP status code.
  local f_url="$1"
  local f_cookie="$2"
  local f_expected="${3:-200}"
  local f_code
  f_code=$(f_exec_try "curl -sk -o /dev/null -w '%{http_code}' \
    -b '$f_cookie' \
    --connect-timeout 10 --max-time 15 '$f_url' 2>/dev/null" 2>/dev/null)
  f_code="${f_code//[^0-9]/}"
  echo "$f_code"
}

function f_oidc_flow_check {
  # Test access to a service via the FULL OIDC redirect flow. This follows
  # every redirect (service -> Authelia /oidc/authorize -> callback -> app)
  # while keeping the cookie jar updated across hops, so it works for BOTH
  # forward-auth services (single hop, session cookie checked by Traefik) and
  # OIDC services (Nextcloud/Home-Assistant/... which manage their own
  # session and need the complete authorize/callback round trip).
  # Usage: f_oidc_flow_check <url> <cookie_jar>
  # Returns the HTTP status code of the FINAL response.
  local f_url="$1"
  local f_cookie="$2"
  local f_code
  f_code=$(f_exec_try "curl -skL --max-redirs 12 \
    -b '$f_cookie' -c '$f_cookie' \
    --connect-timeout 10 --max-time 40 \
    -o /dev/null -w '%{http_code}' '$f_url' 2>/dev/null" 2>/dev/null)
  f_code="${f_code//[^0-9]/}"
  echo "$f_code"
}

# --- Parse arguments ---

g_list_services=0

while [[ $# -gt 0 ]]
do
  case "$1" in
    --service)
      shift
      g_filter_services+=("$1")
      ;;
    --list-services)
      g_list_services=1
      ;;
    -*)
      f_usage
      exit 1
      ;;
    *)
      if [[ -z "$g_hostname" ]]
      then
        g_hostname="$1"
      elif [[ -z "$g_base_domain" ]]
      then
        g_base_domain="$1"
      fi
      ;;
  esac
  shift
done

if [[ -z "$g_hostname" ]]
then
  g_hostname="$(hostname)"
fi

if [[ -z "$g_base_domain" ]]
then
  # Read base_domain from the local inventory (script runs on the host)
  g_base_domain="$(yq -r '.all.vars.base_domain' /symbios/base-services/symbios-ui/config/inventory.yml 2>/dev/null || echo "")"
fi

# data_root is where the runchecks.d healthchecks live (host layout)
g_data_root="$(yq -r '.all.vars.data_root // "/symbios"' /symbios/base-services/symbios-ui/config/inventory.yml 2>/dev/null || echo "/symbios")"
g_data_root="${g_data_root%/}"

# --- Handle --list-services ---
if [[ "$g_list_services" -eq 1 ]]
then
  echo -e "${f_bold}SymbiOS Service Discovery${f_reset}"
  echo "Domain: $g_base_domain"
  echo ""

  g_services_json=$(f_extract_services_json 2>/dev/null)
  f_count=$(echo "$g_services_json" | jq 'length' 2>/dev/null)
  f_count="${f_count:-0}"

  if [[ "$f_count" == "0" ]]
  then
    echo -e "${f_yellow}No services with # docs: blocks found.${f_reset}"
    exit 0
  fi

  echo -e "${f_bold}Found $f_count service(s):${f_reset}"
  echo ""

  for f_i in $(seq 0 $(( f_count - 1 )))
  do
    f_svc_json=$(echo "$g_services_json" | jq ".[$f_i]" 2>/dev/null)
    f_svc_name=$(f_json_get "$f_svc_json" ".playbook" "?")
    f_svc_url=$(f_json_get "$f_svc_json" .url "")
    f_svc_compose=$(f_json_get "$f_svc_json" ".service_control.services[0].compose_file" "")
    f_svc_user_group=$(f_json_get "$f_svc_json" ".access.user_group" "")
    f_svc_admin_group=$(f_json_get "$f_svc_json" ".access.admin_group" "")

    echo -e "${f_green}${f_svc_name}${f_reset}"
    [[ -n "$f_svc_url" ]] && echo "  URL:     $f_svc_url"
    [[ -n "$f_svc_compose" ]] && echo "  Compose: $f_svc_compose"
    if [[ -n "$f_svc_user_group" ]]
    then
      echo "  Access:  user_group=$f_svc_user_group  admin_group=$f_svc_admin_group"
    fi
  done

  exit 0
fi

mkdir -p "$g_log_dir"

echo -e "${f_bold}SymbiOS Service Test Suite${f_reset}"
echo "Host: $g_hostname  Domain: $g_base_domain  Log: $g_log_dir"
echo "Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=================================================================="

# =========================================================================
# PHASE 0: Pre-flight checks
# =========================================================================
f_section "Phase 0: Pre-flight checks"

if [[ "$(id -u)" -eq 0 ]]
then
  f_result "Running as root" PASS
else
  f_result "Running as root" FAIL "Run as root (sudo)"
  echo -e "\n${f_red}Cannot proceed without root rights. Aborting.${f_reset}"
  exit 1
fi

if [[ -n "$g_base_domain" ]]
then
  f_result "base_domain resolution" PASS "$g_base_domain"
else
  f_result "base_domain resolution" FAIL "No base_domain found in inventory.yml"
fi

for f_container in symbios-base-traefik symbios-base-ldap symbios-base-authelia symbios-base-webui
do
  if f_check_container_running "$f_container"
  then
    f_result "Container: $f_container" PASS
  else
    f_result "Container: $f_container" FAIL "Not running"
  fi
done

if f_exec_try "docker info &>/dev/null" &>/dev/null
then
  f_result "Docker daemon" PASS
else
  f_result "Docker daemon" FAIL "Docker not responding"
fi

if f_exec_try "which symbios-run-playbook.sh" &>/dev/null
then
  f_result "symbios-run-playbook.sh in PATH" PASS
else
  f_result "symbios-run-playbook.sh in PATH" FAIL "Not found in PATH"
fi

if f_exec_try "which symbios-uninstall.sh" &>/dev/null
then
  f_result "symbios-uninstall.sh in PATH" PASS
else
  f_result "symbios-uninstall.sh in PATH" FAIL "Not found in PATH"
fi

if f_exec_try "which yq" &>/dev/null
then
  f_result "yq on host" PASS
else
  f_result "yq on host" FAIL "yq not found - cannot extract playbook metadata"
  echo -e "\n${f_red}Cannot proceed without yq. Aborting.${f_reset}"
  exit 1
fi

# =========================================================================
# Phase: Auth test user setup
# =========================================================================
f_section "Phase: Auth test user setup"

# Generate a random password that satisfies all password policies (including
# paranoid: >=32 chars, letter+digit+special) but is shell-safe (no quotes,
# backticks, dollar signs, backslashes) so it flows safely through the SSH
# exec layers. Base pwgen is alphanumeric; appending X1! guarantees an
# uppercase letter, a digit and a special character.
g_test_pw="$(pwgen -s 31 1)X1!"

# Delete any leftover test user from a previous run first (idempotent), so a
# fresh user with a fresh random password is always created.
f_exec_try "symbios-ldap-user.sh --delete --uid symbios-dev-testuser" >/dev/null 2>&1

# Create test user with random password
f_create_output=$(f_exec_try "echo '${g_test_pw}' > /tmp/.symbios-dev-test-pw && \
  symbios-ldap-user.sh --create --uid symbios-dev-testuser \
  --password-file /tmp/.symbios-dev-test-pw \
  --displayname 'SymbiOS Dev Testuser' --group users && \
  rm -f /tmp/.symbios-dev-test-pw" 2>&1)
f_create_rc=$?

if [[ $f_create_rc -eq 0 ]] && ! echo "$f_create_output" | grep -qi "error\|failed"
then
  f_result "Create test user symbios-dev-testuser" PASS
else
  f_result "Create test user symbios-dev-testuser" FAIL "Could not create user (see output)"
  echo "        $f_create_output" | head -5
fi

# Clean up the test user on exit so an aborted run never leaves it behind
function f_cleanup_testuser {
  f_exec_try "symbios-ldap-user.sh --delete --uid symbios-dev-testuser" >/dev/null 2>&1
  rm -f "$g_log_dir"/cookie-* 2>/dev/null
}
trap f_cleanup_testuser EXIT

# Verify Authelia can authenticate the test user (smoke test)
f_authelia_domain="auth.${g_base_domain}"
f_auth_test_code=$(f_authelia_login "symbios-dev-testuser" "$g_test_pw" "$f_authelia_domain" "/dev/null")
if [[ "$f_auth_test_code" == "200" ]]
then
  f_result "Authelia first-factor login (testuser)" PASS
else
  f_result "Authelia first-factor login (testuser)" FAIL "HTTP $f_auth_test_code (expected 200)"
fi

# Verify admin can still authenticate
f_admin_auth_code=$(f_authelia_login "admin" "test1234" "$f_authelia_domain" "/dev/null")
if [[ "$f_admin_auth_code" == "200" ]]
then
  f_result "Authelia first-factor login (admin)" PASS
else
  f_result "Authelia first-factor login (admin)" FAIL "HTTP $f_admin_auth_code (expected 200)"
fi

# =========================================================================
# Discover services from playbooks
# =========================================================================
f_section "Discovering services from playbooks"

echo "  Extracting # docs: metadata from services/*.yml..."
g_services_json=$(f_extract_services_json 2>/dev/null)

f_service_count=$(echo "$g_services_json" | jq 'length' 2>/dev/null)
f_service_count="${f_service_count:-0}"

if [[ "$f_service_count" == "0" ]]
then
  f_result "Service discovery" FAIL "No services with # docs: blocks found"
  echo -e "\n${f_red}Cannot proceed without service metadata. Aborting.${f_reset}"
  exit 1
fi

f_result "Service discovery" PASS "Found $f_service_count services"

echo ""
echo "  Discovered services:"
for f_i in $(seq 0 $(( f_service_count - 1 )))
do
  f_svc_json=$(echo "$g_services_json" | jq ".[$f_i]" 2>/dev/null)
  f_svc_name=$(f_json_get "$f_svc_json" ".playbook" "?")
  f_svc_url=$(f_json_get "$f_svc_json" ".url" "")
  if [[ -n "$f_svc_url" ]]
  then
    echo "    - $f_svc_name  ->  $f_svc_url"
  else
    echo "    - $f_svc_name  (no HTTP route)"
  fi
done

# =========================================================================
# Per-service testing
# =========================================================================
for f_i in $(seq 0 $(( f_service_count - 1 )))
do
  f_svc_json=$(echo "$g_services_json" | jq ".[$f_i]" 2>/dev/null)

  # Extract all metadata from the docs: block
  f_name=$(f_json_get "$f_svc_json" ".playbook" "")
  f_playbook="services/${f_name}.yml"
  f_url=$(f_json_get "$f_svc_json" ".url" "")
  f_compose=$(f_json_get "$f_svc_json" ".service_control.services[0].compose_file" "")
  f_action_start=$(f_json_get "$f_svc_json" ".actions.start" "")
  f_action_stop=$(f_json_get "$f_svc_json" ".actions.stop" "")
  f_action_restart=$(f_json_get "$f_svc_json" ".actions.restart" "")
  f_action_reload=$(f_json_get "$f_svc_json" ".actions.reload" "")

  # Extract access control groups for Authelia login tests
  f_admin_group=$(f_json_get "$f_svc_json" ".access.admin_group" "")
  f_user_group=$(f_json_get "$f_svc_json" ".access.user_group" "")

  # Extract program_paths and userdata_paths arrays
  f_program_paths=$(f_json_get_array "$f_svc_json" ".uninstall.program_paths")
  f_userdata_paths=$(f_json_get_array "$f_svc_json" ".uninstall.userdata_paths")

  # Expand template variables used in docs paths (hostname-dependent paths)
  f_hostname=$(f_exec_try "hostname" 2>/dev/null | head -1)
  f_program_paths="${f_program_paths//\{\{ ansible_facts['hostname'] \}\}/${f_hostname}}"
  f_program_paths="${f_program_paths//\{\{ ansible_hostname \}\}/${f_hostname}}"

  # Apply service filter
  if [[ ${#g_filter_services[@]} -gt 0 ]]
  then
    f_found=0
    for f_filter in "${g_filter_services[@]}"
    do
      [[ "$f_filter" == "$f_name" ]] && f_found=1
    done
    [[ $f_found -eq 0 ]] && continue
  fi

  echo ""
  echo -e "${f_bold}------------------------------------------------------------------${f_reset}"
  echo -e "${f_bold}Testing: $f_name${f_reset}"
  [[ -n "$f_compose" ]] && echo "  Compose: $f_compose"
  [[ -n "$f_url" ]] && echo "  URL: $f_url"
  [[ -n "$f_action_start" ]] && echo "  Start: $f_action_start"
  [[ -n "$f_action_stop" ]] && echo "  Stop: $f_action_stop"
  [[ -n "$f_action_restart" ]] && echo "  Restart: $f_action_restart"
  [[ -n "$f_action_reload" ]] && echo "  Reload: $f_action_reload"
  if [[ -n "$f_user_group" ]]
  then
    echo "  Access: user_group=$f_user_group admin_group=$f_admin_group"
  fi
  echo -e "${f_bold}------------------------------------------------------------------${f_reset}"

  # Validate required fields
  if [[ -z "$f_compose" ]]
  then
    f_result "Metadata: compose_file" FAIL "No compose_file in # docs:"
    echo "        Skipping $f_name"
    continue
  fi

  # =========================================================================
  # Phase 1: Install
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 1: Install ---${f_reset}"

  # Clean up if already installed
  if f_check_compose_up "$f_compose"
  then
    echo "  Service already running, stopping first..."
    f_uninstall_service "$f_playbook" "full" >/dev/null 2>&1
    sleep 3
  fi

  # Remove any leftover dirs
  f_exec_try "rm -rf /symbios/services/$f_name" >/dev/null 2>&1

  # Run playbook
  f_output=$(f_run_playbook "$f_playbook" 2>&1)
  f_rc=$?
  f_log="$g_log_dir/${f_name}_install.log"
  echo "$f_output" > "$f_log"

  if [[ $f_rc -eq 0 ]] && echo "$f_output" | grep -q "PLAY RECAP\|play recap"
  then
    f_failures=$(echo "$f_output" | grep -oP 'failed=\K[0-9]+' | head -1)
    f_failures="${f_failures:-0}"
    if [[ "$f_failures" == "0" ]]
    then
      f_result "Phase 1: Install playbook" PASS
    else
      f_result "Phase 1: Install playbook" FAIL "failures=$f_failures (see $f_log)"
    fi
  else
    f_result "Phase 1: Install playbook" FAIL "Playbook failed (rc=$f_rc, see $f_log)"
  fi

  # Wait for containers
  f_wait_containers "$f_compose"

  if f_check_compose_up "$f_compose"
  then
    f_result "Phase 1: Containers running" PASS
  else
    f_result "Phase 1: Containers running" FAIL "Not all containers up"
    echo "        Skipping remaining phases for $f_name"
    continue
  fi

  # =========================================================================
  # Phase 2: Healthcheck
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 2: Healthcheck ---${f_reset}"

  f_hc_name="symbios-healthcheck-${f_name}"

  # A service install should have deployed a runcheck for this service
  if f_check_file_exists "${g_data_root}/runchecks.d/${f_hc_name}.check"
  then
    f_result "Phase 2: Healthcheck file deployed" PASS
  else
    f_result "Phase 2: Healthcheck file deployed" FAIL "Missing ${g_data_root}/runchecks.d/${f_hc_name}.check"
  fi

  # Execute the check (in a subshell with the runcheck helpers) and verify it
  # reports "ok". A freshly started service may need time to become reachable,
  # so on failure wait 2 minutes and retry once before reporting FAIL.
  f_run_hc_check()
  {
    local f_hint
    f_hint=$(f_exec_try "g_tmp='/tmp' ; g_current_check_failed=0 ; g_current_check_error='' ; \
      g_echo_error() { g_current_check_failed=1 ; g_current_check_error=\"\$*\" ; } ; \
      . '${g_data_root}/runchecks.d/${f_hc_name}.check' 2>/dev/null ; \
      if [[ \"\${g_current_check_failed:-0}\" == '0' ]] ; then echo ok ; else echo \"error:\${g_current_check_error}\" ; fi" 2>/dev/null)
    echo "$f_hint"
  }

  f_hc_hint=""
  if [[ -f "${g_data_root}/runchecks.d/${f_hc_name}.check" ]]
  then
    f_hc_hint=$(f_run_hc_check)
  fi

  if [[ "$f_hc_hint" != "ok" ]]
  then
    echo "        Healthcheck not OK yet, waiting 2 min before retry..."
    sleep 120
    f_hc_hint=""
    if [[ -f "${g_data_root}/runchecks.d/${f_hc_name}.check" ]]
    then
      f_hc_hint=$(f_run_hc_check)
    fi
  fi

  if [[ "$f_hc_hint" == "ok" ]]
  then
    f_result "Phase 2: Healthcheck execution" PASS
  else
    f_result "Phase 2: Healthcheck execution" FAIL "${f_hc_hint:-check file not executed}"
  fi

  # =========================================================================
  # Phase 3: Idempotency
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 3: Idempotency ---${f_reset}"

  f_output2=$(f_run_playbook "$f_playbook" 2>&1)
  f_rc2=$?
  f_log2="$g_log_dir/${f_name}_idempotency.log"
  echo "$f_output2" > "$f_log2"

  if [[ $f_rc2 -eq 0 ]]
  then
    f_failures2=$(echo "$f_output2" | grep -oP 'failed=\K[0-9]+' | head -1)
    f_failures2="${f_failures2:-0}"
    if [[ "$f_failures2" == "0" ]]
    then
      f_changed=$(echo "$f_output2" | grep -oP 'changed=\K[0-9]+' | head -1)
      f_changed="${f_changed:-0}"
      if [[ "$f_changed" == "0" ]]
      then
        f_result "Phase 3: Idempotent (no changes)" PASS
      else
        f_result "Phase 3: Idempotent (no changes)" FAIL "changed=$f_changed on second run"
      fi
    else
      f_result "Phase 3: Idempotent (no errors)" FAIL "failures=$f_failures2 (see $f_log2)"
    fi
  else
    f_result "Phase 3: Idempotent" FAIL "Playbook failed on second run (see $f_log2)"
  fi

  # =========================================================================
  # Phase 3: Actions - stop, start, restart, reload (from docs: actions block)
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 3: Actions (from docs: actions) ---${f_reset}"

  # --- Stop action ---
  if [[ -n "$f_action_stop" ]]
  then
    echo "  Running: $f_action_stop"
    f_exec_try "$f_action_stop" >/dev/null 2>&1
    sleep 3

    if f_check_no_containers "$f_compose"
    then
      f_result "Phase 3: actions.stop" PASS
    else
      f_result "Phase 3: actions.stop" FAIL "Containers still running after stop"
    fi
  else
    echo "  No actions.stop defined, using docker compose down"
    f_exec_try "cd $(dirname "$f_compose") && docker compose down" >/dev/null 2>&1
    sleep 3
    if f_check_no_containers "$f_compose"
    then
      f_result "Phase 3: docker compose down (fallback)" PASS
    else
      f_result "Phase 3: docker compose down (fallback)" FAIL "Containers still running"
    fi
  fi

  # --- Start action ---
  if [[ -n "$f_action_start" ]]
  then
    echo "  Running: $f_action_start"
    f_exec_try "$f_action_start" >/dev/null 2>&1
  else
    echo "  No actions.start defined, using docker compose up -d"
    f_exec_try "cd $(dirname "$f_compose") && docker compose up -d" >/dev/null 2>&1
  fi
  f_wait_containers "$f_compose"

  if f_check_compose_up "$f_compose"
  then
    f_result "Phase 3: actions.start" PASS
  else
    f_result "Phase 3: actions.start" FAIL "Containers not running after start"
  fi

  # --- Restart action ---
  if [[ -n "$f_action_restart" ]]
  then
    echo "  Running: $f_action_restart"
    f_exec_try "$f_action_restart" >/dev/null 2>&1
    f_wait_containers "$f_compose"

    if f_check_compose_up "$f_compose"
    then
      f_result "Phase 3: actions.restart" PASS
    else
      f_result "Phase 3: actions.restart" FAIL "Containers not running after restart"
    fi
  else
    f_result "Phase 3: actions.restart" SKIP "No actions.restart defined"
  fi

  # --- Reload action (skip if identical to start) ---
  if [[ -n "$f_action_reload" && "$f_action_reload" != "$f_action_start" ]]
  then
    echo "  Running: $f_action_reload"
    f_exec_try "$f_action_reload" >/dev/null 2>&1
    f_wait_containers "$f_compose"

    if f_check_compose_up "$f_compose"
    then
      f_result "Phase 3: actions.reload" PASS
    else
      f_result "Phase 3: actions.reload" FAIL "Containers not running after reload"
    fi
  else
    f_result "Phase 3: actions.reload" SKIP "No actions.reload defined (or same as start)"
  fi

  # =========================================================================
  # Phase 4: Uninstall (program) - userdata stays
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 4: Uninstall (program, userdata kept) ---${f_reset}"

  # Create a marker file in the service dir that represents user data. In
  # "program" mode the service dir and all data must survive the uninstall.
  f_exec_try "mkdir -p /symbios/services/$f_name && echo 'keep-me' > /symbios/services/$f_name/.userdata-marker" >/dev/null 2>&1

  f_output4p=$(f_uninstall_service "$f_playbook" "program" 2>&1)
  f_log4p="$g_log_dir/${f_name}_uninstall_program.log"
  echo "$f_output4p" > "$f_log4p"

  sleep 3

  # No containers should be running after any uninstall mode
  if f_check_no_containers "$f_compose"
  then
    f_result "Phase 4: program - containers stopped" PASS
  else
    f_result "Phase 4: program - containers stopped" FAIL "Containers still running"
  fi

  # The service dir must survive in program mode
  if f_check_dir_exists "/symbios/services/$f_name"
  then
    f_result "Phase 4: program - service dir kept" PASS
  else
    f_result "Phase 4: program - service dir kept" FAIL "/symbios/services/$f_name missing"
  fi

  # User data (marker file) must survive in program mode
  if f_check_file_exists "/symbios/services/$f_name/.userdata-marker"
  then
    f_result "Phase 4: program - userdata kept" PASS
  else
    f_result "Phase 4: program - userdata kept" FAIL "Userdata marker file missing"
  fi

  # The state entry is cleared in program mode (service is uninstalled)
  f_state_check4p=$(f_exec_try "grep -c 'services/$f_name.yml' /symbios/base-services/symbios-ui/config/installed-playbooks.yml || true" 2>/dev/null)
  f_state_check4p="${f_state_check4p//[^0-9]/}"
  if [[ -z "$f_state_check4p" || "$f_state_check4p" == "0" ]]
  then
    f_result "Phase 4: program - state entry removed" PASS
  else
    f_result "Phase 4: program - state entry removed" FAIL "Entry still in installed-playbooks.yml"
  fi

  # =========================================================================
  # Phase 5: Reset (userdata only)
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 5: Reset (delete userdata) ---${f_reset}"

  # Reinstall first
  f_run_playbook "$f_playbook" >/dev/null 2>&1
  f_wait_containers "$f_compose"

  if ! f_check_compose_up "$f_compose"
  then
    f_result "Phase 5: Pre-reinstall" FAIL "Could not reinstall for reset test"
    echo "        Skipping remaining phases for $f_name"
    continue
  fi

  # Run reset: wipes the whole service dir and re-runs the playbook
  f_output5=$(f_uninstall_service "$f_playbook" "reset" 2>&1)
  f_log5="$g_log_dir/${f_name}_reset.log"
  echo "$f_output5" > "$f_log5"

  # Reset includes a full playbook run - wait generously for containers
  f_wait_containers "$f_compose"
  sleep 3

  if f_check_compose_up "$f_compose"
  then
    f_result "Phase 5: Reset - service reprovisioned" PASS
  else
    f_result "Phase 5: Reset - service reprovisioned" FAIL "Containers not running after reset (see $f_log5)"
  fi

  # The service dir must have been recreated by the playbook run
  if f_check_dir_exists "/symbios/services/$f_name"
  then
    f_result "Phase 5: Reset - service dir recreated" PASS
  else
    f_result "Phase 5: Reset - service dir recreated" FAIL "/symbios/services/$f_name missing after reset"
  fi

  # State entry must stay set after a reset (service stays installed)
  f_state_check5=$(f_exec_try "grep -c 'services/$f_name.yml' /symbios/base-services/symbios-ui/config/installed-playbooks.yml || true" 2>/dev/null)
  f_state_check5="${f_state_check5//[^0-9]/}"
  if [[ -n "$f_state_check5" && "$f_state_check5" != "0" ]]
  then
    f_result "Phase 5: Reset - state entry kept" PASS
  else
    f_result "Phase 5: Reset - state entry kept" FAIL "Entry missing from installed-playbooks.yml after reset"
  fi

  # =========================================================================
  # Phase 6: Clean reinstall
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 6: Clean reinstall ---${f_reset}"

  f_uninstall_service "$f_playbook" "full" >/dev/null 2>&1
  sleep 3

  f_output6=$(f_run_playbook "$f_playbook" 2>&1)
  f_rc6=$?
  f_log6="$g_log_dir/${f_name}_reinstall.log"
  echo "$f_output6" > "$f_log6"

  f_wait_containers "$f_compose"

  if f_check_compose_up "$f_compose"
  then
    f_result "Phase 6: Clean reinstall" PASS
  else
    f_result "Phase 6: Clean reinstall" FAIL "Containers not running (see $f_log6)"
  fi

  # =========================================================================
  # Phase 7: HTTP + Authelia authentication check
  # =========================================================================
  if [[ -n "$f_url" ]]
  then
    echo -e "\n  ${f_blue}--- Phase 7: HTTP + Auth check ---${f_reset}"

    # Give Traefik time to detect new container labels
    sleep 5

    # --- 7a: Unauthenticated access (should get redirect to Authelia) ---
    f_unauth_code=$(f_exec_try "curl -sk -o /dev/null -w '%{http_code}' \
      --connect-timeout 10 --max-time 15 '$f_url' 2>/dev/null" 2>/dev/null)
    f_unauth_code="${f_unauth_code//[^0-9]/}"

    if [[ "$f_unauth_code" == "302" || "$f_unauth_code" == "401" ]]
    then
      f_result "Phase 7a: Unauth -> redirect (HTTP $f_unauth_code)" PASS
    elif [[ "$f_unauth_code" == "200" ]]
    then
      # Some services return 200 (e.g. login page) - acceptable for OIDC services
      f_result "Phase 7a: Unauth -> HTTP 200 (login page or open service)" PASS
    else
      f_result "Phase 7a: Unauth check" FAIL "HTTP $f_unauth_code (expected 302/401/200)"
    fi

    # --- Auth tests only if access groups are defined ---
    if [[ -n "$f_user_group" ]]
    then
      f_auth_domain="auth.${g_base_domain}"
      f_cookie_admin="${g_log_dir}/cookie-admin-${f_name}"
      f_cookie_testuser="${g_log_dir}/cookie-testuser-${f_name}"

      # --- 7b: Admin login (admin is always in admin_group after install) ---
      f_admin_code=$(f_authelia_login "admin" "test1234" "$f_auth_domain" "$f_cookie_admin")
      if [[ "$f_admin_code" == "200" ]]
      then
        f_result "Phase 7b: Admin Authelia login" PASS
      else
        f_result "Phase 7b: Admin Authelia login" FAIL "HTTP $f_admin_code (expected 200)"
      fi

      # Test admin access to service (full redirect flow: works for both
      # forward-auth and OIDC services)
      if [[ "$f_admin_code" == "200" ]]
      then
        f_admin_svc_code=$(f_oidc_flow_check "$f_url" "$f_cookie_admin")
        if [[ "$f_admin_svc_code" == "200" ]]
        then
          f_result "Phase 7b: Admin -> service access (HTTP $f_admin_svc_code)" PASS
        else
          f_result "Phase 7b: Admin -> service access" FAIL "HTTP $f_admin_svc_code (expected 200)"
        fi
      fi

      # --- 7c: TestUser IN group -> should get access ---
      # Add testuser to the service's user group
      f_exec_try "symbios-ldap-groups.sh --add-user \
        --name '$f_user_group' --uid symbios-dev-testuser" >/dev/null 2>&1
      sleep 1

      f_testuser_code=$(f_authelia_login "symbios-dev-testuser" "$g_test_pw" \
        "$f_auth_domain" "$f_cookie_testuser")
      if [[ "$f_testuser_code" == "200" ]]
      then
        f_result "Phase 7c: TestUser Authelia login" PASS
      else
        f_result "Phase 7c: TestUser Authelia login" FAIL "HTTP $f_testuser_code (expected 200)"
      fi

      # Test testuser access to service (should be granted)
      if [[ "$f_testuser_code" == "200" ]]
      then
        f_testuser_svc_code=$(f_oidc_flow_check "$f_url" "$f_cookie_testuser")
        if [[ "$f_testuser_svc_code" == "200" ]]
        then
          f_result "Phase 7c: TestUser IN '$f_user_group' -> access (HTTP $f_testuser_svc_code)" PASS
        else
          f_result "Phase 7c: TestUser IN '$f_user_group' -> access" FAIL "HTTP $f_testuser_svc_code (expected 200)"
        fi
      fi

      # --- 7d: TestUser NOT IN group -> should be denied ---
      f_exec_try "symbios-ldap-groups.sh --remove-user \
        --name '$f_user_group' --uid symbios-dev-testuser" >/dev/null 2>&1
      sleep 1

      # Fresh login (old session may still be cached) then follow the full
      # redirect flow: denied access is signalled either by a login redirect
      # (302/401, forward-auth) or by the service's own group check (403,
      # OIDC, e.g. Nextcloud user_oidc whitelist). For forward-auth deny
      # the final HTTP code may be 200 (Authelia login page) because curl
      # follows all redirects - in that case we check whether the final URL
      # is still the service domain (allowed) or something else (denied).
      f_cookie_denied="${g_log_dir}/cookie-denied-${f_name}"
      f_testuser_denied_login=$(f_authelia_login "symbios-dev-testuser" "$g_test_pw" \
        "$f_auth_domain" "$f_cookie_denied")
      f_testuser_denied_code=$(f_oidc_flow_check "$f_url" "$f_cookie_denied")
      if [[ "$f_testuser_denied_code" == "403" || "$f_testuser_denied_code" == "302" || "$f_testuser_denied_code" == "401" ]]
      then
        f_result "Phase 7d: TestUser NOT IN '$f_user_group' -> denied (HTTP $f_testuser_denied_code)" PASS
      else
        # curl -L may follow a deny-redirect chain to a 200 login page.
        # Detect this by checking whether the final URL is still the
        # service domain (access granted) or something else (denied).
        f_testuser_denied_url=$(f_exec_try "curl -skL --max-redirs 12 \
          -b '$f_cookie_denied' -c '$f_cookie_denied' \
          --connect-timeout 10 --max-time 40 \
          -o /dev/null -w '%{url_effective}' '$f_url' 2>/dev/null" 2>/dev/null)
        if [[ "$f_testuser_denied_url" != "$f_url" ]]
        then
          f_result "Phase 7d: TestUser NOT IN '$f_user_group' -> denied (redirected from service)" PASS
        else
          f_result "Phase 7d: TestUser NOT IN '$f_user_group' -> denied" FAIL "HTTP $f_testuser_denied_code (expected 403/302/401 or redirect away from service)"
        fi
      fi

      # Remove testuser from the service group after all tests so the
      # next service iteration gets a clean state (it will re-add in 7c).
      f_exec_try "symbios-ldap-groups.sh --remove-user \
        --name '$f_user_group' --uid symbios-dev-testuser" >/dev/null 2>&1

      # Clean up cookie files
      rm -f "$f_cookie_admin" "$f_cookie_testuser" "$f_cookie_denied" 2>/dev/null
    else
      f_result "Phase 7b-7d: Auth tests" SKIP "No access groups defined in docs metadata"
    fi
  else
    echo -e "\n  ${f_blue}--- Phase 7: HTTP + Auth check ---${f_reset}"
    f_result "Phase 7: HTTP check" SKIP "No url defined (service uses raw ports)"
  fi

  # =========================================================================
  # Phase 8: Uninstall (full) - final cleanup
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 8: Uninstall (full) ---${f_reset}"

  f_output8=$(f_uninstall_service "$f_playbook" "full" 2>&1)
  f_log8="$g_log_dir/${f_name}_uninstall_full.log"
  echo "$f_output8" > "$f_log8"

  sleep 3

  if f_check_no_containers "$f_compose"
  then
    f_result "Phase 8: Containers removed" PASS
  else
    f_result "Phase 8: Containers removed" FAIL "Containers still running"
  fi

  f_pp_removed=0
  f_pp_total=0
  while IFS= read -r f_path
  do
    [[ -z "$f_path" ]] && continue
    f_pp_total=$((f_pp_total + 1))
    if f_check_no_path "$f_path"
    then
      f_pp_removed=$((f_pp_removed + 1))
    fi
  done <<< "$f_program_paths"

  if [[ $f_pp_total -eq 0 ]]
  then
    f_result "Phase 8: program_paths removed" SKIP "No program_paths defined"
  elif [[ $f_pp_removed -eq $f_pp_total ]]
  then
    f_result "Phase 8: program_paths removed ($f_pp_removed/$f_pp_total)" PASS
  else
    f_result "Phase 8: program_paths removed ($f_pp_removed/$f_pp_total)" FAIL "Some program paths remain"
  fi

  if f_check_no_dir "/symbios/services/$f_name"
  then
    f_result "Phase 8: Service dir removed" PASS
  else
    f_result "Phase 8: Service dir removed" FAIL "/symbios/services/$f_name still exists"
  fi

  f_state_check8=$(f_exec_try "grep -c 'services/$f_name.yml' /symbios/base-services/symbios-ui/config/installed-playbooks.yml || true" 2>/dev/null)
  f_state_check8="${f_state_check8//[^0-9]/}"
  if [[ -z "$f_state_check8" || "$f_state_check8" == "0" ]]
  then
    f_result "Phase 8: State entry removed" PASS
  else
    f_result "Phase 8: State entry removed" FAIL "Entry still in installed-playbooks.yml"
  fi

done

# =========================================================================
# Phase: Auth test user cleanup
# =========================================================================
f_section "Phase: Auth test user cleanup"

# Delete test user from LDAP
f_delete_output=$(f_exec_try "symbios-ldap-user.sh --delete --uid symbios-dev-testuser" 2>&1)
f_delete_rc=$?

if [[ $f_delete_rc -eq 0 ]] && ! echo "$f_delete_output" | grep -qi "error\|failed"
then
  f_result "Delete test user symbios-dev-testuser" PASS
else
  f_result "Delete test user symbios-dev-testuser" FAIL "Could not delete user"
fi

# Clean up any remaining cookie files
rm -f "$g_log_dir"/cookie-* 2>/dev/null

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "=================================================================="
echo -e "${f_bold}SUMMARY${f_reset}"
echo "=================================================================="
echo -e "Total: $g_total  ${f_green}Pass: $g_pass${f_reset}  ${f_red}Fail: $g_fail${f_reset}  ${f_yellow}Skip: $g_skip${f_reset}"
echo ""

if [[ $g_fail -gt 0 ]]
then
  echo -e "${f_bold}${f_red}Failed tests:${f_reset}"
  for f_test in "${!g_results[@]}"
  do
    if [[ "${g_results[$f_test]}" == "FAIL" ]]
    then
      echo -e "  ${f_red}FAIL${f_reset}  $f_test"
    fi
  done
  echo ""
fi

echo "Logs saved to: $g_log_dir/"
echo "Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

if [[ $g_fail -gt 0 ]]
then
  exit 1
fi
exit 0
