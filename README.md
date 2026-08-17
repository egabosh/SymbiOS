# SymbiOS

Debian-based distribution for self-hosted servers. SymbiOS turns a plain
Debian machine into a managed, containerized home/server platform: a reverse
proxy with automatic TLS, single sign-on with two-factor auth, an LDAP
directory, and a web UI to manage it all. On top of the
base system you can drop in your own services through the `services/`
subdirectory.

The name is inspired by the Trill symbionts from *Star Trek: Deep Space
Nine* - sentient beings that join with humanoid hosts in a mutualistic
symbiosis. Neither can survive without the other; the host gains the memories
and experiences of all previous hosts, while the symbiont gains a new life.
Much like the Dax symbiont passing through Curzon, Jadzia, and Ezri, the
services in SymbiOS rely on each other - Traefik, Authelia, LDAP, Docker,
the WebUI - each one stronger together than alone. SymbiOS stands for
**Symbio**sis + **OS**.

- Source: <https://github.com/egabosh/SymbiOS>
- Target OS: Debian (also runs on Raspberry Pi OS)

---

## Table of contents

1. [What SymbiOS does](#1-what-symbios-does)
2. [Architecture overview](#2-architecture-overview)
3. [Repository layout](#3-repository-layout)
4. [The base services](#4-the-base-services)
5. [Domains, TLS and certificates](#5-domains-tls-and-certificates)
6. [External services and network access](#6-external-services-and-network-access)
7. [Networking and Traefik routing](#7-networking-and-traefik-routing)
8. [Installation](#8-installation)
9. [Managing the system (WebUI / SSH)](#9-managing-the-system-webui--ssh)
   - [State-file install tracking](#state-file-install-tracking)
10. [Adding your own service](#10-adding-your-own-service)
11. [User-uploaded playbooks](#11-user-uploaded-playbooks)
12. [License](#license)
13. [Disclaimer](#disclaimer)

---

## 1. What SymbiOS does

SymbiOS provisions and wires together a set of core services so that adding a
new web app is mostly "write one playbook and drop it in `services/`":

| Concern            | Provided by                                         |
|--------------------|-----------------------------------------------------|
| Reverse proxy / TLS| Traefik (file-provider based routing)               |
| Authentication     | Authelia (SSO, 2FA, OpenID Connect)                 |
| User directory     | OpenLDAP                                        |
| Certificates       | Let's Encrypt                                    |
| Dynamic DNS        | deSEC (dedyn.io) client                             |
| Management UI      | symbios-ui (Django web interface)                 |
| App isolation      | Docker, one compose stack per service               |

Everything is driven by Ansible playbooks. There is no long-running agent: the
web UI runs playbooks on the host **directly over SSH** through a minimal
audit-logging executor (`symbios-exec.sh`). The WebUI container has the
playbook sources mounted read-only at `/repo`; it parses their machine-readable
`# docs:` blocks locally, resolves every status/action/log command itself, and
ships only the concrete command to the host (no host-side verb dispatch, no
secrets leave the host). The webui's SSH key is a normal root key - trusted
admins operate the host, so the executor imposes no command allow-list. No extra
daemon is required.

---

## 2. Architecture overview

```
                         Internet / LAN
                              |
                        +-----+------+
                        |   Traefik   |   :80 -> redirect to :443
                        | (reverse    |   :443 https  (automatic TLS)
                        |  proxy)     |   :636 ldaps (local mode only)
                        +-----+------+
                              |
        -------------------------------------------------------------
        |              |               |                |          |
   +----v----+   +-----v------+   +----v-----+    +-----v-----+  (your
   | Authelia|   | symbios-ui |   |   LDAP   |    |  services |  services)
   |  (SSO/  |   |  (WebUI)   |   | openldap  |    |  (file    |  attach to
   |  2FA/   |   |            |   | + LAM     |    |  provider |  the traefik
   |  OIDC)  |   |            |   |           |    |  snippets) |  network)
   +---------+   +------------+   +-----------+    +-----------+
        |              |                |
        |              |                |
    +----v--------------v----------------v-----------------------------+
    |  symbios-exec.sh     (audit-logging SSH executor used by the WebUI)   |
    +---------------------------------------------------------------+
        |
   +----v----------------------------+
   |  base-services/*.yml (Ansible)    |
   |  services/*.yml    (Ansible)    |
   +---------------------------------+
```

Key idea: **Traefik does not use the Docker provider and has no access to the
Docker socket.** Routing is declared as *file-provider* snippets in
`/symbios/base-services/traefik/providers/`, which Traefik watches at runtime. A service
becomes reachable by (a) joining the external `traefik` Docker network and
(b) dropping a provider snippet that points a `Host(...)` rule at the
container's IP/port.

---

## 3. Repository layout

```
SymbiOS/
├── install.sh            # Bootstrap: install ansible, clone repo, run base-services
├── inventory.yml         # Template inventory (copied to the host on first install)
├── base-services/        # Core Ansible playbooks (the "Basisservices")
│   ├── *.yml             # One playbook per concern (see section 4)
│   ├── traefik-services.j2   # Template -> /symbios/base-services/traefik/providers/symbios-services.yml
│   ├── authelia-access-control.j2  # Template -> Authelia access_control block
│   └── traefik-static.yml# Traefik static config (entrypoints, etc.)
├── scripts/              # Helper scripts deployed to /usr/local/sbin/ and the WebUI
│   ├── symbios-router-upnp.sh  # Router port-forwarding dispatcher (generic UPnP)
│   ├── symbios-router-fritz.py # FRITZ!Box port-forwarding backend (data.lua API)
│   ├── runchecks.d/      # Health-check scripts (run by runchecks.sh)
│   ├── autoupdate.d/     # Update dispatchers (debian / docker / symbios)
│   └── backup.d/         # Backup modules (docker, ldap-docker, …)
├── services/             # OPTIONAL user services (each = one playbook)
│   ├── home-assistant.yml# Example service (canonical Traefik file-provider pattern)
│   ├── nextcloud.yml     # Example service
│   └── sftp-share.yml    # Example service (exposes a raw port, not via Traefik)
├── webui/                # Django management UI (shipped as the symbios-ui container)
├── desktop/              # Optional desktop environment playbooks (Raspberry Pi)
├── symbpios-image/       # Raspberry Pi OS image builder (first-boot installer via rc.local)
└── LICENSE
```

On the target host all data lives under the `/symbios` data root (which may
itself be a LUKS-encrypted disk, see `scripts/symbios-data-partition.sh`):

```
/symbios/
├── git/SymbiOS/                  # The repository itself (mounted read-only into the WebUI)
├── base-services/                # Core stacks (symbios-ui, traefik, ldap, authelia, …)
├── services/                     # User service stacks (one dir per installed service)
├── docker/                       # Docker data root (daemon.json "data-root")
├── containerd/                   # containerd data root (containerd config.toml)
├── backups/                      # SymbiOS backups
└── home/symbios                  # symlink target of /home (only if /home was empty)
```

`/home` becomes a symlink to `/symbios/home` on first install (the playbook
skips this if `/home` already contains user data). The live inventory is at
`/symbios/base-services/symbios-ui/config/inventory.yml`. User-uploaded playbooks
are stored in `/symbios/base-services/symbios-ui/config/user-playbooks/`
(see section 11). `/var/log` stays on the root filesystem.

---

## 4. The base system

The `base-services/` directory contains the Ansible playbooks that build the
platform. `install.sh` runs them in dependency order. Each playbook manages one
concern and is idempotent, so it is safe to re-run any of them.

| Playbook             | Purpose                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `basics.yml`         | Base OS setup: apt upgrade, locale/timezone, hostname, essentials.      |
| `localization.yml`   | Timezone, keyboard layout and system locale.                            |
| `hardening.yml`      | SSHd hardening, kernel/sysctl and permission hardening.                 |
| `firewall.yml`       | `ufw` firewall; opens SSH (port 33), and the ports services need.      |
| `backup.yml`         | Installs `rsync` and `/usr/local/sbin/backup.d/` backup hooks.          |
| `autoupdate.yml`     | Unattended upgrades via `/usr/local/sbin/autoupdate.d/`.                |
| `runchecks.yml`      | Health/SMART/mdadm checks in `/usr/local/sbin/runchecks.d/`.            |
| `docker.yml`         | Installs Docker, creates the `docker` user/group.                       |
| `dedyn.yml`          | deSEC (dedyn.io) dynamic-DNS client; forces EUI-64 IPv6 addressing (stable interface ID). |
| `traefik.yml`        | Deploys the Traefik reverse proxy (file provider, no Docker socket).   |
| `traefik-static.yml` | Traefik static config template (entrypoints, ACME resolver).            |
| `ldap.yml`           | Deploys OpenLDAP.                         |
| `authelia.yml`       | Deploys Authelia (SSO/2FA/OIDC) and its access-control rules.          |
| `smtp.yml`           | Writes an SMTP client marker file when mail is configured.             |
| `ssh-keys.yml`       | Deploys `root/.ssh/authorized_keys` from the inventory.                |
| `raspberry.yml`      | Raspberry-Pi-specific setup (desktop, video, boot tweaks).             |
| `symbios-ui.yml`     | Builds the WebUI container + systemd timers/index scripts.             |

### Traefik (`traefik.yml`)

- Runs the `traefik:latest` image with **no Docker socket mount**.
- Entrypoints: `http` (:80, redirects to https), `https` (:443).
- One certificate resolver: `letsencrypt` - public ACME (HTTP-01 challenge).
- Middlewares are defined in `providers/_default.yml`: `secHeaders@file`,
  `authelia@file` (forward auth to Authelia), and `default-basic-auth@file`.
- Routing is loaded from `providers/` (see section 7).

### Authelia (`authelia.yml`)

Provides single sign-on in front of protected hosts. The `authelia@file`
middleware in Traefik redirects unauthenticated users to
`auth.<base_domain>`. Configuration (including the `access_control` block,
rendered from `authelia-access-control.j2`) is regenerated by the playbook.

### LDAP (`ldap.yml`)

- `openldap` - the directory server (backend for Authelia and apps).

---

## 5. Domains, TLS and certificates

Certificates are obtained from **Let's Encrypt** via the `letsencrypt` ACME
resolver (HTTP-01 challenge). The `acme_resolver` variable is hardcoded to
`letsencrypt`:

```yaml
acme_resolver: "letsencrypt"
```

Subdomains are derived from `base_domain`:

```yaml
base_domain:     "<your-domain>"   # shared parent for all services
```

---

## 6. External services and network access

For transparency, SymbiOS communicates with the following external services
during normal operation. Everything marked *optional* is only contacted when
the matching feature is configured or installed.

| Service | Purpose | Contacted |
|---------|---------|-----------|
| **Let's Encrypt** (`acme-v02.api.letsencrypt.org`) | Issues the TLS certificates for `*.{{ base_domain }}` (ACME HTTP-01 challenge). Only during issuance/renewal. | always (Traefik) |
| **deSEC** (`desec.io` API) | Dynamic-DNS updates and domain/rrsets management. | when DDNS is configured |
| **deSEC echo services** (`checkipv4.dedyn.io`, `checkipv6.dedyn.io`) | Determine the current public IP (DynDNS updates). | when DDNS is configured |
| **Debian apt repositories** (`deb.debian.org`, `security.debian.org`) | Base system package updates. | always |
| **Docker apt repository** (`download.docker.com`) | Installs/updates the Docker engine. | `docker.yml` |
| **PyPI** (`pypi.org`) | Downloads Python dependencies when building the WebUI container. | WebUI build |
| **Docker Hub** (`docker.io`) | Pulls the `traefik` and `authelia` images (and any user-installed service images). | always / per service |
| **GitHub Container Registry** (`ghcr.io`) | Optional service images (`paperless-ngx`, `home-assistant`, …). | per service |
| **GitHub** (`github.com/egabosh/SymbiOS`, `raw.githubusercontent.com`) | Clones/pulls the SymbiOS repo during install and automatic updates. | install/update |
| **GitHub** (`github.com/egabosh/gaboshlib`) | Installs the shared bash library. | `basics.yml` |
| **Raspberry Pi** (`downloads.raspberrypi.com`) | Downloads the base Raspberry Pi OS image. | image builder only |
| **Digitalcourage DNS** (`dns3.digitalcourage.de`) | Internet-connectivity ping in the health checks. | every 5 min |
| **Qualys SSL Labs** (`ssllabs.com`) | TLS grade scan of hosted services. | optional script |

The host resolves DNS through its locally configured resolver (systemd-resolved
/ router DHCP), so every domain lookup also reaches the configured upstream
nameserver.

When enabled, the following **user-configurable** connections are made:

- **SMTP relay** (`smtp_server`) - sends notification mails.
- **Backup server** (`backup_server_host`) - `rsync`/SSH off-site backups.
- **deSEC API token** (`ddns_apikey`) - required for DynDNS updates.

Services installed via `services/` are free to contact their own external
endpoints (e.g. Matrix federation, map tiles) and pull their container images
from public registries. See each service playbook for details.

### Port forwarding and IPv6

Incoming connections are managed from the WebUI (**Settings → Port
Forwarding**) and handled by the router dispatcher
`scripts/symbios-router-upnp.sh`:

- **FRITZ!Box (AVM)** - `symbios-router-fritz.py` authenticates via PBKDF2 and
  manages device-bound port rules through the `data.lua` API.
- **Generic UPnP routers** - TR-064 SOAP (`AddPortMapping`/`DeletePortMapping`),
  no credentials required.

Operational notes for FRITZ!Box with dual-stack:

- The box assigns IPv6 host addresses by **SLAAC only**, so IPv6 port rules are
  **device-bound** and follow the device's current address.
- IPv6 rules therefore need a **stable interface ID**. `dedyn.yml` forces
  EUI-64 address generation and disables IPv6 privacy extensions, so the IID
  survives upstream prefix changes; rule creation derives the IID from the
  device's current global address instead of the box's (often stale) stored
  value.
- The box only supports IPv6 forwards where the external and internal port are
  equal (no port remapping).
- A separate gateway between ISP router and host is supported: the gateway must
  forward the ISP prefix to the router, and the host rules keep working across
  prefix changes.

---

## 7. Networking and Traefik routing

All proxyable containers attach to one external Docker network named
**`traefik`** (bridge `br-traefik`, Traefik itself has the static IP
`192.168.41.200`). Traefik reaches each backend by its service name / IP on
that network.

Routing is **file-provider based**. Traefik watches
`/symbios/base-services/traefik/providers/` (mounted as `/etc/traefik/providers.local`).
Files there:

- `_default.yml` - shared middlewares (`secHeaders@file`, `authelia@file`, …).
- `symbios-services.yml` - generated from `traefik-services.j2`; contains the
  core routers (authelia, symbios-ui, traefik dashboard).
- `default-basic-auth.usersfile` - basic-auth user file.
- One extra file **per user service** (the recommended way to expose a service).

A minimal router snippet (YAML) looks like:

```yaml
http:
  routers:
    myapp:
      rule: "Host(`myapp.{{ base_domain }}`)"
      entryPoints: ["https"]
      middlewares: ["secHeaders@file", "authelia@file"]
      service: myapp
      tls:
        certResolver: "{{ acme_resolver }}"
  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://myapp:8080"
```

Because the directory is watched, dropping/updating such a file reconfigures
Traefik with no restart.

> Note: the example service `services/nextcloud.yml` still carries legacy
> `traefik.*` Docker labels. Those labels are inert now (the Docker provider is
> disabled). `services/home-assistant.yml` shows the current, correct pattern
> (write a provider snippet). New services should follow the file-provider
> pattern.

---

## 8. Installation

### Raspberry Pi image

A prebuilt image is planned; see the top of the repository for the current
image status.

### Manual install (any Debian)

You need a basic Debian install with root SSH access (SymbiOS uses port 33 for
SSH).

```bash
# on the target machine
wget https://raw.githubusercontent.com/egabosh/SymbiOS/refs/heads/main/install.sh
sudo bash install.sh
```

`install.sh` will:

1. Install Ansible + `community.general`.
2. Clone this repo to `/symbios/git/SymbiOS` (or pull updates).
3. Create `/symbios/base-services/symbios-ui/config/inventory.yml` from the bundled
   template on first run.
4. Run the base-services playbooks in order (basics -> localization ->
   hardening -> firewall -> backup -> autoupdate -> runchecks -> docker ->
   dedyn -> ldap -> raspberry (if Pi) -> symbios-ui). The `traefik.yml` and
   `authelia.yml` playbooks are kept commented out at install time - they
   require `base_domain` and are applied from the WebUI after configuration.
5. On a Raspberry Pi, also apply `raspberry.yml` and the
   `desktop/firefox.yml` desktop playbook.

After install, edit the inventory to set `base_domain` and
(optionally) deSEC credentials, then apply them via the WebUI (which runs the
matching playbook over SSH, see section 9).

---

## 9. Managing the system (WebUI / SSH)

- **symbios-ui** is a Django web app (container `symbios-webui`) that reads the
  inventory and lets you change settings, add/remove services, and start/stop
  containers. The **Services** section in the sidebar lists all discovered
  playbooks (built-in, service, and custom) and lets you run their actions.
  Uploaded playbooks appear under **Custom Playbooks** with a distinct visual
  style and can be managed from **Settings → Playbooks**.
- **No daemon is involved.** Every settings change is applied immediately: the
  WebUI runs the matching base-services playbook over SSH (e.g. saving DDNS runs
  `dedyn.yml`, saving Auth runs `authelia.yml`, saving the mailserver runs
  `smtp.yml`). Inventory edits made directly on the host can be applied the
  same way by running the relevant playbook via SSH.
- **symbios-exec.sh** is the minimal executor the WebUI invokes over SSH. It
  receives a concrete, already-resolved command, audit-logs the invocation
  (client IP, command, syslog + `/var/log/symbios-exec.log`) and runs it. The
  webui's SSH key is a normal root key with **no `command=` restriction** -
  trusted admins operate the host, so the executor imposes no command allow-list.
  All verb logic (status / action / log resolution, catalog building) lives in
  the WebUI, which parses the playbooks' `# docs:` blocks locally.
- **Secrets stay on the host.** The WebUI container mounts the playbook repo
  read-only at `/repo` (see `base-services/symbios-ui.yml`); the repo only ever
  contains runtime-generated placeholders (`!...!`), never real credentials.
  Real secrets live in each service's `/symbios/services/<name>/env` and are never
  mounted into the WebUI.

Manual equivalents:

```bash
# re-apply a base-services playbook
ansible-playbook --limit localhost \
  --inventory /symbios/base-services/symbios-ui/config/inventory.yml \
  /symbios/git/SymbiOS/base-services/traefik.yml

# run a service playbook
ansible-playbook --connection=local \
  --inventory /symbios/base-services/symbios-ui/config/inventory.yml \
  --limit localhost \
  -e ansible_python_interpreter=/usr/bin/python3 \
  /symbios/git/SymbiOS/services/home-assistant.yml
```

---

## 10. Adding your own service

Full documentation for creating service playbooks, the `# docs:` block format,
healthcheck scripts, and user-uploaded playbooks is available in the WebUI at
**Services** (or directly from the repository at
`webui/main/docs/services.md`).

Summary of the workflow:

1. Create `services/<name>.yml` with a `# docs:` header and Ansible tasks.
2. The playbook creates a Docker Compose stack under `/symbios/services/<name>/`
   and (optionally) a Traefik provider snippet for HTTP routing.
3. The WebUI discovers it via the `# docs:` block and presents install/stop/restart
   buttons, live logs, and health status.
4. Deploy from the WebUI or manually:
   ```bash
   ansible-playbook --connection=local \
     --inventory /symbios/base-services/symbios-ui/config/inventory.yml \
     --limit localhost \
     -e ansible_python_interpreter=/usr/bin/python3 \
     /symbios/git/SymbiOS/services/<name>.yml
   ```

---

## 11. User-uploaded playbooks

Upload custom Ansible playbooks through **Settings > Playbooks** in the WebUI.
They are stored on the host at `/symbios/base-services/symbios-ui/config/user-playbooks/`
and appear in the Services section under **Custom Playbooks**. See the WebUI
documentation for the required `# docs:` format and upload workflow.

---

## License

SymbiOS is licensed under the [GNU General Public License v3.0](LICENSE).

```
SymbiOS  Copyright (c) 2026, Oliver Bohlen

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

---

## Disclaimer

SymbiOS is provided **"as is"**, without warranty of any kind, express or
implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose, and noninfringement. In no event shall the
authors, contributors, or copyright holders be liable for any claim, damages,
or other liability, whether in an action of contract, tort, or otherwise,
arising from, out of, or in connection with the software or the use or other
dealings in the software.

**SymbiOS manages critical system infrastructure** - firewalls, LDAP
directories, TLS certificates, Docker containers, and reverse proxy routing.
Incorrect configuration can lead to service outages, data loss, or security
vulnerabilities. Always:

- **Back up your system** before making changes.
- **Test in a staging environment** before deploying to production.
- **Review playbooks** before running them, especially third-party or
  user-uploaded playbooks.
- **Keep your system updated** and monitor the health dashboard.

The SymbiOS project and its contributors assume **no responsibility** for
damage, data loss, service disruptions, or security incidents resulting from
the use or misuse of this software. Use it at your own risk.

---

## AI

Parts of this project were developed with the assistance of AI coding tools.


