#!/usr/bin/env python3
# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Minimal boot unlock server for LUKS-encrypted /symbios data root.

LUKS operations are delegated to symbios-boot-unlock-luks.sh.
This script only handles the web server (HTTPS) and console prompt.
"""

import http.server
import io
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import termios
import threading
import time

LOG_FILE = "/var/log/symbios-boot-unlock.log"

HTTPS_PORT = 443
HTTP_PORT = 80
CERT_DIR = "/usr/local/sbin/symbios-boot-unlock"
CERT_FILE = os.path.join(CERT_DIR, "cert.pem")
KEY_FILE = os.path.join(CERT_DIR, "key.pem")
LUKS_SCRIPT = os.path.join(CERT_DIR, "symbios-boot-unlock-luks.sh")


def log(msg):
    import datetime
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
            f.flush()
    except Exception:
        pass


def call_luks(action, passphrase=""):
    """Run the LUKS helper script and return parsed JSON dict."""
    try:
        r = subprocess.run(
            [LUKS_SCRIPT, action],
            input=passphrase,
            capture_output=True, text=True, timeout=30
        )
        return json.loads(r.stdout)
    except Exception as e:
        return {"error": str(e)}


# Shared state: set when unlock succeeds so both web and console threads
# know to exit and release ports for Traefik.
_unlock_done = threading.Event()

HTML_UNLOCK = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SymbiOS - Unlock /symbios</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">
  <style>
    body { background: #1a1d23; color: #e0e0e0; min-height: 100vh; display: flex; align-items: center; }
    .unlock-card { max-width: 440px; margin: 0 auto; }
    .form-control { background: #2a2d35; border-color: #444; color: #fff; }
    .form-control:focus { background: #2a2d35; border-color: #0d6efd; color: #fff; box-shadow: 0 0 0 .25rem rgba(13,110,253,.25); }
    .spinner-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 1050; }
    .spinner-overlay.active { display: flex; align-items: center; justify-content: center; }
    .spinner-box { background: #2a2d35; padding: 2rem 3rem; border-radius: 12px; text-align: center; }
  </style>
</head>
<body>
  <div class="container">
    <div class="unlock-card">
      <div class="text-center mb-4">
        <h1 class="mb-2"><i class="bi bi-shield-lock"></i> SymbiOS</h1>
        <p class="text-muted">Encrypted /symbios requires unlock</p>
      </div>
      <div class="card" style="background:#2a2d35; border-color:#444;">
        <div class="card-body p-4">
          <div id="error-box" class="alert alert-danger py-2 mb-3" style="display:none;"></div>
          <div id="success-box" class="alert alert-success py-2 mb-3" style="display:none;"></div>
          <form id="unlock-form" onsubmit="doUnlock(event)">
            <div class="mb-3">
              <label class="form-label">LUKS Passphrase</label>
              <input type="password" id="passphrase" class="form-control" required autofocus autocomplete="off">
            </div>
            <button type="submit" class="btn btn-primary w-100" id="btn-unlock">
              <i class="bi bi-unlock"></i> Unlock /symbios
            </button>
          </form>
        </div>
      </div>
      <div class="text-center mt-3">
        <small class="text-muted">After unlock, Traefik takes over with proper SSL</small>
      </div>
    </div>
  </div>
  <div id="spinner" class="spinner-overlay">
    <div class="spinner-box">
      <div class="spinner-border text-primary mb-3" style="width:3rem;height:3rem;"></div>
      <div>Unlocking /symbios...</div>
    </div>
  </div>
  <script>
    function doUnlock(e) {
      e.preventDefault();
      var pw = document.getElementById('passphrase').value;
      if (!pw) return;
      document.getElementById('error-box').style.display = 'none';
      document.getElementById('spinner').classList.add('active');
      document.getElementById('btn-unlock').disabled = true;
      fetch('/unlock', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({passphrase: pw})
      })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        document.getElementById('spinner').classList.remove('active');
        document.getElementById('btn-unlock').disabled = false;
        if (data.ok) {
          document.getElementById('success-box').textContent = data.message + ' Starting services...';
          document.getElementById('success-box').style.display = '';
          document.getElementById('unlock-form').style.display = 'none';
          var dots = 0;
          var statusEl = document.getElementById('success-box');
          var target = 'https://' + location.hostname + '/';
          function pollReady() {
            dots = (dots + 1) % 4;
            statusEl.textContent = data.message + ' Starting services' + '.'.repeat(dots + 1);
            fetch(target, {mode: 'no-cors'})
              .then(function() { location.href = target; })
              .catch(function() { setTimeout(pollReady, 2000); });
          }
          setTimeout(pollReady, 3000);
        } else {
          document.getElementById('error-box').textContent = data.error;
          document.getElementById('error-box').style.display = '';
          document.getElementById('passphrase').value = '';
          document.getElementById('passphrase').focus();
        }
      })
      .catch(function(err) {
        document.getElementById('spinner').classList.remove('active');
        document.getElementById('btn-unlock').disabled = false;
        document.getElementById('error-box').textContent = 'Connection error: ' + err.message;
        document.getElementById('error-box').style.display = '';
      });
    }
  </script>
</body>
</html>"""

HTML_HTTP_HELP = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SymbiOS - Unlock /symbios</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">
  <style>
    body { background: #1a1d23; color: #e0e0e0; min-height: 100vh; display: flex; align-items: center; }
    .help-card { max-width: 480px; margin: 0 auto; }
  </style>
</head>
<body>
  <div class="container">
    <div class="help-card">
      <div class="text-center mb-4">
        <h1 class="mb-2"><i class="bi bi-shield-lock"></i> SymbiOS</h1>
        <p class="text-muted">Encrypted /symbios requires unlock</p>
      </div>
      <div class="card" style="background:#2a2d35; border-color:#444;">
        <div class="card-body p-4 text-center">
          <p>The unlock page is served over <strong>HTTPS</strong>.</p>
          <a href="https://__HOSTNAME__/"
             class="btn btn-primary btn-lg">
            <i class="bi bi-lock"></i> Open unlock page (HTTPS)
          </a>
          <div class="alert alert-info small mt-3 mb-0 text-start">
            <i class="bi bi-info-circle"></i>
            After unlock, Traefik takes over with a proper Let's Encrypt certificate.
          </div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>"""

HTML_DONE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SymbiOS - Starting...</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">
  <style>
    body { background: #1a1d23; color: #e0e0e0; min-height: 100vh; display: flex; align-items: center; }
  </style>
</head>
<body>
  <div class="text-center w-100">
    <h2><i class="bi bi-check-circle text-success"></i> /symbios unlocked</h2>
    <p id="status" class="text-muted">Waiting for Traefik...</p>
    <p><a href="https://__HOSTNAME__/" class="btn btn-primary">Open WebUI now</a></p>
  </div>
  <script>
    var dots = 0;
    var el = document.getElementById('status');
    var target = 'https://' + location.hostname + '/';
    function poll() {
      dots = (dots + 1) % 4;
      el.textContent = 'Waiting for Traefik' + '.'.repeat(dots + 1);
      fetch(target, {mode: 'no-cors'})
        .then(function() { location.href = target; })
        .catch(function() { setTimeout(poll, 2000); });
    }
    setTimeout(poll, 2000);
  </script>
</body>
</html>"""


def get_hostname():
    """Return the hostname this unlock server is reachable at.

    Prefers the names the served certificate is valid for (SAN, then CN)
    over the bare system hostname, so the shown URL matches the cert that
    browsers will check. Falls back to the system hostname if no cert
    exists yet.
    """
    if os.path.exists(CERT_FILE):
        try:
            f_san = subprocess.run(
                ["openssl", "x509", "-in", CERT_FILE, "-noout",
                 "-ext", "subjectAltName"],
                capture_output=True, text=True, timeout=15
            ).stdout
        except Exception:
            f_san = ""
        f_names = []
        for f_line in f_san.splitlines():
            f_line = f_line.strip()
            if f_line.startswith("DNS:"):
                f_name = f_line[4:].strip()
                if f_name and not f_name.startswith("*"):
                    f_names.append(f_name)
        if f_names:
            return f_names[0]
        try:
            f_subject = subprocess.run(
                ["openssl", "x509", "-in", CERT_FILE, "-noout", "-subject"],
                capture_output=True, text=True, timeout=15
            ).stdout
        except Exception:
            f_subject = ""
        if "CN=" in f_subject:
            f_cn = f_subject.split("CN=", 1)[1]
            f_cn = f_cn.split(",", 1)[0].strip()
            if f_cn:
                return f_cn
    try:
        return socket.gethostname()
    except Exception:
        return "symbios"


def generate_self_signed_cert():
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        return True
    os.makedirs(CERT_DIR, exist_ok=True)
    hostname = get_hostname()
    try:
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048",
             "-keyout", KEY_FILE, "-out", CERT_FILE,
             "-days", "3650", "-nodes",
             "-subj", f"/CN={hostname}/O=SymbiOS/C=DE"],
            capture_output=True, text=True, timeout=30
        )
        os.chmod(KEY_FILE, 0o600)
        os.chmod(CERT_FILE, 0o644)
        return True
    except Exception as e:
        print(f"Failed to generate cert: {e}", file=sys.stderr)
        return False


def needs_unlock():
    """Check via bash helper whether /symbios LUKS needs unlocking."""
    result = call_luks("check")
    return result.get("needs_unlock", False), result


def do_unlock(passphrase):
    """Unlock via bash helper. Returns (ok, message)."""
    if _unlock_done.is_set():
        return True, "Already unlocked"
    result = call_luks("unlock", passphrase)
    if result.get("ok"):
        _unlock_done.set()
        return True, result.get("message", "/symbios unlocked")
    return False, result.get("error", "Unlock failed")


def getpass_getpass(f_stream):
    """Read a passphrase from the given tty stream without echoing."""
    f_fd = f_stream.fileno()
    f_old = termios.tcgetattr(f_fd)
    f_new = termios.tcgetattr(f_fd)
    f_new[3] = f_new[3] & ~termios.ECHO
    try:
        termios.tcsetattr(f_fd, termios.TCSADRAIN, f_new)
        f_stream.write("LUKS passphrase: ")
        f_stream.flush()
        f_line = f_stream.readline()
    finally:
        termios.tcsetattr(f_fd, termios.TCSADRAIN, f_old)
    if not f_line:
        raise EOFError
    return f_line.rstrip("\n")


def console_unlock_thread():
    """Prompt for the LUKS passphrase on the local console.

    Writes to and reads from /dev/console (or /dev/tty when run from an
    interactive shell) instead of stdin/stdout, because systemd's rc.local
    runs the script with stdin=/dev/null and pipes stdout into the boot log.
    """
    console = None
    for path in ("/dev/tty", "/dev/console", "/dev/tty1", "/dev/tty0"):
        try:
            # Open as raw binary stream: the buffered text-mode open() seeks
            # the tty and fails with "File or stream is not seekable".
            f = io.TextIOWrapper(
                open(path, "r+b", buffering=0),
                encoding="utf-8",
                write_through=True,
            )
        except OSError:
            continue
        if f.isatty():
            console = f
            break
        f.close()
    if console is None:
        print("No console available, web unlock only", file=sys.stderr)
        return

    print("\n=== SymbiOS LUKS Unlock ===", file=console)
    print("Enter the LUKS passphrase to unlock /symbios.", file=console)
    print(f"Alternatively, open https://{get_hostname()}/ on another device.\n", file=console)
    console.flush()

    while not _unlock_done.is_set():
        try:
            passphrase = getpass_getpass(console)
        except (EOFError, KeyboardInterrupt):
            print("\nSkipping console unlock.\n", file=console)
            console.flush()
            return
        if not passphrase:
            continue
        ok, msg = do_unlock(passphrase)
        if ok:
            log(f"Console unlock: {msg}")
            print(f"Unlock OK: {msg}", file=console)
            console.flush()
            os._exit(0)
        print(f"Unlock failed: {msg}. Try again or use the web interface.\n", file=console)
        console.flush()


def handle_signal(signum, frame):
    print("Received shutdown signal, exiting...", flush=True)
    os._exit(0)


class UnlockHandler(http.server.BaseHTTPRequestHandler):
    def _send_body(self, f_body, f_content_type="text/html; charset=utf-8"):
        """Send a complete response body with an explicit Content-Length.

        Without Content-Length the client cannot know when the body ends and
        reports "TLS connection was non-properly terminated" because the
        server closes the connection without a TLS close_notify.
        """
        self.send_response(200)
        self.send_header("Content-Type", f_content_type)
        self.send_header("Content-Length", str(len(f_body)))
        self.end_headers()
        self.wfile.write(f_body)

    def _send_json(self, f_obj, f_status=200):
        f_body = json.dumps(f_obj).encode()
        self.send_response(f_status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(f_body)))
        self.end_headers()
        self.wfile.write(f_body)

    def do_GET(self):
        if self.path == "/health":
            self._send_body(b"ok", "text/plain")
            return

        hostname = get_hostname()
        must_unlock, result = needs_unlock()
        page = HTML_UNLOCK if must_unlock else HTML_DONE
        page = page.replace("__HOSTNAME__", hostname)

        self._send_body(page.encode())

    def do_POST(self):
        if self.path == "/unlock":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self._send_json({"ok": False, "error": "Invalid JSON"}, 400)
                return

            passphrase = data.get("passphrase", "")
            if not passphrase:
                self._send_json({"ok": False, "error": "Passphrase required"}, 400)
                return

            ok, msg = do_unlock(passphrase)
            if ok:
                log(f"unlock OK: {msg}")
                self._send_json({"ok": True, "message": msg})
                self.wfile.flush()
                os._exit(0)
            else:
                self._send_json({"ok": False, "error": msg})
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


class _DualStackServer(http.server.HTTPServer):
    """HTTPServer that listens on both IPv4 and IPv6 (dual-stack)."""

    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def create_https_server(port, handler):
    server = _DualStackServer(("::", port), handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    return server


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    must_unlock, result = needs_unlock()
    if not must_unlock:
        if result.get("device"):
            log("/symbios already unlocked, nothing to do")
        else:
            log("/symbios is not encrypted, nothing to do")
        return

    if not generate_self_signed_cert():
        print("Failed to generate SSL cert, aborting", file=sys.stderr)
        sys.exit(1)

    def watchdog():
        time.sleep(10)
        while True:
            must_unlock, _ = needs_unlock()
            if not must_unlock:
                if _unlock_done.is_set():
                    log("watchdog: /symbios mounted (our unlock), skipping exit")
                else:
                    log("watchdog: /symbios mounted externally, shutting down")
                    os._exit(0)
            time.sleep(30)

    threading.Thread(target=watchdog, daemon=True).start()

    print(f"SymbiOS boot unlock: HTTPS on :{HTTPS_PORT}, HTTP help on :{HTTP_PORT}")

    threading.Thread(target=console_unlock_thread, daemon=True).start()

    https_server = create_https_server(HTTPS_PORT, UnlockHandler)

    hostname = get_hostname()
    http_help_page = HTML_HTTP_HELP.replace("__HOSTNAME__", hostname)

    class HTTPHelpHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            f_body = http_help_page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(f_body)))
            self.end_headers()
            self.wfile.write(f_body)

        def do_POST(self):
            self.send_response(301)
            self.send_header("Location", f"https://{hostname}{self.path}")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, fmt, *args):
            pass

    http_server = _DualStackServer(("::", HTTP_PORT), HTTPHelpHandler)
    http_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    http_thread.start()

    try:
        https_server.serve_forever()
    except KeyboardInterrupt:
        pass

    https_server.server_close()
    http_server.server_close()


if __name__ == "__main__":
    main()
