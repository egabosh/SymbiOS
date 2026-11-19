#!/bin/bash
# SymbiOS - Restart the Kodi session, unless something is playing.
#
# Kodi reads its addon list, the sources and the skin at start, so a new game
# addon, a changed source or a skin patch only shows up after a restart of the
# session. A restart ends a running video and kills a running game (the game
# runs in the video player), so the session is asked first: while a player is
# active the restart is skipped and reported. The next run without playback
# performs it.
#
# The switcher unit is stopped and started around the session, the same way the
# playbook did it inline: it starts Kodi in the media center mode and must not
# race the restart.
#
# Usage:
#   symbios-kodi-restart.sh
#
# No arguments.
#
# Output: progress on stderr; the last stdout line is the state token
# kodi-session-restarted (the session was restarted),
# kodi-session-busy (something is playing or Kodi does not answer, no restart)
# or kodi-session-unchanged (Kodi is not running, nothing to restart).
# Exit codes: 0 ok (restarted, skipped), 1 the restart failed.

function f_usage {
  cat << EOF
Usage: $(basename "$0")

Restart the Kodi session when nothing is playing.

Kodi reads the addon list, the sources and the skin only at start, so the
playbook calls this after it changed one of them. A running video or game is
never interrupted: the session is asked over its JSON-RPC web server (port
8081, Basic auth with the password in <services_root>/kodi/.kodi_web_pw) and
the restart is skipped while a player is active.

No arguments.

Output: progress on stderr; the last stdout line is one of the state tokens
kodi-session-restarted, kodi-session-busy (playing or web server silent) and
kodi-session-unchanged (Kodi is not running).

Options:
  -h, --help                   Show this help and exit

Exit codes:
  0  restarted, or skipped because nothing has to be done
  1  the restart of the session failed
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

f_no_args "$@"

g_web_pw="${g_services_root}/kodi/.kodi_web_pw"
g_rpc_url="http://127.0.0.1:8081/jsonrpc"

# Active players of the running session. A video, a music track and a game all
# appear here, so the answer covers every way a restart would interrupt
# something.
function f_kodi_playing {
  local f_pw
  f_pw=$(cat "$g_web_pw" 2>/dev/null) || return 2
  [[ -n $f_pw ]] || return 2
  # The password travels through the environment: the JSON-RPC header would
  # otherwise be readable in the process list.
  KODI_PW="$f_pw" python3 - "$g_rpc_url" <<'PYEOF'
import base64, json, os, sys, urllib.request

auth = "Basic " + base64.b64encode(("kodi:" + os.environ["KODI_PW"]).encode()).decode()
body = json.dumps({"jsonrpc": "2.0", "id": 1,
                   "method": "Player.GetActivePlayers"}).encode()
req = urllib.request.Request(sys.argv[1], data=body, headers={
    "Authorization": auth, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=5) as resp:
        players = json.loads(resp.read()).get("result", [])
except Exception as exc:
    print("Kodi JSON-RPC not reachable: %s" % exc, file=sys.stderr)
    sys.exit(2)
sys.exit(0 if players else 1)
PYEOF
}

# A session that is down picks everything up on its next start.
if ! systemctl is-active --quiet kodi-standalone.service
then
  g_echo_note "Kodi is not running, nothing to restart"
  echo "kodi-session-unchanged"
  exit 0
fi

f_kodi_playing
g_playing_rc=$?
if [[ $g_playing_rc -eq 0 ]]
then
  g_echo_note "Kodi is playing, restart skipped (it would end the playback)"
  echo "kodi-session-busy"
  exit 0
fi
if [[ $g_playing_rc -eq 2 ]]
then
  # Without an answer the state is unknown; a restart could kill a playback,
  # so it stays out until the web server responds again.
  g_echo_warn "Kodi does not answer its web server, restart skipped"
  echo "kodi-session-busy"
  exit 0
fi

g_echo_note "Restarting the Kodi session"
systemctl stop switch-kodi-desk.service || true
if ! systemctl stop kodi-standalone.service
then
  g_echo_error "Failed to stop kodi-standalone.service"
  exit 1
fi
if ! systemctl start kodi-standalone.service
then
  g_echo_error "Failed to start kodi-standalone.service"
  exit 1
fi
systemctl start switch-kodi-desk.service || true
echo "kodi-session-restarted"
