# SymbiOS - Coding Standards & Architecture Overview

This document describes the architecture, coding standards, and conventions
for developers and AI assistants working on the SymbiOS codebase.

---

## Service Access Control Policy

Every service that provides web access MUST enforce group-based access control.
Only LDAP users who are members of the service's designated group(s) may log in
or access the service.

### Group naming convention

| Service type | Groups created | Example |
|-------------|----------------|---------|
| Service with admin/user distinction | `<service>-users` + `<service>-admins` | `nextcloud-users`, `nextcloud-admins` |
| Service without admin/user distinction | `<service>` | `dabo` |

### How groups are enforced

Groups are created via the shared task `services/tasks/oidc-groups.yml` which
calls `scripts/symbios-ldap-groups.sh`. This task:

1. Creates `<service>-users` LDAP group
2. Creates `<service>-admins` LDAP group
3. Adds the `admin` user to `<service>-admins`

**Enforcement depends on the auth method:**

| Auth method | Enforcement location | How |
|------------|---------------------|-----|
| OIDC via Authelia | Service app config | `OAUTH_ALLOWED_ROLES` (openwebui), role mapping (home-assistant), LDAP user filter (nextcloud) |
| Authelia forward-auth | Authelia access_control | Subject rule restricting to `<service>-users` / `<service>-admins` groups |
| Internal auth | N/A (service manages own users) | No LDAP groups needed |

### Mandatory checklist for new services

- [ ] Include `services/tasks/oidc-groups.yml` (for OIDC services)
- [ ] Create LDAP groups `<service>-users` and `<service>-admins` (or just `<service>`)
- [ ] Configure group restriction at the app or proxy level
- [ ] Verify that users NOT in the group cannot access the service

### Service group matrix

| Service | Groups | Enforcement |
|---------|--------|-------------|
| nextcloud | `nextcloud-users`, `nextcloud-admins` | Nextcloud LDAP user filter (`ldapUserFilterGroups`) |
| openwebui | `openwebui-users`, `openwebui-admins` | `OAUTH_ALLOWED_ROLES` env var |
| home-assistant | `home-assistant-users`, `home-assistant-admins` | HA `auth_oidc` role mapping |
| paperless | `paperless-users`, `paperless-admins` | Authelia access_control subject rule |
| matrix | `matrix-users`, `matrix-admins` | Synapse OIDC group restriction |
| opencode | `opencode-users`, `opencode-admins` | Authelia access_control subject rule |
| dabo | `dabo` | Authelia access_control subject rule |
| kodidb | `kodidb` | Authelia forward-auth access_control |
| openwrt-vm | `openwrt-vm` | Authelia forward-auth access_control |

---

## Architecture

### How it all fits together

```
Internet -> Traefik (reverse proxy, TLS, file-provider routing)
  -> Authelia (SSO/2FA/OIDC forward-auth)
  -> Services (Docker containers on symbios_services network)
  -> OpenLDAP (user directory, group membership)
```

Key: Traefik does NOT use the Docker provider. Routing is file-provider based.
Services join the `symbios_services` network and get a Traefik provider snippet.

### Execution model

All host commands are executed via `symbios-exec.sh` (SSH exec gateway).
The WebUI must never read host files directly through Docker volume mounts.
Instead, use `run_command()` to fetch data from the host.

### Variable model

Defined in `inventory.yml` under `all.vars`:

| Variable | Purpose |
|----------|---------|
| `base_domain` | Public domain for Host rules |
| `data_root` | Root of all SymbiOS data (LUKS overlay) |
| `git_root` | Repo location |
| `services_root` | User service stacks |

---

## Naming conventions

### Container names

| Scope | Prefix | Example |
|-------|--------|---------|
| Base services | `symbios-base-` | `symbios-base-traefik` |
| User services | `symbios-` | `symbios-nextcloud` |
| Sub-containers | `symbios-<service>-<role>` | `symbios-nextcloud-db` |

### Docker networks

| Network | Purpose |
|---------|---------|
| `symbios_base_services` | All base services |
| `symbios_services` | Traefik + user services |
| `symbios-<service>` | Internal network for multi-container stacks |

### LDAP groups

| Pattern | Example | Purpose |
|---------|---------|---------|
| `<service>-users` | `nextcloud-users` | Regular users allowed to use the service |
| `<service>-admins` | `nextcloud-admins` | Admin users with elevated privileges |
| `ldap-admins` | `ldap-admins` | WebUI admin access |
| `ldap-users` | `ldap-users` | Basic WebUI access |

---

## Code style

### Bash

- Use `[[` instead of `[`
- Indent by two spaces
- Use `g_echo` family instead of raw `echo`
- Source `gaboshlib.include` when available
- Function names: `f_functionname`
- Global variables: `g_varname`
- Local variables: `f_varname`
- Use `if ... <newline> then` not `if ... ; then`

### Ansible

- Use FQCN (`ansible.builtin.shell`, etc.)
- Use `no_log: true` for secrets
- Use `changed_when` / `failed_when` where appropriate
- Blockinfile markers: `# {mark} ANSIBLE MANAGED BLOCK <name>`

### Python (Django WebUI)

- Follow PEP 8
- Use `@csrf_exempt` as outermost decorator only
- All host operations via `run_command()` -> `symbios-exec.sh`

---

## Important patterns

### Playbook execution from WebUI

1. WebUI view calls `_start_reapply()` or `symbios-exec.sh`
2. `symbios-exec.sh` audit-logs and runs command via `exec bash -c`
3. For playbooks: `ansible-playbook --connection=local --limit localhost --inventory <path>`

### Domain changes

1. Update `inventory.yml` with new domain
2. Run `symbios-reapply.sh` or targeted playbook reapply

### Adding a new service

1. Create `services/<name>.yml` with `# docs:` header
2. Include `services/tasks/oidc-groups.yml` for OIDC services
3. Create Traefik provider snippet
4. Enforce group restriction at app or proxy level
5. Deploy a healthcheck: include `tasks/runcheck.yml` (HTTP services, vars
   `service_name` + `service_domain`, optional `healthcheck_url`) or deploy a
   custom `/symbios/runchecks.d/symbios-healthcheck-<name>.check`
   (`<name>` must match the playbook basename; never call `exit` inside a
   `.check` script - it is sourced by runchecks.sh and would kill the daemon;
   set the CHECK_* metadata vars so the check appears categorized on the
   /health/ page; see webui/main/docs/playbooks.md)
6. Verify after install: `symbios-healthcheck-<name>.check` appears in
   `/symbios/base-services/symbios-ui/log/runchecks-results.json`

---

## DNS Policy

NEVER use public DNS servers like 1.1.1.1 (Cloudflare), 8.8.8.8 (Google),
or 9.9.9.9 (Quad9). If a public DNS is required, use Digitalcourage:

- IPv4: `5.9.164.112`
- IPv6: `2a01:4f8:251:554::2`
- Port: 853 (TCP)
- TLS hostname: `dns3.digitalcourage.de`
- sha256 SPKI pinset: `2WFzfO2/56HpeR+v/l25NPf5dacfxLrudH5yZbWCfdo=`
- See https://digitalcourage.de/support/zensurfreier-dns-server

IMPORTANT: Digitalcourage DNS is DNS-over-TLS (port 853). It CANNOT be
used as a plain nameserver in /etc/resolv.conf. It requires a TLS-capable
DNS resolver (e.g. systemd-resolved with DNSOverTLS=yes, or unbound).

NEVER use public IPs like 1.1.1.1 for routing tests or network detection
either. Use Digitalcourage IPs (`5.9.164.112` / `2a01:4f8:251:554::2`)
instead.
