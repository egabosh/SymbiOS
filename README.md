# SymbiOS

Debian-based distribution for self-hosted servers. SymbiOS turns a plain
Debian machine into a managed, containerized home/server platform: a reverse
proxy with automatic TLS, single sign-on with two-factor auth, an LDAP
directory, a local fallback CA, and a web UI to manage it all. On top of the
base system you can drop in your own services through the `services/`
subdirectory.

- Source: <https://github.com/egabosh/SymbiOS>
- Target OS: Debian (also runs on Raspberry Pi OS)

---

## Table of contents

1. [What SymbiOS does](#1-what-symbios-does)
2. [Architecture overview](#2-architecture-overview)
3. [Repository layout](#3-repository-layout)
4. [The base services](#4-the-base-services)
5. [Domains, TLS and certificates](#5-domains-tls-and-certificates)
6. [Networking and Traefik routing](#6-networking-and-traefik-routing)
7. [Installation](#7-installation)
8. [Managing the system (WebUI / SSH)](#8-managing-the-system-webui--ssh)
9. [Adding your own service](#9-adding-your-own-service)

---

## 1. What SymbiOS does

SymbiOS provisions and wires together a set of core services so that adding a
new web app is mostly "write one playbook and drop it in `services/`":

| Concern            | Provided by                                         |
|--------------------|-----------------------------------------------------|
| Reverse proxy / TLS| Traefik (file-provider based routing)               |
| Authentication     | Authelia (SSO, 2FA, OpenID Connect)                 |
| User directory     | OpenLDAP + LDAP Account Manager (LAM)               |
| Certificates       | Let's Encrypt (public) + step-ca local CA (offline)|
| Dynamic DNS        | deSEC (dedyn.io) client                             |
| Management UI      | symbios-ui (Django web interface)                 |
| App isolation      | Docker, one compose stack per service               |

Everything is driven by Ansible playbooks. There is no long-running agent: the
web UI runs playbooks on the host **directly over SSH** through a minimal
audit-logging executor (`symbios-exec.sh`). The WebUI container has the
playbook sources mounted read-only at `/repo`; it parses their machine-readable
`# docs:` blocks locally, resolves every status/action/log command itself, and
ships only the concrete command to the host (no host-side verb dispatch, no
secrets leave the host). The webui's SSH key is a normal root key — trusted
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
`/home/docker/traefik/providers/`, which Traefik watches at runtime. A service
becomes reachable by (a) joining the external `traefik` Docker network and
(b) dropping a provider snippet that points a `Host(...)` rule at the
container's IP/port.

---

## 3. Repository layout

```
SymbiOS/
├── install.sh            # Bootstrap: install ansible, clone repo, run base-services
├── inventory.yml         # Template inventory (copied to the host on first install)
├── symbios-exec.sh       # Minimal audit-logging SSH executor used by the WebUI
├── base-services/          # Core Ansible playbooks (the "Basisservices")
│   ├── *.yml             # One playbook per concern (see section 4)
│   ├── traefik-services.j2   # Template -> /home/docker/traefik/providers/symbios-services.yml
│   ├── authelia-access-control.j2  # Template -> Authelia access_control block
│   ├── lam.conf          # LAM configuration template
│   └── traefik-static.yml# Traefik static config (entrypoints, etc.)
├── services/             # OPTIONAL user services (each = one playbook)
│   ├── home-assistant.yml# Example service (canonical Traefik file-provider pattern)
│   ├── nextcloud.yml     # Example service
│   └── sftp-share.yml    # Example service (exposes a raw port, not via Traefik)
├── webui/                # Django management UI (shipped as the symbios-ui container)
├── desktop/              # Optional desktop environment playbooks (Raspberry Pi)
└── LICENSE
```

On the target host the repo lives at `/home/SymbiOS`, and generated service
state lives under `/home/docker/<service>/`. The live inventory is at
`/home/docker/symbios-ui/config/inventory.yml`.

---

## 4. The base system

The `base-services/` directory contains the Ansible playbooks that build the
platform. `install.sh` runs them in dependency order. Each playbook manages one
concern and is idempotent, so it is safe to re-run any of them.

| Playbook             | Purpose                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `basics.yml`         | Base OS setup: apt upgrade, locale/timezone, hostname, essentials.      |
| `hardening.yml`      | SSHd hardening, kernel/sysctl and permission hardening.                 |
| `firewall.yml`       | `ufw` firewall; opens SSH (port 33), and the ports services need.      |
| `backup.yml`         | Installs `rsync` and `/usr/local/sbin/backup.d/` backup hooks.          |
| `autoupdate.yml`     | Unattended upgrades via `/usr/local/sbin/autoupdate.d/`.                |
| `runchecks.yml`      | Health/SMART/mdadm checks in `/usr/local/sbin/runchecks.d/`.            |
| `docker.yml`         | Installs Docker, creates the `docker` user/group.                       |
| `dedyn.yml`          | deSEC (dedyn.io) dynamic-DNS client (`/usr/local/sbin/dedyn.sh`).       |
| `acme-pki.yml`       | Local fallback CA: runs `step-ca` to issue certs offline (`.local`).    |
| `traefik.yml`        | Deploys the Traefik reverse proxy (file provider, no Docker socket).   |
| `ldap.yml`           | Deploys OpenLDAP + LDAP Account Manager (LAM).                         |
| `authelia.yml`       | Deploys Authelia (SSO/2FA/OIDC) and its access-control rules.          |
| `smtp.yml`           | Writes an SMTP client marker file when mail is configured.             |
| `ssh-keys.yml`       | Deploys `root/.ssh/authorized_keys` from the inventory.                |
| `raspberry.yml`      | Raspberry-Pi-specific setup (desktop, video, boot tweaks).             |
| `symbios-ui.yml`     | Builds the WebUI container + systemd timers/index scripts.             |

### Traefik (`traefik.yml`)

- Runs the `traefik:latest` image with **no Docker socket mount**.
- Entrypoints: `http` (:80, redirects to https), `https` (:443),
  `ldaps` (:636, local mode only).
- Two certificate resolvers:
  - `letsencrypt` — public ACME (HTTP-01 challenge).
  - `symbios-pki` — the local step-ca ACME directory (for `.local`).
- Middlewares are defined in `providers/_default.yml`: `secHeaders@file`,
  `authelia@file` (forward auth to Authelia), and `default-basic-auth@file`.
- Routing is loaded from `providers/` (see section 6).

### Authelia (`authelia.yml`)

Provides single sign-on in front of protected hosts. The `authelia@file`
middleware in Traefik redirects unauthenticated users to
`auth.<base_domain>`. Configuration (including the `access_control` block,
rendered from `authelia-access-control.j2`) is regenerated by the playbook.

### LDAP (`ldap.yml`)

- `openldap` — the directory server (backend for Authelia and apps).
- `ldap.<base_domain>` (LAM) — LDAP Account Manager web UI, exposed **only in
  local mode** (`default_domain == 'local'`) for safety.
- In local mode an LDAPS router (`openldap.local:636`) is published on
  `:636` using the local CA.

---

## 5. Domains, TLS and certificates

SymbiOS operates in one of two modes, selected by `default_domain` in the
inventory:

- **`local`** — hostname-based, offline. `base_domain` is something like
  `symbios.local`. Certificates come from the built-in **step-ca** local CA
  (`symbios-pki` resolver). No public DNS needed.
- **Public (dedyn)** — `default_domain` is a real domain (e.g.
  `symbios-dev.dedyn.io`). Certificates come from **Let's Encrypt**
  (`letsencrypt` resolver), and `dedyn.yml` keeps the DNS A/AAAA records
  updated via deSEC.

The `acme_resolver` variable is derived automatically:

```yaml
acme_resolver: "{{ 'symbios-pki' if default_domain == 'local' else 'letsencrypt' }}"
```

Subdomains are derived from `base_domain`:

```yaml
base_domain:     "symbios-dev.dedyn.io"   # shared parent for all services
symbios_domain:  "{{ base_domain }}"      # the main UI / landing host
authelia_domain: "auth.{{ base_domain }}" # SSO login host
traefik_domain:  "traefik.{{ base_domain }}"# proxy dashboard host
```

---

## 6. Networking and Traefik routing

All proxyable containers attach to one external Docker network named
**`traefik`** (bridge `br-traefik`, Traefik itself has the static IP
`192.168.41.200`). Traefik reaches each backend by its service name / IP on
that network.

Routing is **file-provider based**. Traefik watches
`/home/docker/traefik/providers/` (mounted as `/etc/traefik/providers.local`).
Files there:

- `_default.yml` — shared middlewares (`secHeaders@file`, `authelia@file`, …).
- `symbios-services.yml` — generated from `traefik-services.j2`; contains the
  core routers (authelia, symbios-ui, traefik dashboard, and ldap in local
  mode).
- `symbios-pki-ca.pem`, `default-basic-auth.usersfile` — CA cert and basic-auth
  user file.
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

## 7. Installation

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
2. Clone this repo to `/home/SymbiOS` (or pull updates).
3. Create `/home/docker/symbios-ui/config/inventory.yml` from the bundled
   template on first run.
4. Run the base-services playbooks in order (basics -> hardening -> firewall ->
   backup -> autoupdate -> runchecks -> docker -> dedyn -> acme-pki -> traefik
   -> ldap -> authelia -> symbios-ui).
5. On a Raspberry Pi, also apply `raspberry.yml` and the desktop playbook.

After install, edit the inventory to set `base_domain` / `default_domain` and
(optionally) deSEC credentials, then apply them via the WebUI (which runs the
matching playbook over SSH, see section 8).

---

## 8. Managing the system (WebUI / SSH)

- **symbios-ui** is a Django web app (container `symbios-webui`) that reads the
  inventory and lets you change settings, add/remove services, and start/stop
  containers.
- **No daemon is involved.** Every settings change is applied immediately: the
  WebUI runs the matching base-services playbook over SSH (e.g. saving DDNS runs
  `dedyn.yml`, saving Auth runs `authelia.yml`, saving the mailserver runs
  `smtp.yml`). Inventory edits made directly on the host can be applied the
  same way by running the relevant playbook via SSH.
- **symbios-exec.sh** is the minimal executor the WebUI invokes over SSH. It
  receives a concrete, already-resolved command, audit-logs the invocation
  (client IP, command, syslog + `/var/log/symbios-exec.log`) and runs it. The
  webui's SSH key is a normal root key with **no `command=` restriction** —
  trusted admins operate the host, so the executor imposes no command allow-list.
  All verb logic (status / action / log resolution, catalog building) lives in
  the WebUI, which parses the playbooks' `# docs:` blocks locally.
- **Secrets stay on the host.** The WebUI container mounts the playbook repo
  read-only at `/repo` (see `base-services/symbios-ui.yml`); the repo only ever
  contains runtime-generated placeholders (`!...!`), never real credentials.
  Real secrets live in each service's `/home/docker/<name>/env` and are never
  mounted into the WebUI.

Manual equivalents:

```bash
# re-apply a base-services playbook
ansible-playbook --limit localhost \
  --inventory /home/docker/symbios-ui/config/inventory.yml \
  /home/SymbiOS/base-services/traefik.yml

# run a service playbook
ansible-playbook --connection=local \
  --inventory /home/docker/symbios-ui/config/inventory.yml \
  --limit localhost \
  -e ansible_python_interpreter=/usr/bin/python3 \
  /home/SymbiOS/services/home-assistant.yml
```

---

## 9. Adding your own service

A "service" is a single Ansible playbook in `services/<name>.yml`. It creates a
Docker compose stack under `/home/docker/<name>/` and (if it should be
web-exposed) a Traefik provider snippet. The WebUI discovers it via its `# docs:`
block and runs its actions through `symbios-exec.sh`.

### Workflow

1. Create `services/<name>.yml` (see skeleton below).
2. Make it executable-not-required; it is invoked by `ansible-playbook`.
3. Trigger it — either from the WebUI, or directly on the host:
   ```bash
   ansible-playbook --connection=local \
     --inventory /home/docker/symbios-ui/config/inventory.yml \
     --limit localhost \
     -e ansible_python_interpreter=/usr/bin/python3 \
     /home/SymbiOS/services/<name>.yml
   ```
 4. The playbook writes the compose file and a Traefik provider snippet, then
    restarts the container. Traefik picks up the new route automatically.

### The `# docs:` block (WebUI control metadata)

Each service playbook starts with a machine-readable `# docs:` block — a YAML
document written in `# ` comment lines at the very top of the file. It is the
**single source of truth for what the WebUI can do with the service**: its
title/description and which actions, status checks and log streams exist.

The WebUI container mounts the playbook repo **read-only at `/repo`** and parses
these blocks locally (`webui/main/playbook_catalog.py`) — there is no SSH
round-trip and no host-side Python for this. To run something, the WebUI
resolves the concrete command from the block and ships it to `symbios-exec.sh`
over SSH (commands are shell-quoted so the host runs them verbatim).

```yaml
# docs:
#   short_description: Deploy the Nextcloud service
#   description: Deploys Nextcloud together with its database and storage.
#   author: Oliver Bohlen
#   version: '1.0'
#   category: Service
#   service_control:
#     services:
#       - name: nextcloud
#         type: docker
#         compose_file: /home/docker/nextcloud/docker-compose.yml
#         status: test -d /home/docker/nextcloud || exit 2; docker compose -f /home/docker/nextcloud/docker-compose.yml ps | grep -q "Up "
#       logs:
#         - name: nextcloud
#           command: docker compose -f /home/docker/nextcloud/docker-compose.yml logs -f --tail=100
#   actions:
#     uninstall: docker compose -f /home/docker/nextcloud/docker-compose.yml down
#     start:    docker compose -f /home/docker/nextcloud/docker-compose.yml up -d
#     stop:     docker compose -f /home/docker/nextcloud/docker-compose.yml down
#     restart:  docker compose -f /home/docker/nextcloud/docker-compose.yml restart
#     reload:   docker compose -f /home/docker/nextcloud/docker-compose.yml up -d
```

Fields:

- **`short_description` / `description`** — title and longer text shown in the
  WebUI service list.
- **`author`, `version`, `license`, `copyright`, `min_ansible_version`,
  `platforms`, `category`** — informational metadata.
- **`service_control.services[]`** — one entry per container the service
  consists of:
  - **`name`**, **`type: docker`**, **`compose_file`** — identity and compose
    file location.
  - **`status`** — a shell command whose **exit code** tells the WebUI the
    state: `0` = running, `2`/`4` = not installed, anything else = stopped/error.
  - **`logs[]`** — each item has a `name` and a `command` used for live log
    following in the WebUI.
- **`actions`** — a mapping of action name → shell command. Every key becomes a
  button in the WebUI (common names: `start`, `stop`, `restart`, `reload`,
  `uninstall`). Each command is resolved on the WebUI side and executed on the
  host via `symbios-exec.sh`.

> Secrets: only runtime-generated placeholders (`!...!`) ever appear in a
> playbook. Real credentials live in `/home/docker/<name>/env` and are never
> part of the repo or the `# docs:` block.

### Anatomy of a service playbook

```yaml
---
- name: myapp
  hosts: all
  vars:
    service_name: "myapp"
    service_domain: "{{ base_domain }}"
  tasks:
    - name: Create service directory
      ansible.builtin.file:
        path: /home/docker/{{ service_name }}
        owner: root
        group: docker
        state: directory
        mode: '0550'

    - name: /home/docker/{{ service_name }}/docker-compose.yml
      blockinfile:
        path: /home/docker/{{ service_name }}/docker-compose.yml
        create: yes
        mode: "0440"
        owner: root
        group: docker
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          services:
            {{ service_name }}:
              image: myregistry/myapp:latest
              restart: unless-stopped
              networks:
                - traefik          # <-- join the proxy network
          networks:
            traefik:
              external: true
        backup: yes
      notify: Restart {{ service_name }}

    # Traefik routing via the FILE PROVIDER (the supported mechanism)
    - name: Traefik provider snippet for {{ service_name }}
      blockinfile:
        path: /home/docker/traefik/providers/{{ service_name }}.yml
        create: yes
        mode: "0444"
        owner: root
        group: docker
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          http:
            routers:
              {{ service_name }}:
                rule: "Host(`{{ service_name }}.{{ service_domain }}`)"
                entryPoints: ["https"]
                middlewares: ["secHeaders@file", "authelia@file"]
                service: {{ service_name }}
                tls:
                  certResolver: "{{ acme_resolver }}"
            services:
              {{ service_name }}:
                loadBalancer:
                  servers:
                    - url: "http://{{ service_name }}:8080"
        backup: yes

  handlers:
    - name: Restart {{ service_name }}
      ansible.builtin.shell: |
        docker compose up -d
      args:
        chdir: /home/docker/{{ service_name }}
```

### Rules of thumb

- **Always join the `traefik` external network**; otherwise Traefik cannot
  reach the container.
- **Do not use `traefik.*` Docker labels** — the Docker provider is disabled,
  so they are ignored. Use a provider snippet instead.
- Pick a unique subdomain: `{{ service_name }}.{{ base_domain }}`.
- Protect the route with `authelia@file` unless it must be public; public
  routes still get `secHeaders@file`.
- Use `{{ acme_resolver }}` so the same playbook works in both local and
  public modes.
- For non-HTTP services (e.g. SFTP on a custom port, like `sftp-share.yml`),
  just publish the port in compose and open it with `ufw` — no Traefik needed.

### Discovery and lifecycle

- Service lifecycle (`playbook`, `start` = `docker compose up -d`, `stop` =
  `docker compose down`) is driven by the WebUI. The WebUI container has the
  playbooks mounted read-only at `/repo`; `webui/main/playbook_catalog.py`
  parses each playbook's `# docs:` block to build the catalog (services,
  actions, status and log commands) entirely on the WebUI side. To run
  something, the WebUI resolves the concrete command and ships it to
  `symbios-exec.sh` over SSH (commands are shell-quoted so the host runs them
  verbatim).
- For a **manual** run on the host, use the same command the WebUI sends
  through `symbios-exec.sh`, e.g.
  `ansible-playbook --connection=local --inventory
  /home/docker/symbios-ui/config/inventory.yml --limit localhost -e
  ansible_python_interpreter=/usr/bin/python3 /home/SymbiOS/services/<name>.yml`
  (or `docker compose` directly in `/home/docker/<name>/`).


