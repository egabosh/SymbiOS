#!/bin/bash
# SymbiOS - Router detection via UPnP (pure bash, no python)
# Probes default gateway for UPnP IGD, extracts manufacturer/model,
# and classifies as fritzbox or generic_upnp.
# Outputs JSON to stdout.

SCRIPT_NAME="$(basename "$0")"
BASE_PORT=49000

# XML value extraction via bash parameter substitution
# Usage: f_extract_xml_value "<xml>" "<tag>"

function f_extract_xml_value {
  local f_xml="$1"
  local f_tag="$2"
  local f_tmp="${f_xml#*<${f_tag}>}"

  if [[ "$f_tmp" == "$f_xml" ]]
  then
    echo ""
    return 1
  fi

  echo "${f_tmp%%</${f_tag}>*}"
}

# --- Main ---

GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')

if [[ -z "$GATEWAY" ]]
then
  cat <<EOJSON
{"available":false,"error":"Could not detect default gateway"}
EOJSON
  exit 1
fi

# Try primary UPnP port, then fallback URLs
XML=$(curl -s -m 5 "http://${GATEWAY}:${BASE_PORT}/igddesc.xml" 2>/dev/null)

if [[ -z "$XML" ]]
then
  for URL in "http://${GATEWAY}:5000/rootDesc.xml" \
             "http://${GATEWAY}/rootDesc.xml" \
             "http://${GATEWAY}/igddesc.xml"
  do
    XML=$(curl -s -m 3 "$URL" 2>/dev/null)
    [[ -n "$XML" ]] && break
  done
fi

if [[ -z "$XML" ]]
then
  cat <<EOJSON
{"available":false,"gateway":"${GATEWAY}","error":"No UPnP device description found on any common URL"}
EOJSON
  exit 0
fi

# Extract device info via bash parameter substitution
MANUFACTURER=$(f_extract_xml_value "$XML" "manufacturer")
MODEL=$(f_extract_xml_value "$XML" "modelName")
FRIENDLY=$(f_extract_xml_value "$XML" "friendlyName")

# Determine router type
ROUTER_TYPE="generic_upnp"
if [[ "${MANUFACTURER^^}" == *AVM* ]]
then
  ROUTER_TYPE="fritzbox"
fi

# Extract WANIPConnection/WANPPPConnection control URL
SERVICES="${XML#*<serviceList>}"
SERVICES="${SERVICES%</serviceList>*}"

CONTROL_URL=""
SERVICE_TYPE=""

if [[ "$SERVICES" != "$XML" ]] && [[ -n "$SERVICES" ]]
then
  REMAINING="$SERVICES"
  while [[ "$REMAINING" == *"<service>"* ]]
  do
    BLOCK="${REMAINING#*<service>}"
    BLOCK="${BLOCK%%</service>*}"
    REMAINING="${REMAINING#*</service>}"

    ST=$(f_extract_xml_value "$BLOCK" "serviceType")

    if [[ "$ST" == *"WANIPConnection"* ]] || [[ "$ST" == *"WANPPPConnection"* ]]
    then
      SERVICE_TYPE="$ST"
      CONTROL_URL=$(f_extract_xml_value "$BLOCK" "controlURL")
      break
    fi
  done
fi

if [[ -z "$MANUFACTURER" ]]
then
  cat <<EOJSON
{"available":false,"gateway":"${GATEWAY}","error":"Could not parse device description (no manufacturer)"}
EOJSON
  exit 0
fi

cat <<EOJSON
{"available":true,"manufacturer":"${MANUFACTURER}","model":"${MODEL}","friendly_name":"${FRIENDLY}","router_type":"${ROUTER_TYPE}","control_url":"${CONTROL_URL}","service_type":"${SERVICE_TYPE}","gateway":"${GATEWAY}"}
EOJSON
