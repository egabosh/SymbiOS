# Custom Playbooks

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
#   url: "https://nextcloud.{{ base_domain }}"
#   author: Your Name
#   version: '1.0'
#   license: GPLv3
#   category: Service
#   service_control:
#     services:
#       - name: nextcloud
#         type: docker
#         compose_file: /symbios/services/nextcloud/docker-compose.yml
#         status: test -d /symbios/services/nextcloud || exit 2; docker compose -f /symbios/services/nextcloud/docker-compose.yml ps | grep -q "Up "
#     logs:
#       - name: nextcloud
#         command: docker compose -f /symbios/services/nextcloud/docker-compose.yml logs -f --tail=100
#   uninstall:
#     stop: docker compose -f /symbios/services/nextcloud/docker-compose.yml down
#     program_paths:
#       - /symbios/services/nextcloud/
#       - /symbios/base-services/traefik/providers/nextcloud.yml
#       - /usr/local/sbin/runchecks.d/symbios-healthcheck-nextcloud.check
#       - /usr/local/sbin/autoupdate.d/nextcloud.update
#   actions:
#     start:    docker compose -f /symbios/services/nextcloud/docker-compose.yml up -d
#     stop:     docker compose -f /symbios/services/nextcloud/docker-compose.yml down
#     restart:  docker compose -f /symbios/services/nextcloud/docker-compose.yml restart
```

#### Fields

- **`short_description` / `description`** - title and longer text shown in the WebUI.
- **`url`** - web interface URL for the service. Jinja variables like `{{ base_domain }}` are resolved automatically. Displayed as a clickable link on the service detail page.
- **`author`, `version`, `license`, `copyright`, `min_ansible_version`, `platforms`, `category`** - informational metadata.
- **`service_control.services[]`** - one entry per container:
  - **`name`** - container/service name
  - **`type: docker`** - service type
  - **`compose_file`** - path to the Docker Compose file
  - **`status`** - shell command; exit code tells the WebUI the state:
    - `0` = running
    - `2` or `4` = not installed
    - anything else = stopped/error
- **`service_control.logs[]`** - each item has a `name` and a `command` for live log following.
- **`uninstall`** - controls the 3-mode uninstall feature (Uninstall, Uninstall (keep data), Delete Userdata). The service dir is derived automatically for playbooks below `services/` as `$services_root/<name>/`; everything inside it (compose file, env, bind-mounted data) is treated as the service's data:
  - **`stop`** - whitelisted shell command to stop the service before deletion (`docker compose ...`, `systemctl ...` or `virsh ...`). In "full" and "program" mode a plain `docker compose ... down` is extended with `--rmi all` so the container images are removed as well (scoped to this compose project).
  - **`commands`** - optional list of whitelisted cleanup commands, executed in "full" mode only (e.g. `ufw delete allow ...`, `systemctl disable --now ...`, `userdel ...`). Allowed prefixes: `docker compose`, `systemctl`, `ufw`, `userdel`, `groupdel`, `smbpasswd`, `deluser`, `delgroup`. A failing command is logged but does not abort the uninstall.
  - **`service_dir`** - optional explicit service dir path. Must live below the services root. Only needed if it cannot be derived from the playbook name.
  - **`program_paths`** - list of files/dirs installed OUTSIDE the service dir (Traefik provider snippet, healthcheck script, autoupdate module, systemd units, scripts). Deleted recursively in "full" and "program" mode.
  - **`userdata_paths`** - legacy: extra data dirs outside the service dir. Deleted recursively in "full" and "reset" mode. Normally not needed anymore since everything below the service dir counts as userdata.

  Mode behaviour:

  | | Uninstall (full) | Uninstall (keep data) | Delete Userdata (reset) |
  |---|---|---|---|
  | stop command | yes (+`--rmi all`) | yes (+`--rmi all`) | yes |
  | `commands` cleanup | yes | no | no |
  | service dir | deleted completely | kept completely (incl. compose + data) | deleted completely |
  | `program_paths` | deleted | deleted | kept |
  | state entry | removed | removed | stays set |
  | playbook re-run | no | no | yes (fresh reprovisioning) |
- **`actions`** - mapping of action name to shell command. Every key becomes a button in the WebUI. Common names: `start`, `stop`, `restart`, `reload`.

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
        path: {{ services_root }}/{{ service_name }}
        owner: root
        group: docker
        state: directory
        mode: '0550'

    # Write the Docker Compose file
    - name: {{ services_root }}/{{ service_name }}/docker-compose.yml
      ansible.builtin.blockinfile:
        path: {{ services_root }}/{{ service_name }}/docker-compose.yml
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
        path: /symbios/base-services/traefik/providers/{{ service_name }}.yml
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
        chdir: {{ services_root }}/{{ service_name }}
```

---

## Rules of thumb

- **Always join the `symbios_services` external network** - otherwise Traefik cannot reach the container.
- **Never use `traefik.*` Docker labels** - the Docker provider is disabled. Use a file-provider snippet instead.
- Pick a unique subdomain: `{{ service_name }}.{{ base_domain }}`
- Protect the route with `authelia@file` unless it must be public. Public routes still get `secHeaders@file`.
- Use `{{ acme_resolver }}` to select the Let's Encrypt resolver.
- For non-HTTP services (SFTP, TCP/UDP relays), just publish the port in Compose and open it with `ufw`.

---

## Naming conventions

Follow these naming rules so containers, networks, and services are consistent
across the system.

### Container names

- **User services**: `symbios-<service>` (e.g. `symbios-jellyfin`, `symbios-nextcloud`)
- **Sub-containers**: `symbios-<service>-<role>` (e.g. `symbios-nextcloud-db`, `symbios-matrix-synapse`)
- **Base services** (do not touch): `symbios-base-*` (e.g. `symbios-base-traefik`, `symbios-base-ldap`)

### Docker networks

- **Always join** `symbios_services` (external, created by `docker.yml`).
- **Multi-container stacks** create an internal network named `symbios-<service>`
  (e.g. `symbios-matrix`, `symbios-nextcloud`). Set `com.docker.network.bridge.name`
  to match.
- **Single-container services** only join `symbios_services` - no extra network needed.

### Service names (Docker Compose)

Keep the service name short (for DNS resolution) and set `container_name` to the
full prefixed name:

```yaml
services:
  myapp:
    image: myapp:latest
    container_name: symbios-myapp
    networks:
      - symbios_services

networks:
  symbios_services:
    external: true
```

### Example pattern

```yaml
name: ""

services:
  symbios-myapp:
    image: myapp:latest
    container_name: symbios-myapp
    restart: unless-stopped
    networks:
      symbios-internal: {}
      symbios_services: null

networks:
  symbios-internal:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: symbios-myapp
  symbios_services:
    external: true
```

---

## Healthcheck scripts

Every service should deploy a healthcheck script to
`/usr/local/sbin/runchecks.d/symbios-healthcheck-<name>.check` (where `<name>`
is the playbook filename without `.yml`). The `runchecks.sh` daemon iterates
over all `*.check` files every 5 minutes. The name mapping matters: the WebUI
sidebar derives its health icon from the playbook basename.

### Web-facing services (HTTP)

For HTTP services include the shared task file `services/tasks/healthcheck.yml`
(same pattern as `tasks/oidc-groups.yml`; the path is relative to the
playbook's directory):

```yaml
    # Required vars in the playbook: service_name, service_domain
    # Optional var: healthcheck_url (default: https://{{ service_domain }})
    - name: Deploy healthcheck
      include_tasks: tasks/healthcheck.yml

    # Variant with a custom probe URL (e.g. openwebui on ai.<base_domain>):
    - name: Deploy healthcheck
      include_tasks: tasks/healthcheck.yml
      vars:
        healthcheck_url: "https://ai.{{ base_domain }}"
```

The shared task deploys this check (5-minute cooldown, HTTP `>= 500` = error):

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
          g_svc_url="{{ healthcheck_url | default('https://' ~ service_domain) }}"
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

Services without a web UI deploy an inline check with the same 5-minute
cooldown wrapper (see `rustdesk.yml`, `sftp-share.yml`, `openwrt-vm.yml`):

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
          g_check_file="${g_tmp}/symbios-healthcheck-{{ service_name }}"
          if [ -f "$g_check_file" ] && find "$g_check_file" -mmin -5 | grep -q "$g_check_file"
          then
            return 2>/dev/null || true
          fi
          date > "$g_check_file"
          if ! docker ps | grep -q "{{ service_name }}"
          then
            g_echo_error "Healthcheck failed for {{ service_name }}: container not running"
          fi
        backup: yes
        validate: /bin/bash -n %s
```

### Conventions

- File name: `symbios-healthcheck-<name>.check` (`<name>` must match the
  playbook filename without `.yml`, or the sidebar icon will not appear)
- Mode `0400` (checks are sourced by runchecks.sh as root, never executed)
- **Never call `exit` in a `.check` script** - runchecks.sh sources every
  check, so an `exit` kills the whole health daemon mid-loop
- Uses `g_echo_error` from gaboshlib for error reporting (logged to syslog)
- Uses `g_tmp` for 5-minute cooldown file to avoid redundant checks
- HTTP status `>= 500` or connection failure = error; `200`-`499` = healthy
- The `runchecks.sh` daemon picks up new/changed `.check` files automatically

---

## User-uploaded playbooks

Besides built-in playbooks, you can upload custom Ansible playbooks through the
WebUI. Uploaded playbooks are stored on the host at
`/symbios/base-services/symbios-ui/config/user-playbooks/` and appear in the Services
section under **Custom Playbooks**.

### How it works

- **Upload**: Select one or more `.yml` files above. Filenames are sanitized to `[a-z0-9_-]` and must end in `.yml`.
- **Discovery**: The catalog scanner reads the `user-playbooks/` directory. Playbooks without a `# docs:` block are ignored.
- **Execution**: Uploaded playbooks are run exactly like built-in ones.
- **Delete**: Remove them from the table above.

### Minimum format

```yaml
# docs:
#   short_description: My custom backup job
#   description: Runs a backup to an external NFS mount.
#   url: "https://mybackup.{{ base_domain }}"
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
`/symbios/base-services/symbios-ui/config/installed-playbooks.yml`. Each line contains a
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

- **Automatic registration** - every time the WebUI runs (Re)Install successfully,
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
cat /symbios/base-services/symbios-ui/log/reapply.log  # view reapply log
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
    --inventory /symbios/base-services/symbios-ui/config/inventory.yml \
    --limit localhost \
    -e ansible_python_interpreter=/usr/bin/python3 \
    /home/SymbiOS/services/<name>.yml
  ```
  Or manage the container directly with `docker compose` in `/symbios/services/<name>/`.

> **Secrets**: only runtime-generated placeholders (`!...!`) ever appear in a
> playbook. Real credentials live in `/symbios/services/<name>/env` and are never
> part of the repo or the `# docs:` block.
