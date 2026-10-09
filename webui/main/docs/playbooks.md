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
#       - /symbios/ldap-groups.d/nextcloud-admin-sync.hook
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
  - **`commands`** - optional list of whitelisted cleanup commands, executed in "full" mode only (e.g. `ufw delete allow ...`, `systemctl disable --now ...`, `userdel ...`). Allowed prefixes: `docker compose`, `systemctl`, `ufw`, `userdel`, `groupdel`, `smbpasswd`, `deluser`, `delgroup`, `virsh`, plus bare `symbios-*.sh` repo scripts (no path, reviewed + idempotent - use these instead of inline `rm`/`ip`). A failing command is logged but does not abort the uninstall.
  - **`ldap_groups`** - optional list of LDAP groups deleted via `symbios-ldap-groups.sh --delete` in "full" mode, even if they still have members. Defaults to the groups named in `docs.access` (`admin_group`/`user_group`). A failing deletion is logged but does not abort the uninstall.
  - **`authelia_blocks`** - optional list of Ansible managed block marker suffixes (e.g. `"OIDC nextcloud"`, `"dabo ACCESS CONTROL"`) removed from the Authelia configuration (`authelia-data/configuration.yml`) in "full" mode. The result is validated as YAML before it is accepted (a backup is kept next to the file); Authelia is restarted afterwards when something changed. If validation fails the uninstall is aborted before anything else gets deleted.
  - **`service_dir`** - optional explicit service dir path. Must live below the services root. Only needed if it cannot be derived from the playbook name.
  - **`program_paths`** - list of files/dirs installed OUTSIDE the service dir (Traefik provider snippet, healthcheck script, autoupdate module, systemd units, scripts). Deleted recursively in "full" and "program" mode.
  - **`userdata_paths`** - legacy: extra data dirs outside the service dir. Deleted recursively in "full" and "reset" mode. Normally not needed anymore since everything below the service dir counts as userdata.

  Mode behaviour:

  | | Uninstall (full) | Uninstall (keep data) | Delete Userdata (reset) |
  |---|---|---|---|
  | stop command | yes (+`--rmi all`) | yes (+`--rmi all`) | yes |
  | `commands` cleanup | yes | no | no |
  | `ldap_groups` | deleted | no | no |
  | `authelia_blocks` | removed + Authelia restart | no | no |
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

## Playbook conventions

Layout, sharing and syntax rules for every playbook in `services/` and
`base-services/` (mirrors the Ansible section of `AGENTS.md`):

- **Layout**: one play per file, `# docs:` header, `hosts: all`,
  `vars: service_name/service_domain`. Tasks in standard order:
  Guard -> Packages -> Directories -> Config -> LDAP -> Authelia -> Traefik
  -> Compose -> Healthcheck -> Autoupdate -> State. No service-local
  `tasks/` splits; complex services may use `<name>/templates/*.j2` and
  `<name>/features/*`.
- **Sharing**: only via top-level `shared-tasks/*.yml` with relative
  `include_tasks: ../shared-tasks/<file>.yml` (from both `services/` and
  `base-services/`). New shared tasks only with 3+ callers. Catalog below
  in [Shared tasks](#shared-tasks).
- **Shell**: `>10 lines shell => scripts/symbios-<service>-*.sh` (with
  `-h/--help`, `bash -n` clean). Every `shell/command` needs
  `changed_when`/`failed_when` (plus `creates:`/`removes:` where possible).
  Secrets never travel as argv (stdin JSON or env + `no_log: true`).
- **File modules**: default `blockinfile` (marker
  `# {mark} ANSIBLE MANAGED BLOCK <name>`); `copy` only for 1:1 static
  files; `template` + `.j2` only where loops/multi-line conditions are
  unavoidable. No multi-line `{% for/if %}` inside `block:`/`content:`
  (indent drift) - use single-line `{{ ... if ... else ... }}` or a
  `set_fact` above the task.
- **Traefik routing**: `shared-tasks/traefik-provider.yml` for the standard
  single-router case; inline `blockinfile` only for multi-router/special
  setups. The reverse-proxy WebUI (`symbios-traefik-proxy-apply.sh`) is
  independent of this task.
- **Healthcheck + state**: every service deploys `runcheck.yml` (HTTP) or
  `runcheck-docker.yml` and ends with `state-register.yml` via include.
- **Comments**: WHY not WHAT. Temporary migrations carry
  `# REMOVE-AFTER: YYYY-MM`; no history essays (belong in commit messages).
- **Check before commit**: `ansible-playbook --syntax-check`,
  `ansible-playbook --check` on symbios-dev,
  `runchecks-results.json` green. `validate:` + `backup: yes` on config writes.

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
`/symbios/runchecks.d/symbios-healthcheck-<name>.check` (where `<name>`
is the playbook filename without `.yml`). The `runchecks.sh` daemon iterates
over all `*.check` files every 5 minutes. The name mapping matters: the WebUI
sidebar derives its health icon from the playbook basename.

### Web-facing services (HTTP)

For HTTP services include the shared task file `shared-tasks/runcheck.yml`
(same pattern as `oidc-groups.yml`; the path is relative to the
playbook's directory):

```yaml
    # Required vars in the playbook: service_name, service_domain
    # Optional var: healthcheck_url (default: https://{{ service_domain }})
    - name: Deploy runcheck
      include_tasks: ../shared-tasks/runcheck.yml

    # Variant with a custom probe URL (e.g. openwebui on ai.<base_domain>):
    - name: Deploy runcheck
      include_tasks: ../shared-tasks/runcheck.yml
      vars:
        healthcheck_url: "https://ai.{{ base_domain }}"
```

The shared task deploys this check (5-minute cooldown, HTTP `>= 500` = error).
The CHECK_* variables feed the /health/ overview page:

```yaml
    - name: "{{ data_root }}/runchecks.d/symbios-healthcheck-{{ service_name }}.check"
      ansible.builtin.blockinfile:
        path: "{{ data_root }}/runchecks.d/symbios-healthcheck-{{ service_name }}.check"
        mode: "0400"
        owner: root
        group: root
        create: yes
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          CHECK_CATEGORY="services"
          CHECK_TITLE="{{ service_name }}"
          CHECK_DESC="Healthcheck for the {{ service_name }} service."
          CHECK_DETAIL="Probes https://{{ service_domain }} every 5 minutes.|HTTP status >= 500 or connection failure marks the check as failed."
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

## Shared tasks

Service playbooks can reuse shared task files from `shared-tasks/` via
`include_tasks`. This avoids duplicating common patterns (LDAP groups,
Authelia config, healthchecks) across 13+ playbooks.

> **No Jinja control flow inside `blockinfile`.** `{% for %}` / `{% if %}`
> lines inside a `block:` scalar render with drifted indentation (verified
> Oct 2026: loop body gained extra indent, compose refused to parse).
> Single-line `{% if x %}...{% endif %}` is safe; multi-line loops belong
> in real `.j2` template files rendered with the `template` module
> (precedent: `wordpress/templates/`, `sftp-share/templates/`).

### `shared-tasks/oidc-groups.yml` - dual-group LDAP setup

Creates `<service>-users` and `<service>-admins` LDAP groups and adds
the `admin` user to the admins group. Use for services with OIDC admin/user
distinction.

```yaml
    # Required vars: service_name, git_root
    - name: Create OIDC groups
      include_tasks: ../shared-tasks/oidc-groups.yml
```

### `shared-tasks/ldap-single-group.yml` - single-group LDAP setup

Creates a single LDAP group (e.g. `dabo`) and adds the admin user. Use for
forward-auth services without OIDC admin/user distinction.

```yaml
    # Required vars: service_name, git_root
    # Optional vars: ldap_admin_uid (default: admin)
    - name: Create LDAP group
      include_tasks: ../shared-tasks/ldap-single-group.yml
```

### `shared-tasks/authelia-acl.yml` - Authelia access control

Writes an Authelia `access_control` block for a service domain. Supports
single-group (forward-auth) and dual-group (OIDC) subject patterns.

```yaml
    # Required vars: service_name, service_domain, authelia_subjects
    # Optional vars: authelia_policy (default: two_factor), authelia_deny_fallback (default: true)

    # Single-group forward-auth (dabo, kodidb):
    - name: Write Authelia access_control
      include_tasks: ../shared-tasks/authelia-acl.yml
      vars:
        authelia_subjects:
          - "group:dabo"

    # Dual-group OIDC (home-assistant):
    - name: Write Authelia access_control
      include_tasks: ../shared-tasks/authelia-acl.yml
      vars:
        authelia_policy: one_factor
        authelia_subjects:
          - - "group:home-assistant-users"
          - - "group:home-assistant-admins"
```

### `shared-tasks/authelia-oidc.yml` - Authelia OIDC client config

Writes an OIDC client configuration block in Authelia's `configuration.yml`.

```yaml
    # Required vars: service_name, service_domain
    # Optional vars: oidc_client_name, oidc_redirect_uris (list), oidc_consent_mode,
    #                oidc_require_pkce, oidc_pkce_challenge_method, oidc_scopes (list)

    - name: Write OIDC config
      include_tasks: ../shared-tasks/authelia-oidc.yml
      vars:
        oidc_client_name: "Nextcloud"
        oidc_consent_mode: "implicit"
        oidc_redirect_uris:
          - "https://nextcloud.{{ base_domain }}/apps/user_oidc/code"
```

### `shared-tasks/runcheck.yml` - HTTP healthcheck probe

Deploys a wget-based healthcheck for HTTP services (documented in detail in
the [Healthcheck scripts](#healthcheck-scripts) section above).

### `shared-tasks/runcheck-docker.yml` - Docker container healthcheck

Deploys a `docker ps` based healthcheck for non-HTTP services (TCP/UDP
relays, SSH tunnels, etc.).

```yaml
    # Required vars: service_name
    # Optional vars: check_command, check_desc, check_error
    # (check_error overrides the default "container not running" message -
    # needed for one-shot jobs that are never running idle)
    - name: Deploy healthcheck
      include_tasks: ../shared-tasks/runcheck-docker.yml
```

### `shared-tasks/autoupdate.yml` - autoupdate script deployment

Deploys an autoupdate module to `/symbios/autoupdate.d/`. The caller provides
the full script content via `autoupdate_content`.

```yaml
    # Required vars: service_name, autoupdate_content (full script text)
    # Optional vars: autoupdate_name (default: service_name), autoupdate_mode (default: "0400")
    - name: Deploy autoupdate module
      include_tasks: ../shared-tasks/autoupdate.yml
      vars:
        autoupdate_content: |
          #!/bin/bash
          source /etc/bash/gaboshlib.include
          source symbios-lib.sh
          # ... update logic ...
```

### `shared-tasks/docker-start.yml` - start Docker Compose stack

Starts the service's Docker Compose stack.

```yaml
    # Required vars: service_name
    # Optional vars: docker_compose_args (extra args, e.g. --force-recreate)
    - name: Ensure service is running
      include_tasks: ../shared-tasks/docker-start.yml
```

### `shared-tasks/state-register.yml` - register playbook in state file

Registers the playbook as installed via `symbios-state.sh set`.

```yaml
    # Required vars: service_name
    # Optional vars: state_playbook (default: services/<name>.yml;
    #   base playbooks pass state_playbook: "base-services/<name>.yml")
    - name: Register playbook as installed
      include_tasks: ../shared-tasks/state-register.yml
```

### `shared-tasks/traefik-provider.yml` - single-router Traefik snippet

Deploys a standard single-router file-provider snippet (HTTPS + ACME).
Multi-router/special setups (matrix, nextcloud, mailcow, home-assistant)
still write `blockinfile` directly in the playbook.

```yaml
    # Required vars: service_name, service_domain, traefik_backend_url
    # Optional vars: traefik_middlewares (default: ["secHeaders@file", "authelia@file"])
    - name: Traefik provider snippet for dabo
      include_tasks: ../shared-tasks/traefik-provider.yml
      vars:
        service_domain: "{{ service_domain }}"
        traefik_backend_url: "http://symbios-dabo-django:80"
```

### `shared-tasks/base-domain-guard.yml` - fail without base_domain

Fail early when no public domain is configured. No vars required.

```yaml
    - name: Fail if base_domain is not configured
      include_tasks: ../shared-tasks/base-domain-guard.yml
```

### `shared-tasks/genpw-run.yml` - run genpw.sh once

Executes the service `genpw.sh` idempotently (via `creates:`).
The playbook owns the `genpw.sh` content; this task only runs it.

```yaml
    # Required vars: service_name
    # Optional vars: genpw_creates (default: /symbios/services/<name>/env)
    - name: Gen initial passwords if not exists
      include_tasks: ../shared-tasks/genpw-run.yml
      vars:
        service_name: paperless
```

### `shared-tasks/authelia-restart.yml` - restart Authelia

Restarts Authelia after `access_control`/OIDC changes. Usable as a
regular task and from `handlers:` via `include_tasks`. No vars required.

```yaml
    - name: Restart authelia
      include_tasks: ../shared-tasks/authelia-restart.yml
```

### `shared-tasks/ufw-allow.yml` - open a UFW port

Opens a single UFW port. Replaces ~20 inline `community.general.ufw`
blocks (mailcow, turn, rustdesk, ...). Interface- or policy-only rules
(traefik interface ingress, firewall deny policy) stay inline.

```yaml
    # Required vars: ufw_port (ranges like '21115:21119' work)
    # Optional vars: ufw_proto (default: tcp), ufw_rule, ufw_direction,
    #   ufw_interface (default: omit = global), ufw_src (loop for CIDRs)
    - name: Allow port 3478/tcp (STUN/TURN)
      include_tasks: ../shared-tasks/ufw-allow.yml
      vars:
        ufw_port: '3478'
```

### `shared-tasks/compose-recreate.yml` - recreate compose stack

Recreates a service compose stack (`up -d --force-recreate` in
`/symbios/services/<name>`). Replaces ~15 identical restart handlers.
Specials (opencode build-first, wordpress `--remove-orphans` via
`compose_args`, unbound `docker restart`, systemd units) stay inline.

```yaml
    # Required vars: service_name (inherited from the play, no vars needed)
    # Optional vars: compose_args (default: up -d --force-recreate)
    - name: Restart dabo
      include_tasks: ../shared-tasks/compose-recreate.yml
```

---

## LDAP group-change hooks

When a service needs to react to LDAP group or membership changes (e.g. syncing
Nextcloud admin rights when users are added to/removed from `nextcloud-admins`),
drop a `*.hook` file into `/symbios/ldap-groups.d/`. The shared dispatcher
`f_ldap_groups_hooks` in `scripts/symbios-lib.sh` runs all hooks from that
directory after every successful mutation in `symbios-ldap-groups.sh` (CLI and
WebUI group management pages).

Each hook receives three positional arguments:

| Arg | Content |
|-----|---------|
| `$1` | Event: `group-created`, `group-deleted`, `member-added`, or `member-removed` |
| `$2` | Group name (e.g. `nextcloud-admins`) |
| `$3` | User ID (empty string for group create/delete events) |

Hook errors are logged but never abort the calling mutation or other hooks.

### Deploying a hook from a service playbook

```yaml
    - name: "{{ data_root }}/ldap-groups.d/{{ service_name }}-admin-sync.hook"
      ansible.builtin.copy:
        dest: "{{ data_root }}/ldap-groups.d/{{ service_name }}-admin-sync.hook"
        content: |
          #!/bin/bash
          # React only to changes of our own group
          [[ "${2:-}" == "{{ service_name }}-admins" ]] || exit 0
          exec "{{ git_root }}/scripts/{{ service_name }}-admin-sync.sh"
        mode: '0755'
        owner: root
        group: root
```

The `program_paths` section in the docs block should include the hook file so it
is removed on uninstall:

```yaml
#     program_paths:
#       - /symbios/ldap-groups.d/nextcloud-admin-sync.hook
```

The directory `/symbios/ldap-groups.d/` is created by `base-services/ldap.yml`.

### Non-web services (Docker containers)

Services without a web UI deploy a `docker ps` based healthcheck. Use the
shared task `tasks/runcheck-docker.yml`:

```yaml
    - name: Deploy healthcheck
      include_tasks: ../shared-tasks/runcheck-docker.yml
```

For custom check commands (e.g. `openwrt-vm` with virsh), write the check
inline with the same 5-minute cooldown wrapper and CHECK_* metadata:

```yaml
    - name: "{{ data_root }}/runchecks.d/symbios-healthcheck-{{ service_name }}.check"
      ansible.builtin.blockinfile:
        path: "{{ data_root }}/runchecks.d/symbios-healthcheck-{{ service_name }}.check"
        mode: "0400"
        owner: root
        group: root
        create: yes
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          CHECK_CATEGORY="services"
          CHECK_TITLE="{{ service_name }}"
          CHECK_DESC="Healthcheck for the {{ service_name }} service."
          CHECK_DETAIL="Verifies that the container is listed in docker ps."
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
- Set `CHECK_CATEGORY`, `CHECK_TITLE`, `CHECK_DESC` and `CHECK_DETAIL` so the
  check shows up categorized on the /health/ page (see `load.check`)
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
#   description: Runs a backup to an external mount.
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

Use the shared task `tasks/state-register.yml` to register a playbook at the
end of its task list (requires `service_name` and `git_root` vars):

```yaml
    - name: Register playbook as installed
      include_tasks: ../shared-tasks/state-register.yml
```

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

---

## Feature plugin system

Complex services can expose configurable features through the WebUI. A feature
is an Ansible playbook that can be toggled on/off and configured with parameters
via the service's Features tab.

### Structure

```
services/<name>/
  plugin.yml              # Feature manifest (groups, features, params, param_mapping)
  features-state.yml      # Current state (auto-generated by WebUI, writable)
  features/               # Feature playbooks + detect scripts
    dhcp-hosts.yml
    detect-wifi.sh        # example detect script (if any feature uses one)
    dns_a.yml
```

### plugin.yml format

```yaml
groups:
  - id: network
    name: Network
    icon: bi-ethernet
features:
  - id: wireless
    name: WiFi AP
    icon: bi-wifi
    description: Enable WiFi access point
    group: network
    target: vm                    # vm = SSH into target, host = runs locally
    playbook: wireless.yml        # Relative to features/
    params:
      - name: ssid
        label: SSID
        type: text
        required: true
      - name: radio
        label: Radio
        type: select
        detect: detect-radios.sh  # Populates dropdown dynamically
    param_mapping:
      ssid: wifi_ssid             # WebUI param -> Ansible extra-var
      radio: wifi_radio
```

### Param types

- `text` - Simple text input
- `password` - Masked input
- `number` - Numeric input
- `select` - Dropdown (populated by detect script)
- `multi-select` - Multi-select dropdown

### Detect scripts

Must output JSON array: `[{"value": "...", "label": "..."}, ...]`
Run via `symbios-feature-detect.sh <service> <feature> <param>`.

### Exec overlay

Feature apply follows the WebUI standard exec overlay pattern:
- Overlay stays open after job completes
- Page reloads when user closes the overlay (handled by `exec-modal.js`)
- Feature views must NOT implement custom poll/reload logic

### Path resolution

- `plugin.yml` + `features/` live in the **git repo** (read-only source)
- `features-state.yml` lives in the **config dir** (writable)
- Feature playbooks run via `symbios-feature-apply.sh` which resolves paths from
  `g_git_root` (playbooks) and `g_config_dir` (state)

### Currently implemented

- **openwrt-vm**: 8 features in 3 groups (network, wifi, dns) - VM-side network
  features (iot, wireguard, dnscrypt, ssh, logserver, smtp) are now baked into
  the `openwrt-vm.yml` build-time preconfig and no longer exposed as features.
