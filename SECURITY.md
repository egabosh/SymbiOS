# SymbiOS Security Documentation

## Accepted Risks (Design Decisions)

These are intentional design decisions that are documented and accepted.

### C1: SSH Exec Gateway - No Command Restriction

**Status**: Accepted risk - by design

The WebUI's SSH key (`/config/.ssh/id_symbios`) is a normal root key without
`command=` restriction. The exec gateway (`symbios-exec.sh`) runs arbitrary
commands via `bash -c`.

**Rationale**: The admin can upload arbitrary Playbooks that execute as root.
Restricting the exec gateway would provide a false sense of security while
making the system harder to use. The exec gateway is the mechanism by which
the WebUI manages the host.

**Mitigations**:
- Host key pinning via fingerprint verification (`ssh_exec.py:46-69`)
- Audit logging of all commands (`symbios-exec.sh:62-63`)
- SSH key is only accessible to the WebUI container (chmod 600)
- The exec gateway only accepts connections from the WebUI container

### H3: ALLOWED_HOSTS = ['*']

**Status**: Accepted - required for break-glass flow

The WebUI is accessible via multiple hostnames (localhost, Docker IP, public
domain). Restricting `ALLOWED_HOSTS` would break the break-glass flow on
`http://localhost:8080`.

### H13: Session Cookie Secure = False

**Status**: Accepted - break-glass requires HTTP

The break-glass endpoint on `http://localhost:8080` requires plain HTTP.
Setting `SESSION_COOKIE_SECURE=True` would break the recovery flow. The
session is signed (not encrypted), but this is acceptable for a single-admin
system.

### C3: Admin Password Forced Change

**Status**: Already implemented correctly

The `AutheliaMiddleware` enforces password change on first login:
1. Checks if admin bind with password "admin" succeeds
2. If yes: sets `force_password_change` session flag
3. Redirects all non-bypass requests to `/change-password/`
4. Only clears flag after successful LDAP bind with new password

**Cannot be bypassed** - the check runs in middleware before any view.

### C4: LDAP Admin Password "admin"

**Status**: Accepted - mitigated by forced change

The `uid=admin` user gets password "admin" during initial setup. This is
acceptable because:
- The password is forced to change on first login (C3)
- The LDAP bind DN (`cn=head-of-ldap`) uses a randomly generated password
- The init password is only valid until first successful login

---

## CIS Benchmark Scope and Deviations

SymbiOS audits a curated subset of **CIS Debian Linux 13 Benchmark v1.1.0,
Level 1 Server** with the read-only script `symbios-cis-audit.sh`. The daily
result is cached as `<log>/cis-audit.json` and shown as one card on the Health
page. The audit does not change host configuration and is not a compliance
certificate.

Controls that SymbiOS deliberately does not implement are listed below. Every
waiver in `scripts/runchecks.d/cis-audit.conf` must have a row with the same CIS
ID here; the audit reports undocumented waivers so no deviation is accepted
silently. Findings that are not in this table are shown as warnings and must be
either fixed in the owning playbook or added here with a rationale.

| CIS ID | Control | SymbiOS decision | Rationale | Compensating control |
|--------|---------|------------------|-----------|----------------------|
| 3.2.1 | IP forwarding disabled | Not applied | Docker requires `net.ipv4.ip_forward=1` for bridge and NAT networking. | Containers run on an isolated bridge network; UFW default deny limits exposure. |
| 5.1.10 | SSH root login disabled | Partially applied | Management needs direct root access; `PermitRootLogin prohibit-password` allows keys only. | `PasswordAuthentication` is disabled, ed25519 keys are required, fail2ban is active and SSH listens on non-standard ports. |
| 6.1.1 | auditd enabled | Not applied | auditd adds little value for a single-admin appliance and would duplicate the existing audit trail. | All state-changing WebUI and CLI operations are recorded in `<data_root>/log/symbios-audit.log`; health checks and systemd logs cover host events. |
| 7.2.1 | Password aging for local accounts | Not applicable | Users are managed in LDAP through the WebUI; local accounts are maintenance-only. | The configurable password policy under Settings -> Security and forced first-login password change apply to all LDAP users. |

---

## Security Model

SymbiOS is a single-server management platform designed for hobby sysadmins.
The security model reflects this use case: a single admin operator manages one
Debian server from a WebUI.

### Design Principles

1. **Admin Model**: Members of the `ldap-admins` group (including `admin`)
   have full WebUI access via Authelia SSO. The `ldap-users` group exists for
   service-level access (e.g. Nextcloud, Matrix) but NOT for server management.
   The host-local break-glass on 127.0.0.1:8080 stays admin-only.

2. **SSH Exec Gateway**: The WebUI sends commands to the host via SSH
   (`symbios-exec.sh`). The SSH key has no `command=` restriction - this is
   intentional and documented. The exec gateway runs all commands as root.

3. **Break-Glass Access**: `http://localhost:8080` provides passwordless admin
   access for recovery when Authelia/Traefik is misconfigured. This is only
   reachable from the host itself or via SSH tunnel.

4. **Authelia SSO**: Remote access goes through Traefik + Authelia. Only users
   who pass forward-auth are accepted. The `Remote-User` header is only
   honored from the Traefik proxy IP.

5. **User portal**: `portal.<base_domain>` serves a read-only service launcher
   on the same WebUI container. It uses the forwarded `Remote-Groups` header,
   but only from the Traefik proxy IP, to filter tiles by LDAP group. The
   portal answers on `/` only; the management UI stays on the apex domain and
   remains staff-only.

---

## Additional Security Notes

### LDAP Unencrypted (Port 389)
- LDAP only listens on `127.0.0.1:389` inside the Docker network. Traffic
  never leaves the host. TLS would add complexity without security benefit
  for this architecture.

### M2: Signed Cookies (not encrypted)
- Session data is stored in signed cookies (HMAC), not encrypted.
- Only authorization flags (is_staff, force_password_change) are stored.
- No secrets or passwords in session data.

### M8: WebUI Port 0.0.0.0:8080
- Bound to all interfaces but restricted by UFW to private networks.
- Required for break-glass access via SSH tunnel.

### M9: SSH Port from All Sources
- Non-standard SSH port (33). Key-based auth enforced.
- UFW default deny policy limits exposure.

### M11: No Docker Content Trust
- DCT adoption limited in home server ecosystem.
- Registry-level verification provides sufficient integrity.

### M12: Passwords in Environment Variables
- Same trust boundary as Docker socket access.
- Standard Docker mechanism for configuration.

### M14: State File chmod 644
- Contains only playbook names and timestamps (not sensitive).
- Required for cross-UID read access (root + WebUI container).

### M16: sshpass in WebUI Container
- Only used for initial SSH key deployment.
- Removed from PATH after setup completes.

### M18: Collabora SYS_ADMIN Capability
- Required by Collabora for document conversion sandbox.
- Contained within Docker network.

### L4: SSH StrictHostKeyChecking
- Test scripts use StrictHostKeyChecking=no for dev environments.
- Production SSH uses key-based auth with known hosts.

### L8: Interactive Shell on Install Error
- Installer-only feature for debugging playbook failures.
- No security exposure after installation completes.

### L9: TOCTOU Race in PID File Locking
- Extremely narrow race window (microseconds).
- Worst case: duplicate playbook runs (operational, not security).

### L10: No set -euo pipefail
- Explicit error handling throughout scripts.
- Deliberate architectural choice per coding standards.

---

## Configurable Security Features

### Password Policy

Configurable in the WebUI under Settings > Security. Stored in `inventory.yml`
as `password_policy`. Five levels:

| Level | Requirements |
|-------|-------------|
| none | No requirements |
| low | Min 8 characters |
| medium | Min 8 chars + letters + digits |
| high | Min 12 chars + mixed case + digits + special chars |
| paranoid | Min 16 chars + mixed case + digits + special + no common patterns |

Enforced at all password change points:
- Initial admin password change (forced on first login)
- User creation via WebUI
- Admin password reset via WebUI
- `symbios-ldap-user.sh` CLI script

### WebUI Internet Access Control

Configurable in the WebUI under Settings > Security (Network Access toggle).
Stored in `inventory.yml` as `webui_public_access` (default: `false`).

When `false` (default):
- Traefik applies `allowlocalipsonly@file` middleware to the WebUI router
- Only RFC1918 private IP ranges (10.x, 172.16-31.x, 192.168.x) and
  localhost can reach the WebUI via Traefik
- The break-glass endpoint at localhost:8080 is unaffected

When `true`:
- WebUI is reachable from the public internet (still requires Authelia auth)

