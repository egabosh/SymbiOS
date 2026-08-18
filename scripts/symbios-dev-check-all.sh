#!/bin/bash
# SymbiOS - Comprehensive service test script
#
# Dynamically reads # docs: metadata from each services/*.yml playbook
# and runs all defined actions (install, stop, start, restart, uninstall, etc.).
#
# Usage:
#   symbios-dev-check-all.sh <hostname> [base_domain] [--service <name>]
#
# Examples:
#   symbios-dev-check-all.sh symbios-dev.dedyn.io
#   symbios-dev-check-all.sh symbios-dev.dedyn.io symbios-dev.dedyn.io --service navidrome

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
g_ssh_port=44
g_ssh_user=root
g_sudo_user=symbios
g_insecure=(-k -s)
g_log_dir="/tmp/symbios-check-$$"
g_total=0
g_pass=0
g_fail=0
g_skip=0
declare -A g_results
g_filter_services=()
g_services_json=""

# --- Helper: SSH ---

function f_ssh {
  local f_cmd="$1"
  ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -p "$g_ssh_port" \
    "${g_ssh_user}@${g_hostname}" \
    "export PATH=\"/symbios/git/SymbiOS/scripts:\$PATH\"; bash -c \"$f_cmd\"" 2>/dev/null
}

function f_ssh_sudo {
  local f_cmd="$1"
  ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -p "$g_ssh_port" \
    "${g_sudo_user}@${g_hostname}" \
    "export PATH=\"/symbios/git/SymbiOS/scripts:\$PATH\"; sudo bash -c \"export PATH=\\\"/symbios/git/SymbiOS/scripts:\\\$PATH\\\"; $f_cmd\"" 2>/dev/null
}

function f_ssh_try {
  local f_cmd="$1"
  local f_result
  f_result=$(f_ssh "$f_cmd" 2>&1)
  local f_rc=$?
  if [[ $f_rc -ne 0 ]]
  then
    f_result=$(f_ssh_sudo "$f_cmd" 2>&1)
    f_rc=$?
  fi
  echo "$f_result"
  return $f_rc
}

function f_ssh_ok {
  f_ssh "echo ok" &>/dev/null
}

# --- Helper: Display ---

function f_usage {
  echo "Usage: $(basename "$0") <hostname> [base_domain] [--service <name>]"
  echo ""
  echo "Arguments:"
  echo "  hostname      SymbiOS server hostname or IP"
  echo "  base_domain   Domain for HTTP checks (e.g. symbios-dev.dedyn.io)"
  echo "  --service X   Only test service X (can be repeated)"
  echo ""
  echo "Discovers services dynamically from services/*.yml playbook # docs: blocks."
  echo "Standard password: test1234"
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

  # SCP to host, run, clean up
  scp -o StrictHostKeyChecking=no -P "$g_ssh_port" \
    "$f_script" "${g_ssh_user}@${g_hostname}:/tmp/symbios-extract.sh" 2>/dev/null
  rm -f "$f_script"

  f_ssh_try "chmod +x /tmp/symbios-extract.sh && bash /tmp/symbios-extract.sh"
  f_ssh_try "rm -f /tmp/symbios-extract.sh"
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
    if [[ -n "$f_compose_file" ]]
    then
      local f_up
      f_up=$(f_ssh_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
      f_up="${f_up//[^0-9]/}"
      if [[ -n "$f_up" && "$f_up" -gt 0 ]]
      then
        return 0
      fi
    else
      local f_bad
      f_bad=$(f_ssh_try "docker ps -a --format '{{.Status}}' 2>/dev/null | grep -c -E '(Restarting|Exited)' || true" 2>/dev/null)
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
  f_result=$(f_ssh_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
  f_result="${f_result//[^0-9]/}"
  [[ -n "$f_result" && "$f_result" -gt 0 ]]
}

function f_check_no_containers {
  local f_compose_file="$1"
  local f_result
  f_result=$(f_ssh_try "docker compose -f $f_compose_file ps 2>/dev/null | grep -c ' Up ' || true" 2>/dev/null)
  f_result="${f_result//[^0-9]/}"
  [[ -z "$f_result" || "$f_result" == "0" ]]
}

function f_check_container_running {
  local f_name="$1"
  local f_result
  f_result=$(f_ssh_try "docker ps --format '{{.Names}}' | grep -w '$f_name' || true" 2>/dev/null)
  [[ -n "$f_result" ]]
}

# --- Helper: Playbook/Service ---

function f_run_playbook {
  local f_playbook="$1"
  f_ssh_try "symbios-run-playbook.sh '$f_playbook'" 2>&1
}

function f_uninstall_service {
  local f_playbook="$1"
  local f_mode="$2"
  f_ssh_try "symbios-uninstall.sh '$f_playbook' '$f_mode'" 2>&1
}

function f_check_no_dir {
  local f_path="$1"
  f_ssh_try "test ! -d '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_dir_exists {
  local f_path="$1"
  f_ssh_try "test -d '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_file_exists {
  local f_path="$1"
  f_ssh_try "test -f '$f_path' && echo yes || echo no" 2>/dev/null | grep -q "yes"
}

function f_check_dir_empty {
  local f_path="$1"
  f_ssh_try "find '$f_path' -maxdepth 1 -mindepth 1 -print -quit 2>/dev/null | grep -q . || echo empty" 2>/dev/null | grep -q "empty"
}

function f_http_check {
  local f_url="$1"
  local f_expected="${2:-200}"
  local f_code
  f_code=$(f_ssh_try "curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 '$f_url' 2>/dev/null" 2>/dev/null)
  f_code="${f_code//[^0-9]/}"
  [[ "$f_code" == "$f_expected" ]]
}

# --- Parse arguments ---

while [[ $# -gt 0 ]]
do
  case "$1" in
    --service)
      shift
      g_filter_services+=("$1")
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
  f_usage
  exit 1
fi

if [[ -z "$g_base_domain" ]]
then
  g_base_domain="$g_hostname"
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

if f_ssh_ok
then
  f_result "SSH connectivity" PASS
else
  f_result "SSH connectivity" FAIL "Cannot SSH to $g_hostname:$g_ssh_port"
  echo -e "\n${f_red}Cannot proceed without SSH access. Aborting.${f_reset}"
  exit 1
fi

for f_container in traefik openldap authelia symbios-webui
do
  if f_check_container_running "$f_container"
  then
    f_result "Container: $f_container" PASS
  else
    f_result "Container: $f_container" FAIL "Not running"
  fi
done

if f_ssh_try "docker info &>/dev/null" &>/dev/null
then
  f_result "Docker daemon" PASS
else
  f_result "Docker daemon" FAIL "Docker not responding"
fi

if f_ssh_try "which symbios-run-playbook.sh" &>/dev/null
then
  f_result "symbios-run-playbook.sh in PATH" PASS
else
  f_result "symbios-run-playbook.sh in PATH" FAIL "Not found in PATH"
fi

if f_ssh_try "which symbios-uninstall.sh" &>/dev/null
then
  f_result "symbios-uninstall.sh in PATH" PASS
else
  f_result "symbios-uninstall.sh in PATH" FAIL "Not found in PATH"
fi

if f_ssh_try "which yq" &>/dev/null
then
  f_result "yq on host" PASS
else
  f_result "yq on host" FAIL "yq not found - cannot extract playbook metadata"
  echo -e "\n${f_red}Cannot proceed without yq. Aborting.${f_reset}"
  exit 1
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

  # Extract program_paths and userdata_paths arrays
  f_program_paths=$(f_json_get_array "$f_svc_json" ".uninstall.program_paths")
  f_userdata_paths=$(f_json_get_array "$f_svc_json" ".uninstall.userdata_paths")

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
  f_ssh_try "rm -rf /symbios/services/$f_name" >/dev/null 2>&1

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
  # Phase 2: Idempotency
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 2: Idempotency ---${f_reset}"

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
        f_result "Phase 2: Idempotent (no changes)" PASS
      else
        f_result "Phase 2: Idempotent (no changes)" FAIL "changed=$f_changed on second run"
      fi
    else
      f_result "Phase 2: Idempotent (no errors)" FAIL "failures=$f_failures2 (see $f_log2)"
    fi
  else
    f_result "Phase 2: Idempotent" FAIL "Playbook failed on second run (see $f_log2)"
  fi

  # =========================================================================
  # Phase 3: Actions - stop, start, restart, reload (from docs: actions block)
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 3: Actions (from docs: actions) ---${f_reset}"

  # --- Stop action ---
  if [[ -n "$f_action_stop" ]]
  then
    echo "  Running: $f_action_stop"
    f_ssh_try "$f_action_stop" >/dev/null 2>&1
    sleep 3

    if f_check_no_containers "$f_compose"
    then
      f_result "Phase 3: actions.stop" PASS
    else
      f_result "Phase 3: actions.stop" FAIL "Containers still running after stop"
    fi
  else
    echo "  No actions.stop defined, using docker compose down"
    f_ssh_try "cd $(dirname "$f_compose") && docker compose down" >/dev/null 2>&1
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
    f_ssh_try "$f_action_start" >/dev/null 2>&1
  else
    echo "  No actions.start defined, using docker compose up -d"
    f_ssh_try "cd $(dirname "$f_compose") && docker compose up -d" >/dev/null 2>&1
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
    f_ssh_try "$f_action_restart" >/dev/null 2>&1
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
    f_ssh_try "$f_action_reload" >/dev/null 2>&1
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
  # Phase 4: Uninstall (full)
  # =========================================================================
  echo -e "\n  ${f_blue}--- Phase 4: Uninstall (full) ---${f_reset}"

  f_output4=$(f_uninstall_service "$f_playbook" "full" 2>&1)
  f_rc4=$?
  f_log4="$g_log_dir/${f_name}_uninstall_full.log"
  echo "$f_output4" > "$f_log4"

  sleep 3

  # Verify no containers running for this compose
  if f_check_no_containers "$f_compose"
  then
    f_result "Phase 4: Containers removed" PASS
  else
    f_result "Phase 4: Containers removed" FAIL "Containers still running"
  fi

  # Verify all program_paths are removed
  # Note: symbios-uninstall.sh removes files inside directories but keeps the
  # directory structure for program_paths. Only userdata_paths uses rm -rf.
  f_pp_removed=0
  f_pp_total=0
  while IFS= read -r f_path
  do
    [[ -z "$f_path" ]] && continue
    f_pp_total=$((f_pp_total + 1))
    if [[ "$f_path" == */ ]]
    then
      # Directory: check that it's empty (no files/symlinks inside)
      if f_check_dir_empty "$f_path"
      then
        f_pp_removed=$((f_pp_removed + 1))
      fi
    else
      # File: check that it's gone
      if ! f_check_file_exists "$f_path"
      then
        f_pp_removed=$((f_pp_removed + 1))
      fi
    fi
  done <<< "$f_program_paths"

  if [[ $f_pp_total -eq 0 ]]
  then
    f_result "Phase 4: program_paths removed" SKIP "No program_paths defined"
  elif [[ $f_pp_removed -eq $f_pp_total ]]
  then
    f_result "Phase 4: program_paths removed ($f_pp_total/$f_pp_total)" PASS
  else
    f_result "Phase 4: program_paths removed ($f_pp_removed/$f_pp_total)" FAIL "Some program paths remain"
  fi

  # Verify state entry removed
  f_state_check=$(f_ssh_try "grep -c 'services/$f_name.yml' /symbios/base-services/symbios-ui/config/installed-playbooks.yml || true" 2>/dev/null)
  f_state_check="${f_state_check//[^0-9]/}"
  if [[ -z "$f_state_check" || "$f_state_check" == "0" ]]
  then
    f_result "Phase 4: State entry removed" PASS
  else
    f_result "Phase 4: State entry removed" FAIL "Entry still in installed-playbooks.yml"
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

  # Run reset
  f_output5=$(f_uninstall_service "$f_playbook" "reset" 2>&1)
  f_rc5=$?
  f_log5="$g_log_dir/${f_name}_reset.log"
  echo "$f_output5" > "$f_log5"

  sleep 3

  # After reset: program dir should still exist, userdata should be gone
  if f_check_compose_up "$f_compose"
  then
    f_result "Phase 5: Reset - containers restarted" PASS
  else
    if f_check_dir_exists "/symbios/services/$f_name"
    then
      f_result "Phase 5: Reset - program dir preserved" PASS
    else
      f_result "Phase 5: Reset" FAIL "Program dir removed by reset"
    fi
  fi

  # Verify userdata_paths are removed or reset (empty after recreation)
  # Note: reset mode deletes userdata then restarts, so dirs may be recreated
  f_ud_removed=0
  f_ud_total=0
  while IFS= read -r f_path
  do
    [[ -z "$f_path" ]] && continue
    f_ud_total=$((f_ud_total + 1))
    if f_check_no_dir "$f_path" || f_check_dir_empty "$f_path"
    then
      f_ud_removed=$((f_ud_removed + 1))
    fi
  done <<< "$f_userdata_paths"

  if [[ $f_ud_total -eq 0 ]]
  then
    f_result "Phase 5: userdata_paths removed" SKIP "No userdata_paths defined"
  elif [[ $f_ud_removed -eq $f_ud_total ]]
  then
    f_result "Phase 5: userdata_paths removed ($f_ud_removed/$f_ud_total)" PASS
  else
    f_result "Phase 5: userdata_paths removed ($f_ud_removed/$f_ud_total)" FAIL "Some userdata paths remain"
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
  # Phase 7: HTTP check (only if url is defined)
  # =========================================================================
  if [[ -n "$f_url" ]]
  then
    echo -e "\n  ${f_blue}--- Phase 7: HTTP check ---${f_reset}"

    # Give Traefik time to detect new container labels
    sleep 5

    if f_http_check "$f_url" "200"
    then
      f_result "Phase 7: HTTP -> 200" PASS
    elif f_http_check "$f_url" "302" || f_http_check "$f_url" "401"
    then
      f_result "Phase 7: HTTP -> auth redirect (expected)" PASS
    else
      f_result "Phase 7: HTTP check" FAIL "Not reachable: $f_url"
    fi
  else
    echo -e "\n  ${f_blue}--- Phase 7: HTTP check ---${f_reset}"
    f_result "Phase 7: HTTP check" SKIP "No url defined (service uses raw ports)"
  fi

  # =========================================================================
  # Cleanup: uninstall to leave system clean
  # =========================================================================
  echo -e "\n  ${f_blue}--- Cleanup ---${f_reset}"
  f_uninstall_service "$f_playbook" "full" >/dev/null 2>&1
  f_result "Cleanup: $f_name uninstalled" PASS

done

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
