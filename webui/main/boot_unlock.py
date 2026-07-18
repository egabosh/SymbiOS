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

"""Minimal boot unlock web server for LUKS-encrypted /home.

Listens on 80 (HTTP redirect) and 443 (HTTPS) with a self-signed cert.
After successful unlock, stops itself and starts Docker/Traefik which
takes over ports 80/443.

The self-signed cert is generated once and stored on the root partition
at /etc/symbios-boot-unlock/. After first unlock, Traefik provides
proper certs (Let's Encrypt or local CA).
"""

import http.server
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time

HTTPS_PORT = 443
HTTP_PORT = 80
CERT_DIR = "/usr/local/sbin/symbios-boot-unlock"
CERT_FILE = os.path.join(CERT_DIR, "cert.pem")
KEY_FILE = os.path.join(CERT_DIR, "key.pem")

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
          document.getElementById('success-box').textContent = data.message + ' Starting Traefik...';
          document.getElementById('success-box').style.display = '';
          document.getElementById('unlock-form').style.display = 'none';
          setTimeout(function() { location.reload(); }, 5000);
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

HTML_DONE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="5;url=https://%s/">
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
    <p class="text-muted">Traefik is starting... Redirecting in 5 seconds.</p>
    <p><a href="https://%s/" class="btn btn-primary">Open WebUI now</a></p>
  </div>
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
    """Check if /home is a LUKS device that needs unlocking."""
    try:
        r = subprocess.run(
            ["lsblk", "-o", "FSTYPE,MOUNTPOINT", "-J"],
            capture_output=True, text=True, timeout=5
        )
        data = json.loads(r.stdout)
        for dev in data.get("blockdevices", []):
            if dev.get("fstype") == "crypto_LUKS" and not dev.get("mountpoint"):
                return True
            for child in dev.get("children", []):
                if child.get("fstype") == "crypto_LUKS" and not child.get("mountpoint"):
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
    """Unlock LUKS device and mount /home."""
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

    return True, "/home unlocked successfully"


def start_docker():
    """Start Docker and bring up WebUI + Traefik containers."""
    subprocess.Popen(
        ["systemctl", "start", "docker"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    time.sleep(3)
    for compose_dir in ["/home/docker/symbios-ui", "/home/docker/traefik"]:
        if os.path.isdir(compose_dir):
            subprocess.Popen(
                ["docker", "compose", "up", "-d"],
                cwd=compose_dir,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )


def shutdown_self():
    """Stop this service after unlock so Docker/Traefik can bind 80/443."""
    time.sleep(2)
    subprocess.Popen(
        ["systemctl", "stop", "symbios-boot-unlock.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


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
            page = HTML_DONE % (hostname, hostname)
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
                start_docker()
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
    if not check_home_encrypted():
        print("/home is not encrypted or already unlocked, nothing to do")
        return

    if not generate_self_signed_cert():
        print("Failed to generate SSL cert, aborting", file=sys.stderr)
        sys.exit(1)

    print(f"SymbiOS boot unlock: HTTPS on :{HTTPS_PORT}, HTTP redirect on :{HTTP_PORT}")

    https_server = create_https_server(HTTPS_PORT, UnlockHandler)

    class HTTPRedirectHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hostname = get_hostname()
            self.send_response(301)
            self.send_header("Location", f"https://{hostname}{self.path}")
            self.end_headers()

        def do_POST(self):
            self.do_GET()

        def log_message(self, fmt, *args):
            pass

    http_server = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), HTTPRedirectHandler)

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
