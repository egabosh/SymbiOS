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
