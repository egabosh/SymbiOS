#!/bin/bash
# SymbiOS - Read or set a setting of the running Kodi media center.
#
# Kodi keeps its settings in the profile (guisettings.xml) and rewrites that
# file at start with what it loaded, so a value written behind a running
# instance does not persist on its own. The running session is therefore
# asked over the settings API of its JSON-RPC web server (port 8081, Basic
# auth with the generated password in <services_root>/kodi/.kodi_web_pw).
# A set value takes effect immediately - no restart is needed.
#
# Which settings the system pins is decided by services/kodi.yml, not here.
#
# Usage:
#   symbios-kodi-setting.sh get <setting-id>
#   symbios-kodi-setting.sh set <setting-id> <value>
#
# Values "true" and "false" are sent as boolean, a plain integer as integer,
# everything else as string.
#
# Output: "get" prints the current value (true/false, a number or text);
# "set" prints the change to stderr and a machine-readable state token as the
# last stdout line (kodi-setting-changed / kodi-setting-unchanged).
# Exit codes: 0 ok, 1 Kodi not reachable or request failed, 2 usage error.

function f_usage {
  cat << EOF
Usage: $(basename "$0") get|set <setting-id> [value]

Read or set a Kodi setting of the running session.

Commands:
  get <setting-id>             Print the current value (true/false, number or
                               text)
  set <setting-id> <value>     Set the value if it differs; the last output
                               line is kodi-setting-changed or
                               kodi-setting-unchanged

Values: "true"/"false" are sent as boolean, plain integers as integer, any
other value as string. The setting id is the id from Kodi's settings.xml
(e.g. gamesgeneral.enablerewind).

The web server password is read from
<services_root>/kodi/.kodi_web_pw and never appears on the command line.

Options:
  -h, --help                   Show this help and exit

Exit codes:
  0  ok (also when the value already matches)
  1  Kodi does not answer or rejected the request
  2  usage error (unknown command, missing arguments)
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
# Kodi setting ids are dotted lowercase identifiers (section.setting).
g_setting_re='^[a-z0-9]+(\.[a-z0-9]+)+$'

# JSON-RPC against the local web server. The password travels through the
# environment, so it never shows up in the process list; the helper prints the
# value for "get" and the state token for "set".
function f_kodi_setting {
  local f_action="$1"
  local f_setting="$2"
  local f_want="${3:-}"
  local f_pw
  f_pw=$(cat "$g_web_pw" 2>/dev/null) || return 1
  [[ -n $f_pw ]] || return 1
  KODI_PW="$f_pw" python3 - "$g_rpc_url" "$f_action" "$f_setting" "$f_want" <<'PYEOF'
import base64, json, os, re, sys, time, urllib.request

url, action, setting, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
auth = "Basic " + base64.b64encode(("kodi:" + os.environ["KODI_PW"]).encode()).decode()


def rpc(method, params, timeout=5):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": auth, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def read_setting(timeout=5):
    return rpc("Settings.GetSettingValue", {"setting": setting},
               timeout=timeout)["result"]["value"]


def render(value):
    # Booleans are printed the way the caller passed them in.
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def coerce(raw):
    # A typed value keeps the JSON-RPC call correct without a type argument.
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?[0-9]+", raw):
        return int(raw)
    return raw


try:
    current = read_setting()
except Exception as exc:
    print("Kodi JSON-RPC not reachable: %s" % exc, file=sys.stderr)
    sys.exit(1)

if action == "get":
    print(render(current))
    sys.exit(0)

value = coerce(want)
if render(current) == render(value):
    print("kodi-setting-unchanged")
    sys.exit(0)

try:
    rpc("Settings.SetSettingValue", {"setting": setting, "value": value})
except Exception as exc:
    print("Kodi rejected %s: %s" % (setting, exc), file=sys.stderr)
    sys.exit(1)

# Read back instead of trusting the answer: some settings are applied
# asynchronously (a restart dialog, a reload of dependent values).
for _ in range(5):
    try:
        if render(read_setting(timeout=6)) == render(value):
            print("%s: %s -> %s" % (setting, render(current), render(value)),
                  file=sys.stderr)
            print("kodi-setting-changed")
            sys.exit(0)
    except Exception:
        pass
    time.sleep(1)

print("Kodi did not take %s = %s" % (setting, render(value)), file=sys.stderr)
sys.exit(1)
PYEOF
}

case "${1:-}" in
  get)
    if [[ ! "${2:-}" =~ $g_setting_re ]]
    then
      f_usage >&2
      exit 2
    fi
    f_kodi_setting get "$2"
    ;;
  set)
    if [[ ! "${2:-}" =~ $g_setting_re || -z "${3:-}" ]]
    then
      f_usage >&2
      exit 2
    fi
    f_kodi_setting set "$2" "$3"
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
