# SymbiOS Features

User-facing platform features, as managed through the WebUI under
**Settings** (plus the main management areas at the end). Each entry names
the Settings page, the Ansible playbook(s) behind it, the `inventory.yml`
variables it manages, and the health check that monitors it.

Docker application services (Nextcloud, Home Assistant, Matrix, …) are
**not** listed here - they are auto-discovered from their `# docs:` header
and documented in the WebUI under **Services**.

Conventions used below: all host operations run through `symbios-exec.sh`
(the WebUI never touches host files directly); changing a setting always
re-applies the owning playbook (live output in the exec modal); secrets are
passed via stdin, never on the command line.

---

## Access & Identity

### DNS (`/settings/dns/`)
Public name of the server (e.g. `my-server.dedyn.io`), via deSEC DynDNS or a
self-managed domain. Prerequisite for Traefik routing and Let's Encrypt.
- Playbooks: `base-services/dedyn.yml` (deSEC mode only), then
  `base-services/traefik.yml` + `base-services/authelia.yml` (forced, `--force`)
- Vars: `dns_mode` (`desec`|`self-managed`), `ddns_apikey`, `ddns_host`,
  `ddns_ipv6`, `base_domain`, `dns_configured`

### Mailserver / SMTP (`/settings/mailserver/`)
Outgoing mail account used for 2FA mails and notifications. Includes
provider auto-discovery and a test-mail button.
- Playbook: `base-services/smtp.yml` (plus `authelia.yml` when 2FA mail changes)
- Vars: `smtp_server`, `smtp_port`, `smtp_tls`, `smtp_user`, `smtp_password`, `smtp_from`
- Healthcheck: `smtp`

### Notifications (`/settings/notifications/`)
Health-check alerts and system mails to `root`, delivered by mail and/or
into an E2EE-encrypted Matrix room. At least one channel must work.
- Playbooks: `base-services/notifications.yml`, `base-services/matrix-client.yml`
- Vars: `notify_mail_enabled`, `notify_mail_to`, `notify_level`,
  `notify_matrix_enabled`

### Matrix Account (`/settings/matrix/`)
Sender account (homeserver, user, room, password or token) used by the
matrix-client daemon for notifications.
- Playbook: `base-services/matrix-client.yml`
- Vars: `matrix_homeserver`, `matrix_user`, `matrix_password`, `matrix_token`, `matrix_room`

### Login & 2FA (`/settings/auth/`)
Authelia second factor enforcement for all web services. Can only be enabled
when an SMTP sender is configured (codes must reach the user).
- Playbook: `base-services/authelia.yml`
- Vars: `twofa_enabled`
- Healthcheck: `twofa`

### Security (`/settings/security/`)
Global password policy (`none`…`paranoid`) for admin/user passwords, plus the
WebUI public-access switch (Traefik re-apply only when the switch changes).
- Playbooks: none for the policy (enforced by the WebUI/LDAP tooling),
  `base-services/traefik.yml` for the public-access switch
- Vars: `password_policy`, `webui_public_access`

### Security Certificates / TLS (`/settings/acme/`)
Which ACME server issues the Let's Encrypt certificates Traefik serves and
auto-renews (production vs. staging).
- Playbook: `base-services/traefik.yml`
- Vars: `acme_server` (plus fixed resolver `acme_resolver: letsencrypt`)
- Healthcheck: `certs`

### SSH Keys (`/settings/ssh-keys/`)
`root` login keys (`/root/.ssh/authorized_keys`). The WebUI's own
exec-gateway key (`symbios-base-webui`) is always preserved and hidden.
- Playbook: `base-services/ssh-keys.yml`
- Script: `scripts/symbios-write-authorized-keys.sh` (stdin, atomic replace)

---

## Network

### Port Forwarding (`/settings/port-forwarding/`)
Opens ports 80/443 (optional: SSH 33) on the home router, automatically via
UPnP/TR-064 (FRITZ!Box incl. static-IP reservation) or with a manual guide.
IPv6 forwards are mirrored into UFW so a reapply re-opens them.
- Scripts: `scripts/symbios-router-upnp.sh` (+ `symbios-router-fritz.py`)
- Vars: `port_forwarding_method` (`auto`|`manual`), `port_forwarding_configured`,
  `port_forwarding_static_ip_configured`, `ufw_extra_inbound`, `router_upnp_user`,
  `router_upnp_password`

### WLAN Access Point (`/settings/wlan-accesspoint/`)
Wireless network via hostapd (WiFi only - no routing/DNS/DHCP). The config
lives on the encrypted volume, so hostapd is deliberately **not**
systemd-enabled; `rc.local` starts it after the mount.
- Playbook: `base-services/wlan-accesspoint.yml`
- Vars: `ap_interface`, `ap_name`, `ap_passphrase`, `ap_country`,
  `ap_enabled`, `ap_configured`
- Healthcheck: `symbios-healthcheck-wlan-ap.check`

### Network Bridges (`/settings/network-bridges/`)
Attaches unused physical interfaces to existing Linux bridges (e.g. `wlan0`
to `br-lan`). Applied immediately, persisted in `/etc/rc.local` across
reboots. Docker/SymbiOS bridges are hidden and cannot be picked.
- Playbook: `base-services/network-bridges.yml`
- Script: `scripts/symbios-bridge-assign.sh` (apply + rc.local block),
  `scripts/symbios-bridge-list.sh` (JSON for the WebUI)
- Vars: `bridge_assignments` (e.g. `{wlan0: br-lan}`)
- Healthcheck: `symbios-healthcheck-network-bridges.check`

### OpenVPN Client (`/settings/openvpn/`)
Client tunnels into remote networks (e.g. an IoT network behind another
router, used by Home Assistant for Shelly & co.). Multiple named tunnels;
per tunnel either **upload** a `.ovpn`/`.conf` once or **fetch** it on a
cron schedule from a command (e.g. `scp` from the router). Start/stop,
enable/disable, re-fetch, delete and a journal viewer per tunnel.
- Playbook: `base-services/openvpn-client.yml`
- Vars: `openvpn_clients` (`{<name>: {enabled, mode (upload|fetch),
  interface, fetch_cmd, cron, ufw_allow: [{port, proto}]}}`),
  `openvpn_configured`
- Scripts: `scripts/symbios-openvpn-client.sh` (`list|status|up|down|
  enable|disable|delete|fetch|log`),
  `scripts/symbios-write-openvpn-config.sh` (stdin upload)
- Healthcheck: `symbios-healthcheck-openvpn.check`
- Security model: tunnel configs hold private keys and live **only**
  encrypted on the data volume (`<base-services>/openvpn/`, 0700). They are
  bind-mounted into `/etc/openvpn` after the mount (no fstab entry, never
  any plaintext on the SD card) and the units have no systemd autostart -
  `rc.local` binds and starts the enabled tunnels after the LUKS unlock,
  so dependents (e.g. Home Assistant) always find the interface ready.

---

## Data & Storage

### Data Disk (`/settings/disk/`)
Moves `/symbios` from the SD card to a separate disk, optionally LUKS
encrypted, with rollback/change-password/unmount operations.
- Script: `scripts/symbios-data-partition.sh` (`list|setup|status|…`)
- Healthcheck: `disk`

### Media (`/settings/media/`)
Central media locations (`audio`, `images`, `videos`, `books`, `documents`,
`inbox`, `shared`) plus per-directory quotas. Services mount these instead
of inventing their own paths; missing directories are created on apply.
Details: `mediapaths.md`.
- Playbook: `base-services/media.yml`
- Vars: `media_root`, `media_audio`, `media_images`, `media_videos`,
  `media_books`, `media_documents`, `media_inbox`, `media_shared`,
  `media_gid` (fixed `31000`), `media_quota_*`

### Shares (`/settings/shares/`)
Group directories below the media root (`shared/<name>`, mode 2770, owning
LDAP group `shared-<name>` by default). Membership is managed under Users &
Groups; only empty shares can be deleted.
- Script: `scripts/symbios-media-share.sh` (+ `symbios-sftp-share-homes.sh`
  for `home/<uid>` landing dirs)
- Views: `webui/main/views_shares.py`

### Backup (`/settings/backup/`)
Nightly snapshots of all data - local only or additionally on your own
backup server over SSH (optionally encrypted), with per-service scopes,
excludes, snapshot browser, passphrase handling, restore planner and a
run-now button. Untested backups are none: restore is a first-class flow.
- Playbook: `base-services/backup.yml`
- Scripts: `scripts/symbios-backup.sh` + `backup.d/`,
  `scripts/symbios-backup-list.sh`, `scripts/symbios-restore.sh`
- Vars: `backup_server_host/port/user/path`, `backup_encryption`,
  `backup_exclude`
- Healthcheck: `backup`

---

## System

### Updates (`/settings/updates/`)
Nightly unattended upgrades (OS, apps, SymbiOS itself) plus manual runs at
any time (Debian/Docker/SymbiOS modules, up to 2 h exec-modal jobs).
- Playbook: `base-services/autoupdate.yml`
- Scripts: `scripts/autoupdate.sh` + `autoupdate.d/`

### Language & Timezone (`/settings/localization/`)
Timezone (from the host's `timedatectl` list), keyboard layout (from
`symbios-list-keyboards.sh`) and locale. Explicitly confirmed via the WebUI.
- Playbooks: `base-services/localization.yml`, `base-services/raspberry.yml`
- Vars: `timezone`, `keyboard`, `locale`, `localization_configured`

### AI (`/settings/ai/`)
Optional OpenAI-compatible endpoint (server URL + API key) consumed by the
`openwebui`/`opencode` service playbooks. Includes a `/models` connection
check that saves nothing.
- Vars: `ai_server`, `ai_apikey` (removed again when cleared)

### Config Editor (`/settings/config/`)
Raw `inventory.yml` editor with YAML validation, automatic `.bak` backup
and full reapply. Escape hatch for everything the forms do not cover.

### Custom Playbooks (`/settings/playbooks/`)
Upload your own Ansible playbooks (`services/<name>.yml` shape with a
`# docs:` header) - they appear in the Services catalog like built-ins.
Format reference: `webui/main/docs/playbooks.md`.

---

## Management areas (main navigation)

- **Users & Groups** (`/users/`, `/groups/`) - LDAP users (`inetOrgPerson` +
  `posixAccount`), SSH keys per user (`sshPublicKey`), group membership incl.
  `<service>-users`/`-admins` access groups and the protected `media` group.
- **Services** (`/services/`) - Docker app catalog from playbook `# docs:`
  headers, with install/start/stop/logs/health per service.
  Format reference: `webui/main/docs/services.md`.
- **Health** (`/health/`) - `runchecks.sh` results (5-minute loop over
  `runchecks.d/*.check`), per-minute dashboard history (7 days, crash/leak
  forensics), trend sparklines, per-check re-runs.
- **Logs** (`/logs/`) - live host + container log streaming.
- **File Manager** (`/filemanager/`) - browse the data volume from
  `file_manager_root` (`/symbios`), with user-defined scripts
  (`file_manager_scripts`).
- **External Systems** (`/external-systems/`) - managed remote hosts (e.g.
  for offsite jobs) with connection tests.
- **Initial Setup** (`/setup/`) - guided assistant: connection type,
  localization, DNS, port forwarding, first users. State derived from
  inventory + LDAP, never duplicated (see `setup_status.py`).
