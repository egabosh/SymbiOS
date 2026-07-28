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

"""Minimal boot unlock server for LUKS-encrypted /home.

Provides two ways to unlock:
  1. Web interface on HTTPS :443 (Let's Encrypt cert, extracted by cron)
  2. Console/TTY prompt on the attached screen/keyboard

After successful unlock (by either method), starts Docker and all
compose services, then stops this service so Traefik can take over
ports 80/443.
"""

import http.server
import getpass
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time

LOG_FILE = "/var/log/symbios-boot-unlock.log"

HTTPS_PORT = 443
HTTP_PORT = 80
CERT_DIR = "/usr/local/sbin/symbios-boot-unlock"
CERT_FILE = os.path.join(CERT_DIR, "cert.pem")
KEY_FILE = os.path.join(CERT_DIR, "key.pem")

def log(msg):
    """Append a timestamped line to the log file."""
    import datetime
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
            f.flush()
    except Exception:
        pass

# Shared state: set when unlock succeeds so both web and console threads
# know to stop and hand off to Docker.
_unlock_done = threading.Event()
_unlock_lock = threading.Lock()

HTML_UNLOCK = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SymbiOS - Unlock /home</title>
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
        <p class="text-muted">Encrypted /home requires unlock</p>
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
              <i class="bi bi-unlock"></i> Unlock /home
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
      <div>Unlocking /home...</div>
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
  <title>SymbiOS - Unlock /home</title>
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
        <p class="text-muted">Encrypted /home requires unlock</p>
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
    <h2><i class="bi bi-check-circle text-success"></i> /home unlocked</h2>
    <p id="status" class="text-muted">Waiting for Traefik...</p>
    <p><a href="https://%s/" class="btn btn-primary">Open WebUI now</a></p>
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
    """Get the system hostname for the self-signed cert."""
    try:
        return socket.gethostname()
    except Exception:
        return "symbios"


def generate_self_signed_cert():
    """Generate a self-signed cert on the root partition if not exists."""
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        return True

    os.makedirs(CERT_DIR, exist_ok=True)
    hostname = get_hostname()

    try:
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", KEY_FILE, "-out", CERT_FILE,
                "-days", "3650", "-nodes",
                "-subj", f"/CN={hostname}/O=SymbiOS/C=DE",
            ],
            capture_output=True, text=True, timeout=30
        )
        os.chmod(KEY_FILE, 0o600)
        os.chmod(CERT_FILE, 0o644)
        return True
    except Exception as e:
        print(f"Failed to generate cert: {e}", file=sys.stderr)
        return False


def check_home_encrypted():
    """Check if /home is a LUKS device that needs unlocking.

    Returns True if there is an unopened LUKS device (i.e. a crypto_LUKS
    device whose mapper child is NOT mounted).
    """
    try:
        r = subprocess.run(
            ["lsblk", "-o", "NAME,FSTYPE,MOUNTPOINT,TYPE", "-J"],
            capture_output=True, text=True, timeout=5
        )
        data = json.loads(r.stdout)
        for dev in data.get("blockdevices", []):
            if dev.get("fstype") == "crypto_LUKS":
                # Check if any child (mapper) is mounted
                children = dev.get("children", [])
                has_mounted_child = any(
                    c.get("mountpoint") for c in children
                )
                if not has_mounted_child:
                    return True
    except Exception:
        pass
    return False


def find_luks_device():
    """Find the LUKS device path for /home."""
    try:
        r = subprocess.run(
            ["lsblk", "-o", "NAME,FSTYPE,MOUNTPOINT,TYPE", "-J"],
            capture_output=True, text=True, timeout=5
        )
        data = json.loads(r.stdout)
        for dev in data.get("blockdevices", []):
            if dev.get("fstype") == "crypto_LUKS":
                return "/dev/" + dev["name"]
            for child in dev.get("children", []):
                if child.get("fstype") == "crypto_LUKS":
                    return "/dev/" + child["name"]
    except Exception:
        pass
    return ""


def do_unlock(passphrase):
    """Unlock LUKS device and mount /home. Thread-safe via _unlock_lock."""
    with _unlock_lock:
        if _unlock_done.is_set():
            return True, "Already unlocked"
        luks_dev = find_luks_device()
        if not luks_dev:
            return False, "No LUKS device found"

        luks_name = "home-luks"
        try:
            r = subprocess.run(
                ["cryptsetup", "open", luks_dev, luks_name],
                input=passphrase, capture_output=True, text=True, timeout=30
            )
            if r.returncode != 0:
                return False, "Wrong passphrase or device error"
        except Exception as e:
            return False, f"cryptsetup failed: {e}"

        os.makedirs("/home", exist_ok=True)
        r = subprocess.run(
            ["mount", "/dev/mapper/" + luks_name, "/home"],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode != 0:
            return False, f"Mount failed: {r.stderr}"

        _unlock_done.set()
        return True, "/home unlocked successfully"


def start_docker():
    """Unmask and start Docker via systemd after /home is unlocked.

    The unlock service masks docker.socket, containerd.service, and
    docker.service via ExecStartPre to prevent them from starting
    before /home is mounted (Docker and containerd data live on /home).
    After unlock we unmask them and let systemd handle the startup
    including all dependency ordering (containerd → docker).

    Returns True if Docker started successfully.
    """
    log("start_docker: unmasking services")
    r = subprocess.run(
        ["systemctl", "unmask", "docker.socket",
         "containerd.service", "docker.service"],
        capture_output=True, text=True, timeout=10
    )
    log(f"unmask rc={r.returncode} stderr={r.stderr.strip()}")

    log("starting docker.service via systemd...")
    r = subprocess.run(
        ["systemctl", "start", "docker.service"],
        capture_output=True, text=True, timeout=120
    )
    log(f"docker start rc={r.returncode} stderr={r.stderr.strip()}")
    if r.returncode != 0:
        log("ERROR: docker.service failed to start")
        return False

    log("docker.service started successfully")
    return True


def start_graphical():
    """Start the graphical desktop (LightDM) after unlock.

    The default target is multi-user.target so the boot pauses in
    text mode until the user unlocks.  After unlock we switch to
    graphical.target so LightDM and the desktop session start.
    """
    subprocess.Popen(
        ["systemctl", "start", "graphical.target"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


def shutdown_self():
    """Stop this service after unlock so Docker/Traefik can bind 80/443."""
    # Wait a moment for Docker to stabilize and bind ports.
    time.sleep(5)
    log("shutting down unlock service")
    subprocess.Popen(
        ["systemctl", "stop", "symbios-boot-unlock.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


def console_unlock_thread():
    """Prompt for LUKS passphrase on the physical console (TTY).

    Runs only when stdin is a real terminal (i.e. the service runs on a
    TTY or via systemd with StandardInput=tty).  Uses getpass so the
    passphrase is not echoed.
    """
    if not sys.stdin.isatty():
        return
    print("\n=== SymbiOS LUKS Unlock ===")
    print("Enter the LUKS passphrase to unlock /home.")
    print("Alternatively, open https://<this-host>/ on another device.\n")
    while not _unlock_done.is_set():
        try:
            passphrase = getpass.getpass("LUKS passphrase: ")
        except (EOFError, KeyboardInterrupt):
            print("\nSkipping console unlock.\n")
            return
        if not passphrase:
            continue
        ok, msg = do_unlock(passphrase)
        if ok:
            log(f"Console unlock: {msg}")
            docker_ok = start_docker()
            if docker_ok:
                log("Docker operational (console), starting graphical + shutdown")
            else:
                log("WARNING: Docker not fully operational (console)")
            start_graphical()
            threading.Thread(target=shutdown_self, daemon=True).start()
            return
        print(f"Unlock failed: {msg}. Try again or use the web interface.\n")


def handle_signal(signum, frame):
    """Handle SIGTERM/SIGINT for clean shutdown."""
    print("Received shutdown signal, exiting...", flush=True)
    os._exit(0)


class UnlockHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        hostname = get_hostname()
        if not check_home_encrypted():
            page = HTML_DONE % hostname
        else:
            page = HTML_UNLOCK

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(page.encode())

    def do_POST(self):
        if self.path == "/unlock":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":false,"error":"Invalid JSON"}')
                return

            passphrase = data.get("passphrase", "")
            if not passphrase:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":false,"error":"Passphrase required"}')
                return

            ok, msg = do_unlock(passphrase)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if ok:
                docker_ok = start_docker()
                if docker_ok:
                    log("Docker operational, starting graphical + shutdown")
                else:
                    log("WARNING: Docker not fully operational")
                start_graphical()
                threading.Thread(target=shutdown_self, daemon=True).start()
                self.wfile.write(json.dumps({"ok": True, "message": msg}).encode())
            else:
                self.wfile.write(json.dumps({"ok": False, "error": msg}).encode())
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


def create_https_server(port, handler):
    """Create an HTTPS server with the self-signed cert."""
    server = http.server.HTTPServer(("0.0.0.0", port), handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    return server


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    if not check_home_encrypted():
        log("/home is not encrypted or already unlocked, starting Docker")
        start_docker()
        return

    if not generate_self_signed_cert():
        print("Failed to generate SSL cert, aborting", file=sys.stderr)
        sys.exit(1)

    def watchdog():
        """Exit if /home gets mounted by something else.

        Does NOT exit if we did the unlock ourselves (_unlock_done),
        because Docker may still be starting.
        """
        time.sleep(10)
        while True:
            if not check_home_encrypted():
                if _unlock_done.is_set():
                    log("watchdog: /home mounted (our unlock), skipping exit")
                else:
                    log("watchdog: /home mounted externally, shutting down")
                    os._exit(0)
            time.sleep(30)

    threading.Thread(target=watchdog, daemon=True).start()

    print(f"SymbiOS boot unlock: HTTPS on :{HTTPS_PORT}, HTTP help on :{HTTP_PORT}")

    # Start the console TTY unlock thread (if stdin is a terminal).
    threading.Thread(target=console_unlock_thread, daemon=True).start()

    https_server = create_https_server(HTTPS_PORT, UnlockHandler)

    # HTTP server on port 80 shows a help page explaining how to accept
    # the self-signed cert.  The passphrase is NEVER sent over HTTP.
    hostname = get_hostname()
    http_help_page = HTML_HTTP_HELP.replace("__HOSTNAME__", hostname)

    class HTTPHelpHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(http_help_page.encode())

        def do_POST(self):
            # Accept POST on HTTP too — redirect to HTTPS.
            self.send_response(301)
            self.send_header("Location", f"https://{hostname}{self.path}")
            self.end_headers()

        def log_message(self, fmt, *args):
            pass

    http_server = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), HTTPHelpHandler)

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
