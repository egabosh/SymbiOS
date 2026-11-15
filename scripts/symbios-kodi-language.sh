#!/bin/bash
# SymbiOS - Read or set the UI language of the Kodi media center.
#
# Kodi keeps its UI language in the profile (guisettings.xml), a file the
# running instance owns and rewrites at will. Writing it behind Kodi's back is
# therefore not an option: a running session is asked over the settings API of
# its JSON-RPC web server (port 8081, Basic auth with the generated password in
# <services_root>/kodi/.kodi_web_pw). Which language id belongs to the system
# is decided by services/kodi.yml (inventory "locale"), not here.
#
# The switch is persisted immediately, the UI itself changes with the next
# start - services/kodi.yml restarts the session for that.
#
# Usage:
#   symbios-kodi-language.sh get
#   symbios-kodi-language.sh set <resource.language.xx_yy>
#
# Output: the addon id on stdout for "get"; "set" prints a machine-readable
# state token as the last line (kodi-language-changed /
# kodi-language-unchanged).
# Exit codes: 0 ok, 1 Kodi not reachable or request failed, 2 usage error.

function f_usage {
  cat << EOF
Usage: $(basename "$0") get|set <addon-id>

Read or set the UI language of the running Kodi session.

Commands:
  get                             Print the current language addon id
                                  (e.g. resource.language.de_de)
  set <resource.language.xx_yy>   Switch the UI language if it differs; the
                                  last output line is kodi-language-changed or
                                  kodi-language-unchanged

The web server password is read from
<services_root>/kodi/.kodi_web_pw and never appears on the command line.

Options:
  -h, --help                      Show this help and exit

Exit codes:
  0  ok (also when the language already matches)
  1  Kodi does not answer or rejected the request
  2  usage error (unknown command, malformed addon id)
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

g_web_pw="${g_services_root}/kodi/.kodi_web_pw"
g_rpc_url="http://127.0.0.1:8081/jsonrpc"
# Kodi language addons are named resource.language.<ll>_<cc>, lowercase.
g_addon_re='^resource\.language\.[a-z0-9]+(_[a-z0-9]+)*$'

# JSON-RPC against the local web server. The password travels through the
# environment, so it never shows up in the process list; the helper prints the
# current id for "get" and the state token for "set".
function f_kodi_language {
  local f_action="$1"
  local f_want="${2:-}"
  local f_pw
  f_pw=$(cat "$g_web_pw" 2>/dev/null) || return 1
  [[ -n $f_pw ]] || return 1
  KODI_PW="$f_pw" python3 - "$g_rpc_url" "$f_action" "$f_want" <<'PYEOF'
import base64, json, os, sys, time, urllib.request

url, action, want = sys.argv[1], sys.argv[2], sys.argv[3]
auth = "Basic " + base64.b64encode(("kodi:" + os.environ["KODI_PW"]).encode()).decode()


def rpc(method, params, timeout=5):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": auth, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def read_language(timeout=5):
    return rpc("Settings.GetSettingValue", {"setting": "locale.language"},
               timeout=timeout)["result"]["value"]


try:
    current = read_language()
except Exception as exc:
    print("Kodi JSON-RPC not reachable: %s" % exc, file=sys.stderr)
    sys.exit(1)

if action == "get":
    print(current)
    sys.exit(0)

if current == want:
    print("kodi-language-unchanged")
    sys.exit(0)

# A language pack that was unzipped into ~/.kodi/addons is registered as a
# disabled addon; Kodi then refuses it and silently falls back to English
# ("could not find or enable language add-on"). Enabling is idempotent, and it
# is ignored while Kodi does not know the addon yet (it then needs a restart).
try:
    rpc("Addons.SetAddonEnabled", {"addonid": want, "enabled": True})
except Exception:
    pass

# The answer itself is unreliable: Kodi opens its "restart the application"
# dialog on a language change and drops the HTTP response, and reloading the
# language strings keeps the web server busy for a while. The value is
# therefore read back until it is the requested one.
try:
    rpc("Settings.SetSettingValue",
        {"setting": "locale.language", "value": want}, timeout=5)
except Exception:
    pass

for _ in range(20):
    try:
        if read_language(timeout=6) == want:
            print("Kodi UI language: %s -> %s" % (current, want), file=sys.stderr)
            print("kodi-language-changed")
            sys.exit(0)
    except Exception:
        pass
    time.sleep(3)

print("Kodi did not take the language %s" % want, file=sys.stderr)
sys.exit(1)
PYEOF
}

case "${1:-}" in
  get)
    f_kodi_language get ""
    ;;
  set)
    if [[ -z "${2:-}" ]]
    then
      f_usage >&2
      exit 2
    fi
    if [[ ! "${2}" =~ $g_addon_re ]]
    then
      g_echo_error "not a Kodi language addon id: ${2}"
      exit 2
    fi
    f_kodi_language set "${2}"
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
