#!/bin/bash
# SymbiOS - Router port forwarding (dispatcher + generic UPnP)
#
# Main entry point for port forwarding management.
# Detects router type and dispatches:
#   FRITZ!Box (AVM)   → symbios-router-fritz.py
#   Generic UPnP      → internal bash SOAP functions (curl + temp files)

SCRIPT_NAME="$(basename "$0")"
source symbios-lib.sh
UPNP_CONFIG_DIR="${g_config_dir}"

# Router credentials. Primary source of truth is inventory.yml (all.vars
# router_upnp_user / router_upnp_password, written by 'config' or the WebUI).
# A legacy router-upnp.conf (pre-inventory storage) is honoured as a fallback
# and removed by 'config save/remove'.
UPNP_CONFIG_FILE="${UPNP_CONFIG_DIR}/router-upnp.conf"
ROUTER_UPNP_USER="${ROUTER_UPNP_USER:-$(f_symbios_var router_upnp_user '')}"
ROUTER_UPNP_PASS="${ROUTER_UPNP_PASS:-$(f_symbios_var router_upnp_password '')}"
if [[ -z "$ROUTER_UPNP_USER" ]] && [[ -f "$UPNP_CONFIG_FILE" ]]
then
  source "$UPNP_CONFIG_FILE"
fi

# JSON field extraction helpers (f_json_get/f_json_bool in symbios-lib.sh)

function f_json_bool {
  local f_json="$1" f_key="$2"
  local f_tmp="${f_json#*\"${f_key}\":}"
  [[ "$f_tmp" == "$f_json" ]] && { echo "false"; return 1; }
  f_tmp="${f_tmp## }"
  local f_val="${f_tmp%%,*}"
  f_val="${f_val%%\}*}"
  f_val="${f_val%%\]*}"
  echo "$f_val"
}

# ============================================================
#  SOAP helper — builds XML, sends via curl, outputs body + return code
# ============================================================

function f_soap_call {
  local f_gateway="$1" f_control_url="$2" f_action="$3" f_body_xml="$4"
  local f_url="http://${f_gateway}${f_control_url}"
  local f_soap_action="urn:schemas-upnp-org:service:WANIPConnection:1#${f_action}"
  local f_tmpfile
  f_tmpfile=$(mktemp)

  cat > "$f_tmpfile" <<SOAPEOF
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
 <s:Body>
  <u:${f_action} xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
${f_body_xml}
  </u:${f_action}>
 </s:Body>
</s:Envelope>
SOAPEOF

  local f_outfile
  f_outfile=$(mktemp)
  local f_http_code
  f_http_code=$(curl -s -m 10 -X POST \
    -H "Content-Type: text/xml; charset=utf-8" \
    -H "SOAPAction: \"${f_soap_action}\"" \
    -d "@${f_tmpfile}" \
    -o "$f_outfile" \
    -w "%{http_code}" \
    "${f_url}" 2>/dev/null)

  cat "$f_outfile"
  rm -f "$f_tmpfile" "$f_outfile"
  return "$f_http_code"
}

# ============================================================
#  Generic UPnP: list rules via GetGenericPortMappingEntry loop
# ============================================================

function f_upnp_list {
  local f_gateway="$1" f_control_url="$2"
  local f_idx=0 f_first="true" f_jrules="" f_jmappings=""

  while [[ $f_idx -lt 200 ]]
  do
    local f_body="<NewPortMappingIndex>${f_idx}</NewPortMappingIndex>"
    local f_result
    f_result=$(f_soap_call "$f_gateway" "$f_control_url" \
      "GetGenericPortMappingEntry" "$f_body")
    local f_rc=$?

    [[ $f_rc -ne 200 ]] && break

    # Extract fields from SOAP response XML via parameter substitution
    local f_tmp
    f_tmp="${f_result#*<NewExternalPort>}"
    local f_ep="${f_tmp%%</NewExternalPort>*}"

    f_tmp="${f_result#*<NewInternalPort>}"
    local f_ip="${f_tmp%%</NewInternalPort>*}"

    f_tmp="${f_result#*<NewProtocol>}"
    local f_pr="${f_tmp%%</NewProtocol>*}"

    f_tmp="${f_result#*<NewInternalClient>}"
    local f_cl="${f_tmp%%</NewInternalClient>*}"

    f_tmp="${f_result#*<NewEnabled>}"
    local f_en="${f_tmp%%</NewEnabled>*}"

    f_tmp="${f_result#*<NewPortMappingDescription>}"
    local f_de="${f_tmp%%</NewPortMappingDescription>*}"

    if [[ "$f_first" == "true" ]]
    then
      f_jrules="["; f_jmappings="["; f_first="false"
    else
      f_jrules+=","; f_jmappings+=","
    fi

    f_jrules+="{\"port\":\"${f_ep}\",\"fwport\":\"${f_ip}\",\"fwendport\":\"${f_ip}\",\"protocol\":\"${f_pr}\",\"description\":\"${f_de}\",\"activated\":${f_en},\"internal_client\":\"${f_cl}\"}"

    local f_ae="false"
    [[ "$f_en" == "1" ]] && f_ae="true"
    f_jmappings+="{\"external_port\":\"${f_ep}\",\"protocol\":\"${f_pr}\",\"internal_client\":\"${f_cl}\",\"internal_port\":\"${f_ip}\",\"description\":\"${f_de}\",\"enabled\":${f_ae}}"

    f_idx=$((f_idx + 1))
  done

  if [[ "$f_first" == "true" ]]
  then
    echo '{"ok":true,"router_type":"generic_upnp","rules":[],"mappings":[]}'
  else
    echo "{\"ok\":true,\"router_type\":\"generic_upnp\",\"rules\":${f_jrules}],\"mappings\":${f_jmappings}]}"
  fi
}

# ============================================================
#  Generic UPnP: add / delete port mapping
# ============================================================

function f_upnp_add {
  local f_gateway="$1" f_control_url="$2"
  local f_ext_port="$3" f_proto="$4" f_int_port="$5" f_int_client="$6" f_desc="$7"

  local f_body
  f_body=$(cat <<SOAPBODY
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>${f_ext_port}</NewExternalPort>
<NewProtocol>${f_proto}</NewProtocol>
<NewInternalPort>${f_int_port}</NewInternalPort>
<NewInternalClient>${f_int_client}</NewInternalClient>
<NewEnabled>1</NewEnabled>
<NewPortMappingDescription>${f_desc}</NewPortMappingDescription>
<NewLeaseDuration>0</NewLeaseDuration>
SOAPBODY
)

  local f_result
  f_result=$(f_soap_call "$f_gateway" "$f_control_url" \
    "AddPortMapping" "$f_body")
  local f_rc=$?

  if [[ "$f_rc" -eq 200 ]]
  then
    echo "{\"ok\":true,\"router_type\":\"generic_upnp\",\"message\":\"Port forwarding added: ${f_proto}/${f_ext_port} → ${f_int_client}:${f_int_port}\"}"
  else
    local f_tmp="${f_result#*<errorDescription>}"
    local f_err="${f_tmp%%</errorDescription>*}"
    [[ -z "$f_err" ]] && f_err="SOAP error (HTTP ${f_rc})"
    echo "{\"ok\":false,\"router_type\":\"generic_upnp\",\"error\":\"${f_err}\"}"
  fi
}

function f_upnp_delete {
  local f_gateway="$1" f_control_url="$2" f_ext_port="$3" f_proto="$4"

  local f_body
  f_body=$(cat <<SOAPBODY
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>${f_ext_port}</NewExternalPort>
<NewProtocol>${f_proto}</NewProtocol>
SOAPBODY
)

  local f_result
  f_result=$(f_soap_call "$f_gateway" "$f_control_url" \
    "DeletePortMapping" "$f_body")
  local f_rc=$?

  if [[ "$f_rc" -eq 200 ]]
  then
    echo "{\"ok\":true,\"router_type\":\"generic_upnp\",\"message\":\"Port forwarding deleted: ${f_proto}/${f_ext_port}\"}"
  else
    local f_tmp="${f_result#*<errorDescription>}"
    local f_err="${f_tmp%%</errorDescription>*}"
    [[ -z "$f_err" ]] && f_err="SOAP error (HTTP ${f_rc})"
    echo "{\"ok\":false,\"router_type\":\"generic_upnp\",\"error\":\"${f_err}\"}"
  fi
}

# ============================================================
#  Main dispatch
# ============================================================

GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
ACTION="${1:-help}"
shift 2>/dev/null || true

if [[ -z "$GATEWAY" ]]
then
  echo '{"ok":false,"error":"Could not detect default gateway"}'
  exit 1
fi

case "$ACTION" in

  # ------------------------------------------------------------------
  detect)
    exec symbios-router-detect.sh
    ;;

  # ------------------------------------------------------------------
  config)
    # Remove stored credentials (e.g. from the WebUI "Remove credentials").
    if [[ "$1" == "remove" ]]
    then
      f_symbios_var_set router_upnp_user ""
      f_symbios_var_set router_upnp_password ""
      rm -f "$UPNP_CONFIG_FILE"
      echo '{"ok":true,"configured":false,"message":"Router credentials removed."}'
      exit 0
    fi

    if [[ -n "$1" ]] && [[ -n "$2" ]]
    then
      f_symbios_var_set router_upnp_user "$1"
      f_symbios_var_set router_upnp_password "$2"
      rm -f "$UPNP_CONFIG_FILE"
      echo '{"ok":true,"message":"Router credentials saved."}'
      exit 0
    fi

    if [[ -n "$ROUTER_UPNP_USER" ]]
    then
      echo "{\"ok\":true,\"configured\":true,\"username\":\"${ROUTER_UPNP_USER}\",\"gateway\":\"${GATEWAY}\"}"
    else
      echo "{\"ok\":true,\"configured\":false,\"gateway\":\"${GATEWAY}\"}"
    fi
    exit 0
    ;;

  # ------------------------------------------------------------------
  login|list|add|delete|staticip|unset-staticip|ipv6info)
    # Detect router type
    DETECT=$(symbios-router-detect.sh 2>/dev/null)
    AVAILABLE=$(f_json_bool "$DETECT" "available")

    if [[ "$AVAILABLE" != "true" ]]
    then
      ERR=$(f_json_get "$DETECT" "error")
      echo "{\"ok\":false,\"error\":\"Router not available: ${ERR}\",\"gateway\":\"${GATEWAY}\"}"
      exit 1
    fi

    ROUTER_TYPE=$(f_json_get "$DETECT" "router_type")

    # FRITZ!Box → Python backend
    if [[ "$ROUTER_TYPE" == "fritzbox" ]]
    then
      if [[ -z "$ROUTER_UPNP_USER" ]]
      then
        echo '{"ok":false,"router_type":"fritzbox","error":"FRITZ!Box credentials not configured. Use '\''config'\'' to set them."}'
        exit 1
      fi

      SCRIPT_DIR="$(dirname "$0")"
      RESULT=$(ROUTER_UPNP_USER="$ROUTER_UPNP_USER" \
        ROUTER_UPNP_PASS="$ROUTER_UPNP_PASS" \
        python3 "${SCRIPT_DIR}/symbios-router-fritz.py" \
        "$ACTION" "$@")
      RC=$?

      # Manage UFW allow rules for IPv6 port forwards.
      # FRITZ!Box IPv6 forwards connect directly to the host's GUA, so
      # the host firewall must explicitly allow forwarded traffic on the port.
      if [[ $RC -eq 0 ]]; then
        OK=$(f_json_bool "$RESULT" "ok")
        if [[ "$OK" == "true" ]]; then
          case "$ACTION" in
            add)
              ACCESSTYPE=$(f_json_get "$RESULT" "accesstype")
              if [[ "$ACCESSTYPE" == "ipv6" ]] || [[ "$ACCESSTYPE" == "ipv4_ipv6" ]]; then
                # Comment marks script-created rules so delete only removes them,
                # never rules managed by firewall.yml (e.g. direct SSH on port 33).
                ufw allow "$1/${2,,}" comment 'symbios-upnp' 2>/dev/null || true
              fi
              ;;
            delete)
              DEL_ACCESSTYPE=$(f_json_get "$RESULT" "accesstype")
              # Only remove UFW rule for IPv6 forwards. Rules for ports that are
              # also direct host services (e.g. SSH) are managed by firewall.yml.
              if [[ "$DEL_ACCESSTYPE" == "ipv6" ]] || [[ "$DEL_ACCESSTYPE" == "ipv4_ipv6" ]]; then
                ufw delete allow "$1/${2,,}" comment 'symbios-upnp' 2>/dev/null || true
              fi
              ;;
          esac
        fi
      fi

      echo "$RESULT"
      exit $RC
    fi

    # Generic UPnP → bash SOAP handlers
    CONTROL_URL=$(f_json_get "$DETECT" "control_url")

    if [[ -z "$CONTROL_URL" ]]
    then
      echo '{"ok":false,"router_type":"generic_upnp","error":"No WANIPConnection control URL found on this router. Try '\''detect'\'' for details."}'
      exit 1
    fi

    case "$ACTION" in
      login)
        echo '{"ok":true,"router_type":"generic_upnp","note":"UPnP does not require authentication. Credentials in config are for FRITZ!Box only."}'
        ;;
      list)
        f_upnp_list "$GATEWAY" "$CONTROL_URL"
        ;;
      add)
        EXT_PORT="$1" PROTO="$2" INT_PORT="$3" INT_CLIENT="$4" DESC="${5:-SymbiOS}"
        if [[ -z "$EXT_PORT" ]] || [[ -z "$PROTO" ]] || [[ -z "$INT_PORT" ]] || [[ -z "$INT_CLIENT" ]]
        then
          echo '{"ok":false,"error":"Usage: add <ext_port> <protocol> <int_port> <int_client> [description]"}'
          exit 1
        fi
        f_upnp_add "$GATEWAY" "$CONTROL_URL" "$EXT_PORT" "$PROTO" "$INT_PORT" "$INT_CLIENT" "$DESC"
        ;;
      delete)
        EXT_PORT="$1" PROTO="${2:-TCP}"
        if [[ -z "$EXT_PORT" ]]
        then
          echo '{"ok":false,"error":"Usage: delete <ext_port> [protocol]"}'
          exit 1
        fi
        f_upnp_delete "$GATEWAY" "$CONTROL_URL" "$EXT_PORT" "$PROTO"
        ;;
    esac
    exit $?
    ;;

  # ------------------------------------------------------------------
  help|--help|-h)
    cat <<EOHELP
Usage: ${SCRIPT_NAME} <action> [args...]

Auto-detects router type (FRITZ!Box vs generic UPnP) on every action.

Actions:
  detect                          Probe router and show type, model
  login                           Test auth (FRITZ!Box) or show UPnP status
  list                            List port forwarding rules
  add <ext_port> <proto> <int_port> <int_client> [desc] [accesstype]
                                  Add a port forwarding rule
                                  (accesstype: ipv4|ipv6|ipv4_ipv6)
  delete <ext_port> [protocol]    Delete a port forwarding rule
  config [username] [password]    Show or save router credentials
                                  (use 'config remove' to delete them)
  ipv6info                        Show IPv6 state and device addresses
                                  (FRITZ!Box, read-only)

Router types:
  fritzbox (AVM Berlin)
    Uses PBKDF2 login + data.lua API (symbios-router-fritz.py)
    Requires WebUI credentials (config command)
  generic_upnp (TP-Link, Speedport, Ubiquiti, ...)
    Uses TR-064 SOAP (AddPortMapping/DeletePortMapping)
    No authentication needed; config is optional

Credentials stored in: ${g_inventory} (all.vars router_upnp_user/router_upnp_password)
Environment: ROUTER_UPNP_USER, ROUTER_UPNP_PASS
EOHELP
    exit 0
    ;;

  *)
    echo "{\"ok\":false,\"error\":\"Unknown action: ${ACTION}. Use 'help' for usage.\"}"
    exit 1
    ;;
esac
