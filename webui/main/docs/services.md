# Services in SymbiOS

## What is a service?

A **service** in SymbiOS is a single Ansible playbook that deploys and manages a Docker
container on the host. Each service creates:

- A Docker Compose stack under `/symbios/services/<name>/`
- A Traefik provider snippet for HTTP routing (optional)
- Status checks, log streams, and lifecycle actions the WebUI can control

The WebUI discovers services automatically from the playbook's `# docs:` block
and presents them in the **Services** section with install/uninstall/start/stop
buttons, live logs, and health status.

## User portal

Every SymbiOS installation also serves a read-only launcher at
`https://portal.<base_domain>`. It is protected by Authelia forward-auth and
shows tiles for installed services only. A tile appears when:

- the playbook lives in `services/` and is listed in `installed-playbooks.yml`,
- its `# docs:` header has an HTTP(S) `url`, and
- the logged-in user is a member of `docs.access.user_group` or
  `docs.access.admin_group` (admins see all services; `docs.access.none`
  means the service is shown to every authenticated user).

Services with per-instance domains (for example Static Web or WordPress) have
no fixed `url` in their docs header and are not shown in v1. The page is
rendered on each request from the local service catalog and the group list that
Traefik forwards from Authelia, so it never needs a cron job or static file.

DNS must resolve `portal.<base_domain>` to the SymbiOS host (the wildcard CNAME
created for deSEC domains covers it). Traefik requests the certificate with the
usual HTTP-01 challenge.

---

## Built-in services vs. custom services

SymbiOS ships playbooks from these locations:

| Type | Location | Description |
|------|----------|-------------|
| **Base services** | `base-services/` | Core platform components (Traefik, Authelia, LDAP, Docker, etc.) |
| **Services** | `services/` | Additional applications you can deploy (Nextcloud, Home Assistant, etc.) |
| **External services** | `external-services/` | Playbooks for remote/external systems (e.g. OpenWrt, Linux). Managed under Settings > External Systems. Uses `docs.type` for grouping and runs via SSH. |
| **Custom playbooks** | User-uploaded | Your own playbooks, uploaded via the WebUI |

Base services are built-in and cannot be uninstalled. Services can be installed,
uninstalled, and managed individually.
