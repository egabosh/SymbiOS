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
4. [The base system](#4-the-base-system)
5. [Domains, TLS and certificates](#5-domains-tls-and-certificates)
6. [Networking and Traefik routing](#6-networking-and-traefik-routing)
7. [Installation](#7-installation)
8. [Managing the system (WebUI / config daemon)](#8-managing-the-system-webui--config-daemon)
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
| Management UI      | symbios-ui (Django web interface + config daemon)  |
| App isolation      | Docker, one compose stack per service               |

Everything is driven by Ansible playbooks. There is no custom agent beyond a
small shell daemon (`symbios-configd.sh`) and a restricted SSH exec gateway
(`symbios-exec.sh`) that the web UI uses to run playbooks on the host.

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
   |  symbios-configd.sh  (watches inventory + service triggers)      |
   |  service-handler.sh  (runs a service playbook / docker compose)  |
   |  symbios-exec.sh     (restricted SSH exec used by the WebUI)     |
   +---------------------------------------------------------------+
        |
   +----v----------------------------+
   |  base-system/*.yml (Ansible)    |
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
├── install.sh            # Bootstrap: install ansible, clone repo, run base-system
├── inventory.yml         # Template inventory (copied to the host on first install)
├── cleanup.sh            # Helper to tear down / reset
├── symbios-configd.sh    # Config daemon: reacts to inventory changes + triggers
├── symbios-exec.sh       # Restricted SSH exec gateway used by the WebUI
├── base-system/          # Core Ansible playbooks (the "Basissystem")
│   ├── *.yml             # One playbook per concern (see section 4)
│   ├── traefik-services.j2   # Template -> /home/docker/traefik/providers/symbios-services.yml
│   ├── authelia-access-control.j2  # Template -> Authelia access_control block
│   ├── lam.conf          # LAM configuration template
│   └── traefik-static.yml# Traefik static config (entrypoints, etc.)
├── services/             # OPTIONAL user services (each = one playbook)
│   ├── service-handler.sh# Runs a service playbook / docker up|down
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

The `base-system/` directory contains the Ansible playbooks that build the
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
4. Run the base-system playbooks in order (basics -> hardening -> firewall ->
   backup -> autoupdate -> runchecks -> docker -> dedyn -> acme-pki -> traefik
   -> ldap -> authelia -> symbios-ui).
5. On a Raspberry Pi, also apply `raspberry.yml` and the desktop playbook.

After install, edit the inventory to set `base_domain` / `default_domain` and
(optionally) deSEC credentials, then let the config daemon apply the changes
(see section 8).

---

## 8. Managing the system (WebUI / config daemon)

- **symbios-ui** is a Django web app (container `symbios-webui`) that reads the
  inventory and lets you change settings, add/remove services, and start/stop
  containers.
- **symbios-configd.sh** runs on the host and watches:
  - the inventory file — on relevant changes it re-runs the matching
    base-system playbooks (e.g. domain change -> traefik/authelia/ldap), and
  - a trigger directory — files like `<action>-<service>.trigger` tell it to
    run a service playbook or `docker compose up|down`.
- **symbios-exec.sh** is the restricted command that the WebUI invokes over SSH
  (`command=` restriction in `authorized_keys`). It only permits
  `playbook`, `docker-compose`, and a narrow `exec` set, and only for paths
  under `base-system/` or `services/`.

Manual equivalents:

```bash
# re-apply a base-system playbook
ansible-playbook --limit localhost \
  --inventory /home/docker/symbios-ui/config/inventory.yml \
  /home/SymbiOS/base-system/traefik.yml

# run a service playbook
/home/SymbiOS/services/service-handler.sh playbook home-assistant
```

---

## 9. Adding your own service

A "service" is a single Ansible playbook in `services/<name>.yml`. It creates a
Docker compose stack under `/home/docker/<name>/` and (if it should be
web-exposed) a Traefik provider snippet. The WebUI discovers it, and the config
daemon / `service-handler.sh` runs it.

### Workflow

1. Create `services/<name>.yml` (see skeleton below).
2. Make it executable-not-required; it is invoked by `ansible-playbook`.
3. Trigger it — either from the WebUI, by dropping a trigger file, or directly:
   ```bash
   /home/SymbiOS/services/service-handler.sh playbook <name>
   ```
4. The playbook writes the compose file and a Traefik provider snippet, then
   restarts the container. Traefik picks up the new route automatically.

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

- `symbios-configd.sh` watches `services/` for changes and the trigger
  directory for `<action>-<service>.trigger` files created by the WebUI.
- `service-handler.sh` supports `playbook`, `start` (`docker compose up -d`),
  and `stop` (`docker compose down`).
- The WebUI's service-discovery reads the same directory
  (`webui/main/service_discover.py`).


