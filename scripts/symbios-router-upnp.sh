#!/bin/bash
# SymbiOS - Router port forwarding (dispatcher + generic UPnP)
#
# Main entry point for port forwarding management.
# Detects router type and dispatches:
#   FRITZ!Box (AVM)   → symbios-router-fritz.py
#   Generic UPnP      → internal bash SOAP functions (curl + temp files)

SCRIPT_NAME="$(basename "$0")"
UPNP_CONFIG_DIR="/symbios/base-services/symbios-ui/config"
UPNP_CONFIG_FILE="${UPNP_CONFIG_DIR}/router-upnp.conf"
ROUTER_UPNP_USER=""
ROUTER_UPNP_PASS=""

# Load config if present
if [[ -f "$UPNP_CONFIG_FILE" ]]
then
  source "$UPNP_CONFIG_FILE"
fi

# ============================================================
#  JSON field extraction via bash parameter substitution
# ============================================================

function f_json_str {
  local f_json="$1" f_key="$2"
  local f_tmp="${f_json#*\"${f_key}\":\"}"
  [[ "$f_tmp" == "$f_json" ]] && { echo ""; return 1; }
  echo "${f_tmp%%\"*}"
}

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
    if [[ -n "$1" ]] && [[ -n "$2" ]]
    then
      mkdir -p "$UPNP_CONFIG_DIR" 2>/dev/null
      cat > "$UPNP_CONFIG_FILE" <<EOF
# Router credentials for port forwarding
# FRITZ!Box users: set WebUI username and password
# Generic UPnP routers: credentials are optional
ROUTER_UPNP_USER='$1'
ROUTER_UPNP_PASS='$2'
EOF
      chmod 600 "$UPNP_CONFIG_FILE" 2>/dev/null
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
  login|list|add|delete)
    # Detect router type
    DETECT=$(symbios-router-detect.sh 2>/dev/null)
    AVAILABLE=$(f_json_bool "$DETECT" "available")

    if [[ "$AVAILABLE" != "true" ]]
    then
      ERR=$(f_json_str "$DETECT" "error")
      echo "{\"ok\":false,\"error\":\"Router not available: ${ERR}\",\"gateway\":\"${GATEWAY}\"}"
      exit 1
    fi

    ROUTER_TYPE=$(f_json_str "$DETECT" "router_type")

    # FRITZ!Box → Python backend
    if [[ "$ROUTER_TYPE" == "fritzbox" ]]
    then
      if [[ -z "$ROUTER_UPNP_USER" ]]
      then
        echo '{"ok":false,"router_type":"fritzbox","error":"FRITZ!Box credentials not configured. Use '\''config'\'' to set them."}'
        exit 1
      fi

      SCRIPT_DIR="$(dirname "$0")"
      ROUTER_UPNP_USER="$ROUTER_UPNP_USER" \
        ROUTER_UPNP_PASS="$ROUTER_UPNP_PASS" \
        python3 "${SCRIPT_DIR}/symbios-router-fritz.py" \
        "$ACTION" "$@"
      exit $?
    fi

    # Generic UPnP → bash SOAP handlers
    CONTROL_URL=$(f_json_str "$DETECT" "control_url")

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
  add <ext_port> <proto> <int_port> <int_client> [desc]
                                  Add a port forwarding rule
  delete <ext_port> [protocol]    Delete a port forwarding rule
  config [username] [password]    Show or save router credentials

Router types:
  fritzbox (AVM Berlin)
    Uses PBKDF2 login + data.lua API (symbios-router-fritz.py)
    Requires WebUI credentials (config command)
  generic_upnp (TP-Link, Speedport, Ubiquiti, ...)
    Uses TR-064 SOAP (AddPortMapping/DeletePortMapping)
    No authentication needed; config is optional

Credentials stored in: ${UPNP_CONFIG_FILE}
Environment: ROUTER_UPNP_USER, ROUTER_UPNP_PASS
EOHELP
    exit 0
    ;;

  *)
    echo "{\"ok\":false,\"error\":\"Unknown action: ${ACTION}. Use 'help' for usage.\"}"
    exit 1
    ;;
esac
