#!/bin/bash
# SymbiOS - Router port forwarding via UPnP IGD / TR-064
# Communicates with the default gateway via TR-064 (WANIPConnection:1)
# on port 49000 using proper two-step Digest auth (avoiding curl --digest bug).
# Outputs JSON for WebUI consumption.

# --- Configuration ---
SCRIPT_NAME="$(basename "$0")"
HOST_PORT=49000
CONTROL_PATH="/upnp/control/wanipconnection1"
NS="urn:dslforum-org:service:WANIPConnection:1"
CURL_TIMEOUT=10

UPNP_CONFIG_DIR="/home/docker/symbios-ui/config"
UPNP_CONFIG_FILE="${UPNP_CONFIG_DIR}/router-upnp.conf"
ROUTER_UPNP_USER=""
ROUTER_UPNP_PASS=""

# --- Helpers ---

function f_detect_gateway {
  local f_gw
  f_gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
  if [[ -z "$f_gw" ]]
  then
    echo ""
    return 1
  fi
  echo "$f_gw"
}

function f_probe_gateway {
  local f_gateway="$1"
  local f_url="http://${f_gateway}:${HOST_PORT}/tr64desc.xml"
  local f_xml
  f_xml=$(curl -s -m 5 "$f_url" 2>/dev/null)
  if [[ -z "$f_xml" ]]
  then
    return 1
  fi

  python3 -c "
import sys, xml.etree.ElementTree as ET, json

try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    print(json.dumps({'available': False, 'error': 'XML parse error'}))
    sys.exit(0)

ns = {'root': 'urn:dslforum-org:device-1-0'}
device = root.find('.//root:device', ns)
if device is None:
    device = root.find('.//{urn:schemas-upnp-org:device-1-0}device')
if device is None:
    device = root.find('.//device')

if device is None:
    print(json.dumps({'available': False, 'error': 'No device element found'}))
    sys.exit(0)

def tag_text(e, name):
    el = e.find(name)
    if el is None:
        el = e.find('{urn:schemas-upnp-org:device-1-0}' + name)
    if el is None:
        el = e.find('{urn:dslforum-org:device-1-0}' + name)
    return (el.text or '') if el is not None else ''

result = {
    'available': True,
    'manufacturer': tag_text(device, 'manufacturer'),
    'model': tag_text(device, 'modelName'),
    'model_number': tag_text(device, 'modelNumber'),
    'friendly_name': tag_text(device, 'friendlyName'),
    'firmware_version': tag_text(device, 'firmwareVersion'),
    'presentation_url': tag_text(device, 'presentationURL'),
}
print(json.dumps(result))
" <<< "$f_xml"
  return 0
}

function f_build_body {
  local action="$1"
  local inner="${2:-}"
  if [[ -n "$inner" ]]
  then
    echo '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:'"$action"' xmlns:u="'"$NS"'">'"$inner"'</u:'"$action"'></s:Body></s:Envelope>'
  else
    echo '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:'"$action"' xmlns:u="'"$NS"'"/></s:Body></s:Envelope>'
  fi
}

function f_soap_call {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"
  local action="$4"
  local inner="${5:-}"

  local body
  body=$(f_build_body "$action" "$inner")
  local soapaction="${NS}#${action}"
  local url="http://${f_host}:${HOST_PORT}${CONTROL_PATH}"

  local resp1
  resp1=$(curl -s -m "$CURL_TIMEOUT" -D - \
    -H "Content-Type: text/xml" \
    -H "SOAPAction: ${soapaction}" \
    -d "$body" \
    "$url" 2>/dev/null)

  local status1
  status1=$(echo "$resp1" | head -1 | awk '{print $2}')

  if [[ "$status1" == "200" ]]
  then
    echo "$resp1" | sed -n '/^\r$/,$ p' | tail -n +2
    return 0
  fi

  if [[ "$status1" != "401" ]]
  then
    local f_body1
    f_body1=$(echo "$resp1" | sed -n '/^\r$/,$ p' | tail -n +2)
    if echo "$f_body1" | grep -qi "errorCode\|UPnPError\|s:Fault" >/dev/null 2>&1
    then
      local f_err_desc
      f_err_desc=$(echo "$f_body1" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'<errorDescription>([^<]*)', xml)
if m: print(m.group(1))
m2 = re.search(r'<errorCode>([^<]+)', xml)
if m2: print(f' (code {m2.group(1)})')
" 2>/dev/null)
      echo '{"ok":false,"error":"Router error: '"$f_err_desc"'"}'
      return 1
    fi
    echo "$f_body1"
    return 0
  fi

  local www_auth
  www_auth=$(echo "$resp1" | grep -i "^WWW-Authenticate:" | sed 's/[Ww][Ww][Ww]-[Aa]uthenticate: //i' | tr -d '\r\n')

  if [[ -z "$www_auth" ]]
  then
    echo '{"ok":false,"error":"No WWW-Authenticate header in 401 response"}'
    return 1
  fi

  local realm nonce qop
  realm=$(echo "$www_auth" | sed 's/.*realm="\([^"]*\)".*/\1/')
  nonce=$(echo "$www_auth" | sed 's/.*nonce="\([^"]*\)".*/\1/')
  qop=$(echo "$www_auth" | sed 's/.*qop="\([^"]*\)".*/\1/')

  local auth_header
  auth_header=$(python3 -c "
import hashlib, random, sys

user = sys.argv[1]
pw = sys.argv[2]
realm = sys.argv[3]
nonce = sys.argv[4]
path = sys.argv[5]
qop = sys.argv[6] if len(sys.argv) > 6 else ''

cnonce = hashlib.md5(str(random.random()).encode()).hexdigest()[:16]
nc = '00000001'

ha1 = hashlib.md5(f'{user}:{realm}:{pw}'.encode()).hexdigest()
ha2 = hashlib.md5(f'POST:{path}'.encode()).hexdigest()

if qop:
    resp_hash = hashlib.md5(f'{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}'.encode()).hexdigest()
    auth = f'Digest username=\"{user}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{path}\", algorithm=MD5, qop={qop}, nc={nc}, cnonce=\"{cnonce}\", response=\"{resp_hash}\"'
else:
    resp_hash = hashlib.md5(f'{ha1}:{nonce}:{ha2}'.encode()).hexdigest()
    auth = f'Digest username=\"{user}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{path}\", algorithm=MD5, response=\"{resp_hash}\"'

print(auth)
" "$f_user" "$f_pass" "$realm" "$nonce" "$CONTROL_PATH" "$qop" 2>/dev/null)

  if [[ -z "$auth_header" ]]
  then
    echo '{"ok":false,"error":"Failed to compute Digest auth"}'
    return 1
  fi

  local resp2
  resp2=$(curl -s -m "$CURL_TIMEOUT" -D - \
    -H "Content-Type: text/xml" \
    -H "SOAPAction: ${soapaction}" \
    -H "Authorization: ${auth_header}" \
    -d "$body" \
    "$url" 2>/dev/null)

  local status2
  status2=$(echo "$resp2" | head -1 | awk '{print $2}')
  local body2
  body2=$(echo "$resp2" | sed -n '/^\r$/,$ p' | tail -n +2)

  if [[ "$status2" == "200" ]]
  then
    echo "$body2"
    return 0
  fi

  local error_desc
  error_desc=$(echo "$body2" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'<errorDescription>([^<]*)', xml)
if m: print(m.group(1))
else: print('HTTP $status2')
" 2>/dev/null)

  local error_code
  error_code=$(echo "$body2" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'<errorCode>([^<]+)', xml)
if m: print(m.group(1))
else: print('')
" 2>/dev/null)

  if [[ -n "$error_code" ]]
  then
    echo '{"ok":false,"error":"Router error: '"$error_desc"' (code '"$error_code"')"}'
  else
    echo '{"ok":false,"error":"'"$error_desc"'"}'
  fi
  return 1
}

function f_get_count {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"
  local f_result
  f_result=$(f_soap_call "$f_host" "$f_user" "$f_pass" "GetPortMappingNumberOfEntries")
  local f_count
  f_count=$(echo "$f_result" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'<NewPortMappingNumberOfEntries>([^<]+)', xml)
print(int(m.group(1)) if m else 0)
" 2>/dev/null)
  echo "$f_count"
}

function f_list_mappings {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"

  local f_count
  f_count=$(f_get_count "$f_host" "$f_user" "$f_pass") || {
    echo '{"ok":false,"error":"Failed to get mapping count","mappings":[]}'
    return 1
  }

  if ! [[ "$f_count" =~ ^[0-9]+$ ]]
  then
    echo '{"ok":false,"error":"Invalid mapping count: '"$f_count"'","mappings":[]}'
    return 1
  fi

  local f_mappings="["
  local f_first=true
  local f_idx

  for ((f_idx=0; f_idx<f_count; f_idx++))
  do
    local f_xml
    f_xml=$(f_soap_call "$f_host" "$f_user" "$f_pass" "GetGenericPortMappingEntry" "<NewPortMappingIndex>${f_idx}</NewPortMappingIndex>") || continue

    local f_entry
    f_entry=$(echo "$f_xml" | python3 -c "
import sys, re, json
xml = sys.stdin.read()
vals = {}
for m in re.finditer(r'<(?:[^:>]*:)?(\w+)>([^<]+)</(?:[^:>]*:)?\1>', xml):
    vals[m.group(1)] = m.group(2).strip()
ep = vals.get('NewExternalPort', '0')
try:
    ext_port = int(ep)
except ValueError:
    ext_port = 0
iport = vals.get('NewInternalPort', '0')
try:
    int_port = int(iport)
except ValueError:
    int_port = 0
ld = vals.get('NewLeaseDuration', '0')
try:
    lease = int(ld)
except ValueError:
    lease = 0
entry = {
    'index': ${f_idx},
    'remote_host': vals.get('NewRemoteHost', ''),
    'external_port': ext_port,
    'external_port_range': ep if ext_port == 0 and ep != '0' else '',
    'protocol': vals.get('NewProtocol', ''),
    'internal_port': int_port,
    'internal_client': vals.get('NewInternalClient', ''),
    'enabled': vals.get('NewEnabled', '0') == '1',
    'description': vals.get('NewPortMappingDescription', ''),
    'lease_duration': lease,
}
print(json.dumps(entry))
" 2>/dev/null)

    if [[ -n "$f_entry" ]]
    then
      if [[ "$f_first" == true ]]
      then
        f_first=false
      else
        f_mappings+=","
      fi
      f_mappings+="$f_entry"
    fi
  done

  f_mappings+="]"
  echo '{"ok":true,"count":'"$f_count"',"mappings":'"$f_mappings"'}'
}

function f_check_duplicate {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"
  local f_ext_port="$4"
  local f_proto="$5"
  local f_proto_upper
  f_proto_upper=$(echo "$f_proto" | tr '[:lower:]' '[:upper:]')

  local f_mappings_json
  f_mappings_json=$(f_list_mappings "$f_host" "$f_user" "$f_pass") || return 1

  python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for m in data.get('mappings', []):
    if str(m.get('external_port')) == '${f_ext_port}' and m.get('protocol', '').upper() == '${f_proto_upper}':
        print(json.dumps({'duplicate': True, 'existing': m}))
        sys.exit(0)
print(json.dumps({'duplicate': False}))
" <<< "$f_mappings_json" 2>/dev/null

  return $?
}

function f_add_mapping {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"
  local f_ext_port="$4"
  local f_proto="$5"
  local f_int_port="$6"
  local f_int_client="$7"
  local f_desc="${8:-SymbiOS}"

  if ! [[ "$f_ext_port" =~ ^[0-9]+$ ]] || [[ "$f_ext_port" -lt 1 ]] || [[ "$f_ext_port" -gt 65535 ]]
  then
    echo '{"ok":false,"error":"Invalid external port number"}'
    return 1
  fi
  if ! [[ "$f_int_port" =~ ^[0-9]+$ ]] || [[ "$f_int_port" -lt 1 ]] || [[ "$f_int_port" -gt 65535 ]]
  then
    echo '{"ok":false,"error":"Invalid internal port number"}'
    return 1
  fi

  local f_proto_upper
  f_proto_upper=$(echo "$f_proto" | tr '[:lower:]' '[:upper:]')
  if [[ "$f_proto_upper" != "TCP" ]] && [[ "$f_proto_upper" != "UDP" ]]
  then
    echo '{"ok":false,"error":"Protocol must be TCP or UDP"}'
    return 1
  fi

  if ! [[ "$f_int_client" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
  then
    echo '{"ok":false,"error":"Invalid internal client IP address"}'
    return 1
  fi

  local f_inner="<NewRemoteHost>0.0.0.0</NewRemoteHost><NewExternalPort>${f_ext_port}</NewExternalPort><NewProtocol>${f_proto_upper}</NewProtocol><NewInternalPort>${f_int_port}</NewInternalPort><NewInternalClient>${f_int_client}</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>${f_desc}</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration>"

  local f_result
  f_result=$(f_soap_call "$f_host" "$f_user" "$f_pass" "AddPortMapping" "$f_inner") || {
    if echo "$f_result" | grep -q '"ok":false'
    then
      echo "$f_result"
    else
      echo '{"ok":false,"error":"AddPortMapping failed"}'
    fi
    return 1
  }

  if echo "$f_result" | grep -q "AddPortMappingResponse"
  then
    echo '{"ok":true,"message":"Port forwarding added: '"$f_proto_upper"'/'"$f_ext_port"' → '"$f_int_client"':'"$f_int_port"'"}'
    return 0
  fi

  echo '{"ok":false,"error":"AddPortMapping returned unexpected response"}'
  return 1
}

function f_delete_mapping {
  local f_host="$1"
  local f_user="$2"
  local f_pass="$3"
  local f_ext_port="$4"
  local f_proto="$5"

  local f_proto_upper
  f_proto_upper=$(echo "$f_proto" | tr '[:lower:]' '[:upper:]')

  local f_inner="<NewRemoteHost>0.0.0.0</NewRemoteHost><NewExternalPort>${f_ext_port}</NewExternalPort><NewProtocol>${f_proto_upper}</NewProtocol>"

  local f_result
  f_result=$(f_soap_call "$f_host" "$f_user" "$f_pass" "DeletePortMapping" "$f_inner") || {
    if echo "$f_result" | grep -q '"ok":false'
    then
      echo "$f_result"
    else
      echo '{"ok":false,"error":"DeletePortMapping failed"}'
    fi
    return 1
  }

  if echo "$f_result" | grep -q "DeletePortMappingResponse"
  then
    echo '{"ok":true,"message":"Port forwarding deleted: '"$f_proto_upper"/"$f_ext_port"'"}'
    return 0
  fi

  echo '{"ok":false,"error":"DeletePortMapping returned unexpected response"}'
  return 1
}

# --- Config file ---

function f_load_config {
  if [[ -f "$UPNP_CONFIG_FILE" ]]
  then
    source "$UPNP_CONFIG_FILE"
  fi
}

function f_save_config {
  local f_user="$1"
  local f_pass="$2"
  if [[ ! -d "$UPNP_CONFIG_DIR" ]]
  then
    mkdir -p "$UPNP_CONFIG_DIR" 2>/dev/null || return 1
  fi
  cat > "$UPNP_CONFIG_FILE" <<EOF
# Router UPnP credentials for port forwarding
# Stored by SymbiOS WebUI — do not edit manually
ROUTER_UPNP_USER='${f_user}'
ROUTER_UPNP_PASS='${f_pass}'
EOF
  chmod 600 "$UPNP_CONFIG_FILE" 2>/dev/null
}

# --- Main ---

function f_main {
  local f_action="${1:-help}"
  shift 2>/dev/null || true

  f_load_config

  local f_gateway
  f_gateway=$(f_detect_gateway) || {
    echo '{"ok":false,"error":"Could not detect default gateway"}'
    exit 1
  }

  local f_user="${ROUTER_UPNP_USER:-}"
  local f_pass="${ROUTER_UPNP_PASS:-}"

  case "$f_action" in
    detect)
      local f_info
      f_info=$(f_probe_gateway "$f_gateway") || {
        echo '{"ok":true,"available":false,"gateway":"'"$f_gateway"'","error":"No TR-064 response on port 49000"}'
        exit 0
      }
      echo "$f_info" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['gateway'] = '${f_gateway}'
print(json.dumps(d, indent=2))
"
      exit 0
      ;;

    list)
      if [[ -z "$f_user" ]]
      then
        echo '{"ok":false,"error":"Router UPnP credentials not configured. Use '\''config'\'' subcommand to set them."}'
        exit 1
      fi
      f_list_mappings "$f_gateway" "$f_user" "$f_pass"
      exit 0
      ;;

    add)
      local f_ext_port="$1"
      local f_proto="$2"
      local f_int_port="$3"
      local f_int_client="$4"
      local f_desc="${5:-SymbiOS}"

      if [[ -z "$f_ext_port" ]] || [[ -z "$f_proto" ]] || [[ -z "$f_int_port" ]] || [[ -z "$f_int_client" ]]
      then
        echo '{"ok":false,"error":"Usage: add <ext_port> <protocol> <int_port> <int_client> [description]"}'
        exit 1
      fi
      if [[ -z "$f_user" ]]
      then
        echo '{"ok":false,"error":"Router UPnP credentials not configured."}'
        exit 1
      fi

      local f_dup_check
      f_dup_check=$(f_check_duplicate "$f_gateway" "$f_user" "$f_pass" "$f_ext_port" "$f_proto")
      local f_is_dup
      f_is_dup=$(echo "$f_dup_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('duplicate') else 'false')" 2>/dev/null)
      if [[ "$f_is_dup" == "true" ]]
      then
        echo '{"ok":false,"error":"Port mapping already exists for '"$f_proto"'/'"$f_ext_port"'"}'
        exit 1
      fi

      f_add_mapping "$f_gateway" "$f_user" "$f_pass" "$f_ext_port" "$f_proto" "$f_int_port" "$f_int_client" "$f_desc"
      exit 0
      ;;

    delete)
      local f_ext_port="$1"
      local f_proto="${2:-TCP}"

      if [[ -z "$f_ext_port" ]]
      then
        echo '{"ok":false,"error":"Usage: delete <ext_port> [protocol]"}'
        exit 1
      fi
      if [[ -z "$f_user" ]]
      then
        echo '{"ok":false,"error":"Router UPnP credentials not configured."}'
        exit 1
      fi

      f_delete_mapping "$f_gateway" "$f_user" "$f_pass" "$f_ext_port" "$f_proto"
      exit 0
      ;;

    config)
      local f_new_user="${1:-}"
      local f_new_pass="${2:-}"
      if [[ -n "$f_new_user" ]] && [[ -n "$f_new_pass" ]]
      then
        f_save_config "$f_new_user" "$f_new_pass"
        echo '{"ok":true,"message":"Router UPnP credentials saved."}'
        exit 0
      fi
      if [[ -n "$f_user" ]]
      then
        echo '{"ok":true,"configured":true,"username":"'"$f_user"'","gateway":"'"$f_gateway"'"}'
      else
        echo '{"ok":true,"configured":false,"gateway":"'"$f_gateway"'"}'
      fi
      exit 0
      ;;

    help|--help|-h)
      cat <<EOHELP
Usage: ${SCRIPT_NAME} <action> [args...]

Actions:
  detect                          Probe router via gateway for UPnP IGD support
  list                            List all port mappings
  add <ext_port> <proto> <int_port> <int_client> [desc]
                                  Add a port forwarding rule
  delete <ext_port> [protocol]    Delete a port forwarding rule
  config [username] [password]    Show or save router UPnP credentials

Credentials are stored in ${UPNP_CONFIG_FILE}
Environment: ROUTER_UPNP_USER, ROUTER_UPNP_PASS
EOHELP
      exit 0
      ;;

    *)
      echo '{"ok":false,"error":"Unknown action: '"$f_action"'"}'
      exit 1
      ;;
  esac
}

f_main "$@"
