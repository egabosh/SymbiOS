#!/bin/bash

# Enable all installed addons via the JSON-RPC web server. Kodi
# registers manually installed addons (vfs.sftp, plugins, ...) as
# disabled; they must be active for their protocols and services to
# work. The pass is cheap and idempotent: it asks Kodi which
# installed addons are currently disabled (JSON-RPC v13 takes the
# filter as booleans, "enabled": false) and only sends
# SetAddonEnabled for those, so it converges shortly after Kodi
# starts and stays quiet afterwards. Enabling a VFS addon at
# runtime registers its protocol immediately (VFSEntry subscribes
# to AddonEvents::Enabled), no restart needed.
f_enable_addons() {
  local f_pw
  f_pw=$(cat /symbios/services/kodi/.kodi_web_pw 2>/dev/null) || return 0
  [[ -n "$f_pw" ]] || return 0
  python3 - "$f_pw" <<'PYEOF' 2>/dev/null || true
import base64, json, sys, urllib.request

pw = sys.argv[1]
auth = "Basic " + base64.b64encode(("kodi:" + pw).encode()).decode()
url = "http://localhost:8081/jsonrpc"

def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": auth, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as resp:
        return json.loads(resp.read())

# "enabled" is a boolean filter in JSON-RPC v13: this returns the
# installed addons that are currently disabled (empty when none)
res = rpc("Addons.GetAddons", {"enabled": False})
for addon in res.get("result", {}).get("addons", []):
    rpc("Addons.SetAddonEnabled",
        {"addonid": addon["addonid"], "enabled": True})
PYEOF
}

# The media database (MariaDB) is a remote host: while it does not
# answer - remote site down, name resolving to an address without a
# database route - Kodi blocks in the database open and never paints
# its first frame, so the TV stays black. Waiting for the database
# therefore never blocks the session: after a grace period the
# profile falls back to the local SQLite library (empty media
# library, but a usable menu and the SFTP sources) and returns to
# the shared database as soon as it answers again.
g_userdata=/home/kodi/.kodi/userdata
g_advancedsettings=${g_userdata}/advancedsettings.xml
# Kodi only reads the exact file name, so the "database off" state
# is a rename next to it.
g_advancedsettings_off=${g_advancedsettings}.db-off

# Print "<host> <port>" of the configured MySQL backend; nothing
# when the profile has no database backend.
f_db_target() {
  local f_file
  f_file=${g_advancedsettings}
  [[ -f $f_file ]] || f_file=${g_advancedsettings_off}
  [[ -f $f_file ]] || return 0
  grep -q mysql "$f_file" 2>/dev/null || return 0
  printf '%s %s\n' \
    "$(grep "<host>" "$f_file" | head -n1 | cut -d"<" -f2 | cut -d">" -f2)" \
    "$(grep "<port>" "$f_file" | head -n1 | cut -d"<" -f2 | cut -d">" -f2)"
}

# Is the media database reachable? A bare /dev/tcp connect hangs for
# the whole kernel SYN timeout (~2 min) against a firewalled host,
# so the probe is bounded.
f_db_up() {
  local f_host f_port
  read -r f_host f_port <<<"$(f_db_target)"
  [[ -n $f_host ]] || return 0
  timeout 3 bash -c "exec 3<>/dev/tcp/${f_host}/${f_port:-3306}" 2>/dev/null
}

# Park or restore the remote database section. Only called while
# Kodi is stopped, so the switch needs no restart.
f_db_off() {
  [[ -f $g_advancedsettings ]] || return 0
  mv -f "$g_advancedsettings" "$g_advancedsettings_off"
  echo "media database unreachable - starting with the local library"
}

f_db_on() {
  [[ -f $g_advancedsettings_off ]] || return 0
  mv -f "$g_advancedsettings_off" "$g_advancedsettings"
  echo "media database reachable - back to the shared library"
}

# Restart Kodi at most once per 5 minutes: the database error stays
# in the log until the next start, so an unguarded restart would
# turn into a loop.
f_restart_kodi() {
  local f_stamp=/run/switch-kodi-desk.last-restart
  if [[ -f $f_stamp ]]
  then
    [[ $(( $(date +%s) - $(stat -c %Y "$f_stamp") )) -ge 300 ]] || return 0
  fi
  touch "$f_stamp"
  systemctl restart kodi-standalone.service
}

# Manually unpacked addons are registered by Kodi with enabled=0 at the first
# start, which raises the "activate disabled addons?" dialog before the
# runtime JSON-RPC pass below can run. Seed the installed table while Kodi is
# stopped so the first frame is already clean. Addons installed later are
# still covered by f_enable_addons once Kodi is up.
f_enable_addons_in_db() {
  local f_db=/home/kodi/.kodi/userdata/Database/Addons33.db
  local f_xml f_id f_sql
  command -v sqlite3 >/dev/null 2>&1 || return 0
  [[ -f "$f_db" ]] || return 0
  for f_xml in /home/kodi/.kodi/addons/*/addon.xml
  do
    [[ -f "$f_xml" ]] || continue
    f_id="$(grep -o 'id="[^"]*"' "$f_xml" | head -n1 | cut -d'"' -f2)"
    [[ -n "$f_id" ]] || continue
    f_sql="INSERT INTO installed (addonID, enabled, disabledReason) VALUES ('${f_id//\'/\'\'}', 1, 0) ON CONFLICT(addonID) DO UPDATE SET enabled=1, disabledReason=0;"
    sqlite3 "$f_db" "$f_sql" >/dev/null 2>&1 || true
  done
}

# Start Kodi with the shared library when the database answers
# within the grace period, with the local library otherwise.
f_start_kodi() {
  local f_i
  f_enable_addons_in_db
  if ! f_db_up
  then
    echo "waiting up to 60s for the media database $(f_db_target)"
    for (( f_i = 0; f_i < 12; f_i++ ))
    do
      sleep 5
      f_db_up && break
    done
  fi
  if f_db_up
  then
    f_db_on
  else
    f_db_off
  fi
  systemctl start kodi-standalone
}

deskorkodi="kodi"
while true
do

  ps axu >/tmp/deskorkodi-$$
  if egrep "/usr/bin/kodi |kodi\.bin " /tmp/deskorkodi-$$
  then
    deskorkodi="desk"
    # keep all installed addons enabled (converges after Kodi start)
    f_enable_addons
    # Kodi shutdown hang detection
    egrep -iq "info <general>: Stopping the application..." /home/kodi/.kodi/temp/kodi.log && grep -q "info <general>: Stopping all" /home/kodi/.kodi/temp/kodi.log && killall -9 kodi kodi.bin
    if [[ -f $g_advancedsettings_off ]]
    then
      # running on the local fallback: switch back once the shared
      # database answers again
      f_db_up && f_db_on && f_restart_kodi
    elif f_db_up && egrep -iq " Unable to open database: .*t connect to server" /home/kodi/.kodi/temp/kodi.log
    then
      # Restart Kodi if the remote database connection fails - only
      # while the database answers (a restart against an unreachable
      # host would just loop) and rate-limited.
      f_restart_kodi
    fi
  elif grep "cinnamon" /tmp/deskorkodi-$$
  then
    deskorkodi="kodi"
  else
    if [[ $deskorkodi = kodi ]]
    then
      systemctl stop lightdm
      f_start_kodi
      deskorkodi="desk"
    elif [[ $deskorkodi = desk ]]
    then
      systemctl stop kodi-standalone
      systemctl start lightdm
      deskorkodi="kodi"
      sleep 10
    else
      systemctl stop lightdm
      f_start_kodi
      deskorkodi="desk"
    fi
  fi
  echo VAR=$deskorkodi
  sleep 10
done
