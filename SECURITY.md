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
- Host key pinning via fingerprint verification (`ssh_exec.py`)
- Audit logging of all WebUI commands and direct CLI mutations (see below)
- The key is `0640 root:10000`, readable by root and the WebUI container
  (uid 10000)

The authorized_keys entry has no `from=` restriction and the gateway has no
source-IP check; any key holder can connect from any source allowed by the
firewall.

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

**Status**: Implemented for Authelia-forwarded admin logins and for the LAN
break-glass login, with one documented exception

The `AutheliaMiddleware` enforces a password change while the default "admin"
password still works:
1. Checks if an admin bind with password "admin" succeeds
2. If yes: sets the `force_password_change` session flag
3. Redirects all non-bypass requests to `/change-password/`
4. Clears the flag once the default password no longer binds or the password
   change succeeds

The LAN break-glass login at `http://<local-ip>:8080` authenticates against
LDAP and sets the same flag when the default password still works
(`webui/main/views.py:83-110`).

**Exception - host-local break-glass:** for trusted source addresses the
middleware grants an implicit local `admin` session without setting
`force_password_change` (`webui/main/middleware.py:145-149`). The WebUI is
reachable on `127.0.0.1:8080` without Traefik/Authelia by design, so the
forced-change guarantee does not apply to that path. For all other requests
the middleware check runs before any view.

### C4: LDAP Admin Password "admin"

**Status**: Accepted - mitigated by forced change

The `uid=admin` user gets password "admin" during initial setup. This is
acceptable because:
- A forwarded or LAN break-glass login forces a password change while the
  default password still works (C3)
- The LDAP bind DN (`cn=head-of-ldap`) uses a randomly generated password
- Login alone does not rotate the password: it stays valid until the admin
  actually changes it. Reapply does not reset it once `.admin_initialized`
  exists; the forwarded login only sets a session flag.

### T1: SSL Labs A+ Requires HSTS Preload List Membership

**Status**: Accepted with opt-in - A and A+ are both green in the TLS healthcheck

Qualys grades a configuration A+ only when HSTS is robust: at least one year
`max-age`, `includeSubDomains`, `preload`, and the domain is actually present in
the browser HSTS preload lists. SymbiOS sends the complete header through
Traefik, but the `preload` directive only signals intent; adding the domain to
the list is an external submission at `https://hstspreload.org/`. Until a domain
is preloaded, SSL Labs caps an otherwise clean SymbiOS host at A (strong
commercial security). The daily `ssl-labs` runcheck therefore accepts A and A+
as green and fails A- and below.

The DNS settings page offers a **HSTS preload** checkbox for `base_domain`.
Tick it only when every current and future subdomain can always use HTTPS: the
preload entry makes the whole domain HTTPS-only in browsers and is slow to
reverse. On save SymbiOS adds a `www.<base_domain>` HTTPS redirect, runs a local
and external preflight, and submits the domain only when the preflight passes.
The daily `hsts-preload` status job and healthcheck report `pending` until the
browser rollout finishes. Removal requires a deliberate manual step and can
take weeks or months; SymbiOS never automates it.

Check the current status with
`curl -sS 'https://hstspreload.org/api/v2/status?domain=<base-domain>'` or with
`symbios-hsts-preload.sh status`.

**Mitigations**: TLS 1.3, modern ciphers and a one-year HSTS header are already
enforced by SymbiOS; the remaining difference is first-load protection from the
browser preload list, not the TLS configuration of the host.

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
| 5.1.10 | SSH root login disabled | Partially applied | Management needs direct root access; `PermitRootLogin prohibit-password` allows keys only. | SSH listens on ports 22 and 33, ed25519 keys are required and fail2ban reports auth failures without banning. Password auth for other local accounts is not centrally disabled. |
| 6.1.1 | auditd enabled | Not applied | auditd adds little value for a single-admin appliance and would duplicate the existing audit trail. | All state-changing WebUI and CLI operations are recorded in `<data_root>/log/symbios-audit.log`; health checks and systemd logs cover host events. |
| 7.2.1 | Password aging for local accounts | Not applicable | Users are managed in LDAP through the WebUI; local accounts are maintenance-only. | The configurable password policy under Settings -> Security applies to LDAP users; the forced first-login change applies only to the initial admin while the default password works (see C3). |

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

## Audit Logging

All state-changing operations are appended to a single audit file on the
encrypted data partition: `<data_root>/log/symbios-audit.log` (mode 0600,
directory 0700, 30 daily rotations). Nothing is written to `/var/log`.

Covered sources:

- `source=gateway` - every command sent through `symbios-exec.sh` (the WebUI
  SSH gateway), with client IP and the shell-quoted command. Secret patterns
  are masked before writing. Read-only `symbios-run-detached.sh poll` calls
  are skipped so a long job cannot bury real changes under hundreds of lines.
- `source=cli` - direct host-side mutations that bypass the gateway:
  `symbios-inventory.py` and `symbios-config.py` writes, `symbios-state.sh`
  set/unset, LDAP group/user changes, `symbios-run-playbook.sh` and
  `symbios-reapply.sh`.

Events carry a UTC timestamp, source, uid, action and a short detail string.
Callers log key names and object names only, never values or secrets. Writing
an event is best effort: a failed write warns but never aborts the operation
that triggered it. The legacy `/var/log/symbios-exec.log` is left untouched as
historical data; it is no longer written.

`source=security` is used for authentication failure patterns. The detail
contains source, address, failure count and user name only - never a password,
token, cookie or raw log line.

---

## Auth Attack Reporting (report only)

fail2ban is used purely as a detector. `banaction = symbios-report` replaces
the Debian nftables default for **every** jail: the action only calls
`symbios-auth-report.sh`, creates no firewall rule, and `bantime = 1m` is a
report cooldown rather than a lockout. No address is blocked by SymbiOS,
including the host `sshd` jail on ports 22/33. Only loopback is ignored, so
brute force from the LAN is reported too.

The report-only jails use two actions: `symbios-report` for plain SSH failures
and `symbios-report-auth` for Authelia credential attacks. The latter passes
account, portal and authentication endpoint to the reporter, but never a
password, token, cookie or complete log line.

The reporter writes one `security/auth-failure` audit event and, unless called
with `--audit-only`, one notification per source and address per 15 minutes.
The auth healthchecks (`sftp-auth`, `auth-patterns`) use `--audit-only`: they
share the audit trail but keep their existing flap-protected notification, so
one event never produces two alerts.

Coverage is deliberately narrow and stated openly:

- host sshd (22/33): fail2ban jail on the systemd journal
- Authelia: report-only `authelia-auth` jail on the host-visible auth log for
  failed `1FA`/`TOTP` attempts and unknown-user probes. The log lives on the
  rootfs so the boot-enabled fail2ban can read it before `/symbios` is mounted
- SFTP (28): healthcheck on the container's authentication log
- Traefik: JSON access log, 401/403 bursts per client IP and distinct source
  IPs per `Remote-User`. This is a request pattern, not proof of a credential
  attack: the configured bypasses (Paperless `^/api/`, Forgejo `\.git(/|$)`)
  are counted separately and the mail names the busiest host, router, service,
  path and user agent
- other services: no usable authentication failure log source today; they are
  not silently claimed as covered

Successful logins are reported separately by the `auth-logins` check. It reads
new `successful = 1` rows from Authelia's local database and accepted logins
from the SSH journal, writes a `security/auth-success` audit event, and sends a
warning notification with user, source address and service context. A state
file under the log directory ensures each new login is reported once. This is
intentionally not a fail2ban jail: a successful login is not a failure and
Authelia only logs it at debug level, while the database already has the
authoritative record.

---

## Additional Security Notes

### LDAP Unencrypted (Port 389)
- LDAP only listens on `127.0.0.1:389` inside the Docker network. Traffic
  never leaves the host. TLS would add complexity without security benefit
  for this architecture.

### M2: Signed Cookies (not encrypted)
- Session data is stored in signed cookies (HMAC), not encrypted.
- Only the authorization flags `force_password_change` and `lan_admin` are
  stored; `is_staff` lives on the user object.
- No secrets or passwords in session data.

### M8: WebUI Port 0.0.0.0:8080
- Bound to all interfaces but restricted by UFW to private networks.
- Required for break-glass access via SSH tunnel.

### M9: SSH Port from All Sources
- SSH listens on ports 22 and 33; port 33 is open from all sources. UFW default
  deny limits exposure to the other ports.
- Root login is key-only (`PermitRootLogin prohibit-password`); SymbiOS does not
  centrally disable password auth for other local accounts.

### M11: No Docker Content Trust
- DCT adoption is limited in the home server ecosystem.
- No digest pinning or signature verification is configured; integrity relies
  on the registry and the administrator's choice of images.

### M12: Passwords in Environment Variables
- Same trust boundary as Docker socket access.
- Standard Docker mechanism for configuration.

### M14: State File chmod 644
- Contains only playbook names and timestamps (not sensitive).
- Required for cross-UID read access (root + WebUI container).

### M16: sshpass in WebUI Container
- No longer installed in the WebUI image. Initial SSH key deployment runs on
  the host via `symbios-remote-install-key.sh`, which uses `sshpass -e` with
  the password on stdin.
- Existing containers need an image rebuild before the removal takes effect.

### M18: Collabora SYS_ADMIN Capability
- Required by Collabora for document conversion sandbox.
- Contained within Docker network.

### M19: WebUI parameters in OpenWrt `raw` tasks

**Status**: Mitigated - central validation on save and run (2026-11-20)

The playbooks under `external-services/tasks/openwrt/` configure routers mostly
with Ansible's `raw` module (the targets are Python-less OpenWrt images). All
parameter values reach the router as shell text, so a value containing
`$(...)`, backticks or shell operators could execute commands as root on that
router; quotes could corrupt UCI configuration.

Mitigations now in place:

- `symbios-external-params-validate.sh` checks every string value at both
  entry points: when `symbios-external-params.sh set` persists values and again
  when `symbios-run-remote-playbook.sh` runs a playbook. Values containing
  CR/LF/NUL, backticks, `;`, `|`, `&`, `\`, `$(` or `${` are rejected with
  exit code 2. This also covers values loaded from saved host/playbook vars.
- The shared setter `external-services/tasks/openwrt/uci-set.yml` quotes every
  value with `| quote` and includes the reusable validation task
  `uci-validate.yml`; 15 simple setter files now use it.
- Quotes, spaces and non-ASCII text remain allowed because the UCI setters
  quote them. WebUI access is admin-only and the exec audit log records the
  target and playbook name.

Residual risk: the remaining `raw:` tasks outside the shared setter still
interpolate values directly; an allowed value with spaces or quotes can
corrupt a configuration line there (integrity, not command execution). A full
conversion to `ansible.builtin.command` argv lists is still pending and needs
router-side testing.

### M20: Passwords in client argv

**Status**: Mitigated - secret files / stdin across clients (2026-11-20)

Several clients used to receive their password as an argument, exposing it via
`/proc/<pid>/cmdline`. `no_log: true` only masked Ansible output.

Mitigations now in place:

- LDAP: `symbios-lib.sh` writes a transient 0600 password file
  (`f_write_secret_file`, shredded on exit via `f_cleanup_secret_files`) and all
  `ldap*` clients use `-y` or `-W` with stdin. No `ldap* -w` sites remain.
- Database clients: `MYSQL_PWD`, `--defaults-extra-file` with a 0600 file, or
  `PGPASSWORD` inside the container's own `sh -c` (never passed to `docker exec
  -e`). This covers backup, restore, Nextcloud, KodiDB, WordPress, Mastodon and
  Matrix helpers.
- `htpasswd` uses `-i` (stdin), `authelia crypto hash generate` uses `--random`
  instead of `--password`, and `openssl passwd` uses `-stdin`.
- Secrets are never passed as argv to settings scripts; `no_log` remains on
  playbook tasks that handle credentials.

Residual exceptions (documented, not fixed here):

- `mas-cli` (Matrix Authentication Service) has no stdin password option and
  its image is distroless; the break-glass registration in `services/matrix.yml`
  and the password-sync hook still pass `--password` as an argument. The calls
  are short-lived and root-only.
- `matrix-commander` in `base-services/matrix-client.yml` still receives
  `--password` at device login; the CLI offers no non-argv login password.
- `services/mailcow.yml` was not modified by this hardening pass and still uses
  `mysql -p${DBPASS}` in its initialization tasks.

### Central Secret Store (symbios-secret.sh)

**Status**: Introduced 2026-11-20. Migration of existing secrets is staged.

SymbiOS now has a generic encrypted secret store. `symbios-secret.sh` uses
`age` (X25519 + ChaCha20-Poly1305, authenticated encryption) with these paths:

- identity: `<data_root>/.keys/symbios-secret.age.key` (0600 root, outside the
  WebUI container mounts)
- recipient: `<data_root>/.keys/symbios-secret.age.pub`
- ciphertext: `<config_dir>/secrets/<name>.age` (0600, directory 0700)

Values are read from stdin and written to 0600 files; neither the value nor
the identity is ever passed in argv. Only secret **names** are written to the
audit log. `f_secret_get_to_file` in `symbios-lib.sh` gives callers a transient
file with automatic shred-on-exit.

What this mitigates:

- plaintext copies of secrets in hand-edited files, playbook logs and backups
  (only ciphertext is stored in the generic store),
- uncontrolled distribution of credentials across service directories,
- missing rotation and missing audit trail for secret access.

What it does **not** mitigate - residual risks:

- A process with root on the live host can read the identity and every secret.
  No software-only store on a single host can prevent this; the WebUI exec
  gateway is already root-equivalent (see C1).
- On hosts without LUKS on `/symbios` the identity itself is plaintext on
  disk. There is no TPM on the current hosts, so there is no sealed key.
- Generated `env` files remain plaintext because Docker Compose `env_file:`
  requires it (see M12). They are now derived artifacts, regenerated from the
  store, not the source of truth. `shred` on SSD/CoW filesystems is best-effort.
- Existing secrets in `inventory.yml`, service env files and rootfs paths are
  migrated gradually; until then both storage models coexist.
- The SFTP share's LDAP readuser bind password is store-backed as
  `sftp-share/ldap_bindpw`. `nslcd.conf` stays a root-only derived file because
  nslcd cannot read the age identity; reapply `services/sftp-share.yml` after
  rotating it.

Rotating a secret:

1. For credentials that an application owns (LDAP users, Matrix accounts,
   database roles), change the value in the application first. The store is a
   copy, not the authoritative credential database, so an unrelated `rotate`
   would make the store diverge from the service.
2. Store the new value via stdin (`read -rsp 'New value: ' f_value` and
   `printf '%s' "$f_value" | symbios-secret.sh put <name>`), or for a generated
   token use `symbios-secret.sh rotate <name>` and pass the printed 0600 file on
   to the service setup. Never pass a value as an argument or echo it to a log.
3. For env-bound services (Nextcloud, Matrix), reapply the service playbook.
   `shared-tasks/secret-env.yml` regenerates the env file from the store and
   notifies the compose restart handler, so running containers pick up the new
   value. Other consumers read the store at runtime and need no reapply.

There is no scheduled rotation; rotation is event-driven. The primitive is
`rotate --plan` (dry run), `rotate --apply` (store change plus propagation) and
`rollback` (one previous ciphertext). Metadata lives in
`<config_dir>/secrets/meta/` and records type, policy, consumers, last rotation
and rollback time, but never a value. A propagation hook under
`scripts/secret-rotation.d/` receives the new and old values as two transient
0600 files; if it exits non-zero, the previous ciphertext is restored
automatically. A failed hook therefore consumes the rollback copy because the
store is already back to the old value. Generated secrets may be rotated in the
store; application-owned credentials must be changed in the application first
and then written back with `put`. `delete` removes the ciphertext together with
its rollback copy and metadata so no unlisted credential is left behind.

The `secret-store` healthcheck validates identity and directory permissions,
resolves every `secret:` reference from `inventory.yml`, flags stale transient
plaintext files, and warns about known credential keys that are still stored in
plaintext. It reports names only, never values.

The WebUI page under Settings -> Security -> Secrets lists the same names and
metadata via `symbios-secrets-list.sh`. Its rotate, rollback and delete buttons
run the host scripts through the exec gateway and their output contains names
only. An explicit reveal button calls `symbios-secret.sh show --actor <user>`
synchronously and places the value in a masked dialog in the current browser
session; it is not stored in the page, a job or a log. The host audit records
`action=reveal secret=<name> actor=<user>` with a timestamp, so it is traceable
who revealed which credential, but the value itself is never logged. This is a
deliberate residual risk of on-demand display.

### L4: SSH StrictHostKeyChecking
- Test scripts use `StrictHostKeyChecking=no` for dev environments.
- Production automation uses `no` in several callers (for example WoL,
  Home Assistant and the external-systems test) and `accept-new` in others;
  pinned `known_hosts` are not used consistently.

### L8: Interactive Shell on Install Error
- Installer-only feature for debugging playbook failures.
- No security exposure after installation completes.

### L9: TOCTOU Race in PID File Locking
- Fixed: `symbios-reapply.sh` holds a non-blocking `flock` on
  `/run/symbios-reapply.pid.lock`; the PID file is informational only.
- Previously the worst case was duplicate playbook runs (operational, not
  security).

### L10: No set -euo pipefail
- Strict mode is used in a few scripts; most scripts rely on explicit error
  handling.
- The coding standards do not forbid strict mode.

---

## Configurable Security Features

### Password Policy

Configurable in the WebUI under Settings > Security. Stored in `inventory.yml`
as `password_policy`. Five levels:

| Level | Requirements |
|-------|-------------|
| none | Min 1 character |
| low | Min 8 characters |
| medium | Min 10 chars + letter + digit + special char |
| high | Min 16 chars + letter + digit + special char |
| paranoid | Min 32 chars + letter + digit + special char |

There is no mixed-case requirement and no common-pattern check.

Enforced at all password change points:
- Initial admin password change (forced while the default password works)
- User creation via WebUI
- Admin password reset via WebUI
- `symbios-ldap-user.sh` CLI script

### Traefik Host Access Control

Configurable in the WebUI under Settings -> Access, with a "Network access"
selector on supported service detail pages. Stored in `inventory.yml` as
`traefik_default_access` (`internet` by default) and `traefik_service_access`
(a service name -> `default|internal|internet` map; a missing entry or
`default` follows the global value).

| Mode | Effect on the host's HTTPS router |
|------|-----------------------------------|
| `internal` | Traefik adds the existing `allowlocalipsonly@file` middleware (RFC1918 private ranges 10.x, 172.16-31.x, 192.168.x, IPv6 ULA `fc00::/7`, IPv6 link-local `fe80::/10`, loopback `127.0.0.1/32` and `::1/128`) |
| `internet` | No network restriction middleware is added |

The firewall still opens ports 80/443 globally: exposure is decided per
hostname at layer 7, not by a firewall rule. Authelia stays independent -
`internal` restricts the source network, it does not remove the login
requirement. Routers that must stay local (for example Home Assistant Matter)
and routers that must stay reachable from the internet (Mastodon federation
and WebFinger, Matrix federation, ACME and TURN challenges, Authelia itself)
keep their deliberate exposure. Forwards from Settings -> Reverse Proxy follow
the global default as well; their own `open|local|authelia` choice remains a
separate decision about authentication.

`webui_public_access` from Settings -> Security is deprecated and no longer
shown there. It is honoured only as a fallback for the WebUI router, so
existing installations keep their current exposure until the Settings ->
Access page is used; fresh installations no longer carry the flag and the
WebUI follows the global default. The break-glass endpoint at localhost:8080
is unaffected by either setting.

### Reboot Policy

Kernel and libc fixes only become active after a reboot. A host that stays up
for weeks therefore keeps known-vulnerable code in memory even though its
packages are patched. SymbiOS can limit that exposure:

| Setting | Default | Meaning |
|---------|---------|---------|
| `reboot_max_days` | `0` | Uptime after which a pending reboot may be applied. `0` disables the policy. |
| `reboot_auto` | `false` | `true` schedules a reboot once the limit is reached; `false` only warns. |

Both keys are configurable under Settings > Security and are read at runtime
by the scripts, so no playbook reapply is needed.

The pending-reboot detection uses Debian's `/run/reboot-required` marker plus a
comparison of the running kernel with the installed `linux-image-*` packages,
because Debian trixie no longer writes the marker reliably after a kernel
update. Uptime alone never reboots a healthy host.

When `reboot_max_days` is greater than `0`:
- `reboot-uptime.check` warns as soon as a reboot is pending, even below the
  limit. The message states when the automatic reboot would happen. It shares
  the detector with `reboot-required.check`, which already reports the same
  condition as an error even when the policy is disabled.
- With `reboot_auto: true`, `autoupdate.d/reboot-threshold.update` schedules
  `shutdown -r +5` during the daily maintenance window (Settings > Maintenance,
  default 00:05), but only after the uptime reached `reboot_max_days` **and** a
  reboot is still pending. Backup always runs before updates in that window,
  and the shared maintenance lock prevents overlap with manual runs.
- The five minutes let the rest of the update run finish. An administrator
  can cancel with `shutdown -c`; a non-empty `/run/symbios-no-auto-reboot`
  suppresses the reboot for manual maintenance.

The separate `reboot-required.check` reports Debian's reboot marker and an
outdated running kernel as errors. It only reports; any reboot comes from the
opt-in policy above or from an explicit WebUI action.

**LUKS caveat**: on hosts whose data volume needs a passphrase after boot
(for example `symbios-dev`), an automatic reboot leaves the host offline
until someone unlocks it. Keep `reboot_auto: false` there. Hosts with an
unlock key in `rc.local` can use the automatic variant.

