# Services in SymbiOS

## What is a service?

A **service** in SymbiOS is a single Ansible playbook that deploys and manages a Docker
container on the host. Each service creates:

- A Docker Compose stack under `/home/docker/<name>/`
- A Traefik provider snippet for HTTP routing (optional)
- Status checks, log streams, and lifecycle actions the WebUI can control

The WebUI discovers services automatically from the playbook's `# docs:` block
and presents them in the **Services** section with install/uninstall/start/stop
buttons, live logs, and health status.

---

## Built-in services vs. custom services

SymbiOS ships two types of playbooks:

| Type | Location | Description |
|------|----------|-------------|
| **Base services** | `base-services/` | Core platform components (Traefik, Authelia, LDAP, Docker, etc.) |
| **Services** | `services/` | Additional applications you can deploy (Nextcloud, Home Assistant, etc.) |
| **Custom playbooks** | User-uploaded | Your own playbooks, uploaded via the WebUI |

Base services are built-in and cannot be uninstalled. Services can be installed,
uninstalled, and managed individually.

---

## How to build your own service playbook

### 1. Create the playbook

Create a file `services/<name>.yml` with two parts:
a `# docs:` header (WebUI metadata) and the Ansible tasks.

### 2. The `# docs:` block

The `# docs:` block at the top of the file tells the WebUI everything it needs
to know: title, description, available actions, status checks, and log streams.

```yaml
# docs:
#   short_description: Deploy the Nextcloud service
#   description: Deploys Nextcloud together with its database and storage.
#   author: Your Name
#   version: '1.0'
#   license: GPLv3
#   category: Service
#   service_control:
#     services:
#       - name: nextcloud
#         type: docker
#         compose_file: /home/docker/nextcloud/docker-compose.yml
#         status: test -d /home/docker/nextcloud || exit 2; docker compose -f /home/docker/nextcloud/docker-compose.yml ps | grep -q "Up "
#     logs:
#       - name: nextcloud
#         command: docker compose -f /home/docker/nextcloud/docker-compose.yml logs -f --tail=100
#   actions:
#     start:    docker compose -f /home/docker/nextcloud/docker-compose.yml up -d
#     stop:     docker compose -f /home/docker/nextcloud/docker-compose.yml down
#     restart:  docker compose -f /home/docker/nextcloud/docker-compose.yml restart
#     uninstall: docker compose -f /home/docker/nextcloud/docker-compose.yml down
```

#### Fields

- **`short_description` / `description`** — title and longer text shown in the WebUI.
- **`author`, `version`, `license`, `copyright`, `min_ansible_version`, `platforms`, `category`** — informational metadata.
- **`service_control.services[]`** — one entry per container:
  - **`name`** — container/service name
  - **`type: docker`** — service type
  - **`compose_file`** — path to the Docker Compose file
  - **`status`** — shell command; exit code tells the WebUI the state:
    - `0` = running
    - `2` or `4` = not installed
    - anything else = stopped/error
- **`service_control.logs[]`** — each item has a `name` and a `command` for live log following.
- **`actions`** — mapping of action name to shell command. Every key becomes a button in the WebUI. Common names: `start`, `stop`, `restart`, `reload`, `uninstall`.

### 3. The Ansible tasks

```yaml
---
- name: myapp
  hosts: all
  vars:
    service_name: "myapp"
    service_domain: "{{ base_domain }}"
  tasks:
    # Create the service directory
    - name: Create service directory
      ansible.builtin.file:
        path: /home/docker/{{ service_name }}
        owner: root
        group: docker
        state: directory
        mode: '0550'

    # Write the Docker Compose file
    - name: /home/docker/{{ service_name }}/docker-compose.yml
      ansible.builtin.blockinfile:
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
                - traefik
          networks:
            traefik:
              external: true
        backup: yes
      notify: Restart {{ service_name }}

    # Traefik routing via the FILE PROVIDER
    - name: Traefik provider snippet for {{ service_name }}
      ansible.builtin.blockinfile:
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
      ansible.builtin.shell: docker compose up -d
      args:
        chdir: /home/docker/{{ service_name }}
```

---

## Rules of thumb

- **Always join the `traefik` external network** — otherwise Traefik cannot reach the container.
- **Never use `traefik.*` Docker labels** — the Docker provider is disabled. Use a file-provider snippet instead.
- Pick a unique subdomain: `{{ service_name }}.{{ base_domain }}`
- Protect the route with `authelia@file` unless it must be public. Public routes still get `secHeaders@file`.
- Use `{{ acme_resolver }}` so the playbook works in both local and public modes.
- For non-HTTP services (SFTP, TCP/UDP relays), just publish the port in Compose and open it with `ufw`.

---

## Healthcheck scripts

Every service should deploy a healthcheck script to
`/usr/local/sbin/runchecks.d/symbios-healthcheck-<name>.check` (where `<name>`
is the playbook filename without `.yml`). The `runchecks.sh` daemon iterates
over all `*.check` files every 5 minutes.

### Web-facing services (HTTP)

```yaml
    - name: /usr/local/sbin/runchecks.d/symbios-healthcheck-{{ service_name }}.check
      ansible.builtin.blockinfile:
        path: /usr/local/sbin/runchecks.d/symbios-healthcheck-{{ service_name }}.check
        mode: "0400"
        owner: root
        group: root
        create: yes
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          # Healthcheck for {{ service_name }}
          g_svc_url="https://{{ service_domain }}"
          g_check_file="${g_tmp}/symbios-healthcheck-{{ service_name }}"
          if [ -f "$g_check_file" ] && find "$g_check_file" -mmin -5 | grep -q "$g_check_file"
          then
            return 2>/dev/null || true
          fi
          date > "$g_check_file"
          g_http_code=$(wget -q -O /dev/null --server-response --timeout=10 "$g_svc_url" 2>&1 | grep -oE "HTTP/[0-9.]+" | tail -1 | grep -oE "[0-9]+$")
          if [ -z "$g_http_code" ] || [ "$g_http_code" -ge 500 ]
          then
            g_echo_error "Healthcheck failed for {{ service_name }}: HTTP $g_http_code from $g_svc_url"
          fi
        backup: yes
        validate: /bin/bash -n %s
```

### Non-web services (Docker containers)

```yaml
    - name: /usr/local/sbin/runchecks.d/symbios-healthcheck-{{ service_name }}.check
      ansible.builtin.blockinfile:
        path: /usr/local/sbin/runchecks.d/symbios-healthcheck-{{ service_name }}.check
        mode: "0400"
        owner: root
        group: root
        create: yes
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          # Healthcheck for {{ service_name }} (container)
          if ! docker ps | grep -q "{{ service_name }}"
          then
            g_echo_error "Healthcheck failed for {{ service_name }}: container not running"
          fi
        backup: yes
        validate: /bin/bash -n %s
```

### Conventions

- File name: `symbios-healthcheck-<name>.check`
- Uses `g_echo_error` from gaboshlib for error reporting (logged to syslog)
- Uses `g_tmp` for 5-minute cooldown file to avoid redundant checks
- HTTP status `>= 500` or connection failure = error; `200`-`499` = healthy
- The `runchecks.sh` daemon picks up new/changed `.check` files automatically

---

## User-uploaded playbooks

Besides built-in playbooks, you can upload custom Ansible playbooks through the
WebUI at **Settings > Playbooks**. Uploaded playbooks are stored on the host at
`/home/docker/symbios-ui/config/user-playbooks/` and appear in the Services
section under **Custom Playbooks**.

### How it works

- **Upload**: Go to **Settings > Playbooks**. Select one or more `.yml` files. Filenames are sanitized to `[a-z0-9_-]` and must end in `.yml`.
- **Discovery**: The catalog scanner reads the `user-playbooks/` directory. Playbooks without a `# docs:` block are ignored.
- **Execution**: Uploaded playbooks are run exactly like built-in ones.
- **Delete**: Remove them from **Settings > Playbooks**.

### Minimum format

```yaml
# docs:
#   short_description: My custom backup job
#   description: Runs a backup to an external NFS mount.
#   actions:
#     run:
#       command: /usr/local/sbin/my-backup.sh
#
---
- name: My custom backup
  hosts: localhost
  tasks:
    - name: Run backup
      ansible.builtin.command: /usr/local/sbin/my-backup.sh
```

> User-uploaded playbooks are stored on the host (not in the git repository)
> and survive container restarts. They are **not** backed up automatically.

---

## State-file install tracking

SymbiOS keeps a persistent record of which playbooks are currently installed in
`/home/docker/symbios-ui/config/installed-playbooks.yml`. Each line contains a
playbook path and an ISO timestamp:

```yaml
# Auto-maintained by playbooks via symbios-state.sh
base-services/traefik.yml: "2025-07-21T12:30:00Z"
base-services/authelia.yml: "2025-07-21T12:30:05Z"
```

### How it works

- **`symbios-state.sh`** (`/usr/local/sbin/symbios-state.sh`) manages the state file.
  Commands: `set <path>` (register), `unset <path>` (remove), `list` (print paths),
  `is-installed <path>` (exit 0/1).

- **Automatic registration** — every time the WebUI runs (Re)Install successfully,
  it calls `symbios-state.sh set <playbook>` on the host. Uninstall calls `symbios-state.sh unset <playbook>`.

- **`symbios-reapply.sh`** (`/usr/local/sbin/symbios-reapply.sh`) reads the state file
  and re-runs all registered playbooks in dependency order. Runs in the background.

### When reapply runs

- After any settings save, only the relevant playbooks are re-run (e.g. localization
  only re-runs `localization.yml` and `raspberry.yml`).
- The WebUI can trigger a reapply via `symbios-reapply.sh [--only <playbook> ...]`.
- Progress is written to `/tmp/symbios-reapply.status` and polled by the WebUI.

### Manual equivalents

```bash
symbios-state.sh list                        # list installed playbooks
symbios-state.sh is-installed base-services/traefik.yml  # check if installed
symbios-reapply.sh                           # full reapply
symbios-reapply.sh --only base-services/localization.yml base-services/raspberry.yml  # specific playbooks
cat /home/docker/symbios-ui/log/reapply.log  # view reapply log
```

---

## Discovery and lifecycle

- Service lifecycle (`playbook`, `start` = `docker compose up -d`, `stop` =
  `docker compose down`) is driven by the WebUI. The WebUI container has the
  playbooks mounted read-only at `/repo`; `webui/main/playbook_catalog.py`
  parses each playbook's `# docs:` block to build the catalog (services,
  actions, status and log commands) entirely on the WebUI side.
- For a **manual** run on the host:
  ```bash
  ansible-playbook --connection=local \
    --inventory /home/docker/symbios-ui/config/inventory.yml \
    --limit localhost \
    -e ansible_python_interpreter=/usr/bin/python3 \
    /home/SymbiOS/services/<name>.yml
  ```
  Or manage the container directly with `docker compose` in `/home/docker/<name>/`.

> **Secrets**: only runtime-generated placeholders (`!...!`) ever appear in a
> playbook. Real credentials live in `/home/docker/<name>/env` and are never
> part of the repo or the `# docs:` block.
