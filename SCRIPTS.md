# SymbiOS Scripts Handbook (SCRIPTS.md)

User and admin reference for everything in `scripts/`. These scripts are the
executable layer of SymbiOS: the WebUI calls them on the host via
`run_command()` -> `symbios-exec.sh`, and admins call them directly over SSH.
If a task can be done in the WebUI, the same script behind the button does it
on the CLI - same validation, same result.

> **Spelling**: the project name is always written `SymbiOS`.
> File contents, names and docs follow the English-only rule from AGENTS.md.

---

## 1. Running scripts

Scripts run **on the SymbiOS host**, never in the dev container (host paths
like `/symbios` do not exist there):

```bash
ssh -p44 root@symbios-dev.dedyn.io "symbios-settings-localization.sh get"
```

How name resolution works:

- On the host, `scripts/` is on `PATH` via `/etc/profile.d/symbios-path.sh`
  (login shells) **and** via `symbios-exec.sh`, which prepends its own
  directory to `PATH` for every WebUI-invoked command (SSH
  non-interactive shells do not read `/etc/profile.d`). So bare names work
  both interactively and from the WebUI.
- Scripts that call sibling scripts MUST NOT rely on `PATH` alone; the
  established pattern is the own-directory prefix (gaboshlib may sanitize
  `PATH`):
  ```bash
  g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
  "$g_symbios_dir/symbios-inventory.py" --inventory "${g_inventory}" merge
  ```

Deploying script changes to the test host (from the dev checkout):

```bash
rsync -e "ssh -p44" scripts/<file> root@symbios-dev.dedyn.io:/symbios/git/SymbiOS/scripts/<file>
```

---

## 2. Conventions (all scripts)

- `--help` / `-h`: **every** script answers with purpose, subcommands,
  options, examples, output format and exit codes (AGENTS.md `--help`
  rule). Unknown options print usage to stderr and exit `1`.
  `symbios-set-hostname.sh` (`f_usage`) is the model. Libraries answer
  `--help` via the `BASH_SOURCE == $0` guard instead of executing.
- Exit codes: `0` = ok / nothing to do, `2` = usage or validation error,
  `1` = technical error.
- Idempotency: running twice with the same input changes nothing the
  second time and reports `unchanged`. State-changing scripts print a
  machine-readable token on the last line (`<domain>-changed` /
  `<domain>-unchanged`) for Ansible and the WebUI.
- `--check` (where offered): dry run, reports what would change, changes
  nothing.
- Output: human-readable status lines for the exec modal; `--json` (where
  offered) for machine consumption. Secret *values* are never printed -
  only whether one is configured (`ai_apikey_set: true`).
- Secrets NEVER travel as argv (visible in `ps`): they go via stdin JSON
  or stdin file content (pattern: `symbios-write-authorized-keys.sh` with
  `stdin_data=`). Scripts that own secrets reject them as flags with an
  explicit error pointing at `--json-stdin`.
- Bash style: `[[ ]]`, two-space indent, `g_echo` family, `f_` locals /
  `g_` globals, `if ... <newline> then`. Every script sources
  `gaboshlib.include` and `symbios-lib.sh` (except pre-mount scripts, see
  below) and uses `g_*` paths instead of hardcoded locations.

---

## 3. Settings CLI-first scripts

One script per WebUI page `/settings/<slug>/`:
`scripts/symbios-settings-<slug>.sh`. The WebUI view is a thin wrapper
(`run_command()` + exec-modal job); validation and the `inventory.yml`
write live here. Contract per script: `get [--json]`, `set ... [--check]`,
`schema`, `-h/--help`, plus domain extras (`test`, `remove`, ...).
`set` writes all keys in ONE transaction. Empty values delete the key
(WebUI "clear the field to remove" behavior).

### 3.1 `symbios-inventory.py` - the single YAML writer

The ONLY host-side writer of `inventory.yml` (domain scripts delegate to
it; it knows no domains). Atomic write (tmp + `fsync` + `os.replace`) with
`.bak` backup, same guarantees as the WebUI `_save_inventory_config`.

```bash
symbios-inventory.py get timezone
symbios-inventory.py set timezone Europe/Berlin
echo '{"timezone":"Europe/Berlin","ai_server":null}' | symbios-inventory.py merge
symbios-inventory.py del ai_apikey
symbios-inventory.py --inventory /path/to/inventory.yml get timezone
```

| Subcommand | Purpose |
|------------|---------|
| `get <key>` | Print one `all.vars` value (`true`/`false` for bools, one item per line for lists; `--json` for any type as JSON); exit 1 when unset |
| `set <key> <value>` | Store one **string** value (non-string types: use `merge`) |
| `merge` | Merge a JSON object from stdin in one transaction; `null` deletes the key; preserves JSON types (bool/number/string, lists and string-keyed dicts of those) |
| `del <key>` | Delete one key (idempotent, missing keys report `unchanged`) |
| `dict-get <dict> <key>` | Print one dict entry as JSON; exit 1 when missing |
| `dict-set <dict> <key>` | Set one dict entry from a JSON value on stdin (creates the dict) |
| `dict-merge <dict> <key>` | Merge a JSON object from stdin into one dict entry (partial update, creates it) |
| `dict-del <dict> <key>` | Delete one dict entry (idempotent) |
| `dict-keys <dict>` | Print dict keys, one per line |
| `dict-show <dict>` | Print a string-valued dict as `k=v` lines |
| `list-add <key>` | Append a stdin JSON value to a list unless already present |
| `list-del <key>` | Remove stdin-JSON-equal entries from a list (idempotent) |

`set`/`merge`/`del` accept `--check` (dry run). Key names must match
`^[A-Za-z_][A-Za-z0-9_]*$` (exit 2 otherwise). Exit codes: 0 ok/unchanged,
2 usage/validation, 1 technical.

### 3.2 `symbios-settings-localization.sh` (pilot)

Timezone, keyboard layout, locale (`localization_configured` flag included).

```bash
symbios-settings-localization.sh get [--json]
symbios-settings-localization.sh set --timezone Europe/Berlin --keyboard de --locale de_DE.UTF-8 [--check]
echo '{"timezone":"Europe/Berlin"}' | symbios-settings-localization.sh set --json-stdin
symbios-settings-localization.sh keyboards   # wraps symbios-list-keyboards.sh
symbios-settings-localization.sh timezones   # from host timedatectl
symbios-settings-localization.sh schema
```

Validation: timezone must exist in `timedatectl list-timezones` (when
available), keyboard must exist in the XKB list (when available), locale
must match `language[_territory][.codeset][@modifier]`. Omitted options
keep their current value. Token: `localization-changed/-unchanged`.

### 3.3 `symbios-settings-ai.sh`

OpenAI-compatible server URL + API key.

```bash
symbios-settings-ai.sh get [--json]
symbios-settings-ai.sh set --ai-server https://ai.example.com/v1 [--check]
echo '{"ai_server":"https://...","ai_apikey":"sk-.."}' | symbios-settings-ai.sh set --json-stdin
```

`ai_apikey` is secret: there is deliberately NO `--ai-apikey` flag
(passing one is a validation error). `get --json` reports
`ai_apikey_set` (bool), never the value.

### 3.4 `symbios-settings-ai-speech.sh`

STT/TTS URLs, keys, models (`ai_stt_url`, `ai_stt_key`, `ai_stt_model`,
`ai_tts_url`, `ai_tts_key`, `ai_tts_model`). Keys only via `--json-stdin`
(`--stt-key`/`--tts-key` flags are rejected); other fields as
`--stt-url`, `--stt-model`, `--tts-url`, `--tts-model` flags or stdin.

### 3.5 `symbios-settings-ai-image.sh`

`ai_image_url`, `ai_image_model`, `ai_image_edit_url`,
`ai_image_edit_model`. No secrets - plain flags
(`--image-url`, `--image-model`, `--image-edit-url`,
`--image-edit-model`).

### 3.6 `symbios-settings-ai-search.sh`

`ai_tika_url`, `ai_searxng_url` (`--tika-url`, `--searxng-url`). The
SearXNG URL may carry the `<query>` placeholder.

### 3.7 `symbios-settings-auth.sh`

Login/2FA toggle (`twofa_enabled`, stored as a real YAML boolean).

```bash
symbios-settings-auth.sh get [--json]
symbios-settings-auth.sh set --twofa true|false [--check]
```

Enabling requires `smtp_server` + `smtp_from` (Authelia mails the second
factor) - enforced here, exit 2 otherwise.

### 3.8 `symbios-settings-acme.sh`

Custom ACME CA server (`acme_server`).

```bash
symbios-settings-acme.sh get [--json]
symbios-settings-acme.sh set --server https://ca.example.com/acme/acme/directory [--check]
symbios-settings-acme.sh remove [--check]   # back to the default CA
```

`remove` deletes the key; the playbook default (`""`) and the
`{% if acme_server %}` guard in `traefik.yml` treat a missing key exactly
like the empty string the WebUI used to write.

### 3.9 `schema` subcommand (all settings scripts)

```bash
symbios-settings-localization.sh schema
```

Emits a JSON array of field descriptors (`name`, `type`
[`text`|`password`|`url`|`bool`|`select`], `label`, `required`,
`default`, `secret`, plus `pattern`/`placeholder`/`detect`/`needs` where
relevant) for future generic WebUI form rendering. Validate with
`... schema | python3 -c "import json,sys; json.load(sys.stdin)"`.

### 3.10 `symbios-settings-ssh-keys.sh`

Root `authorized_keys` user keys. Exception domain: manages a host FILE,
not `inventory.yml` (the documented SSH-key exception). The file write is
delegated to `symbios-write-authorized-keys.sh` (atomic, always preserves
the `symbios-base-webui` gateway key); this script adds strict validation
(key type + base64), index-based removal over user keys only, and JSON
list output. The gateway key can never be edited or removed here.

```bash
symbios-settings-ssh-keys.sh list [--json]
printf '%s\n' "ssh-ed25519 AAAA... user@host" | symbios-settings-ssh-keys.sh validate --stdin
symbios-settings-ssh-keys.sh add --key "ssh-ed25519 AAAA... user@host" [--check]
symbios-settings-ssh-keys.sh remove --index 0 [--check]
printf '%s\n' "ssh-ed25519 AAAA... user@host" | symbios-settings-ssh-keys.sh set --stdin [--check]
```

### 3.11 `symbios-settings-backup.sh`

Backup target: server host/port/user/path, encryption flag (real YAML
boolean), rsync exclude patterns (YAML list; needs `merge` list support
in `symbios-inventory.py` plus `get --json` for reading the list back).

```bash
symbios-settings-backup.sh get [--json]
symbios-settings-backup.sh set --host backup.example.com --port 22 --user root --path /backups/symbios --encryption true [--check]
printf '%s\n' '*.tmp' 'cache/' | symbios-settings-backup.sh set --exclude-stdin [--check]
```

Snapshot listing, passphrase handling (`symbios-backup.sh
gen-passphrase|get-passphrase` - the passphrase is NOT an inventory var),
restore and manual runs stay with their dedicated scripts and thin
endpoints.

### 3.12 `symbios-settings-dns.sh`

deSEC DynDNS or self-managed domain (the host becomes `base_domain`).
Live deSEC API probes (availability, API-key test, registration, captcha,
host status) stay Python in the container.

```bash
symbios-settings-dns.sh get [--json]
echo '{"ddns_host":"myhost","ddns_apikey":"token..","ddns_ipv6":""}' | symbios-settings-dns.sh set --mode desec --json-stdin [--check]
symbios-settings-dns.sh set --mode self-managed --domain example.com [--check]
symbios-settings-dns.sh remove [--check]
```

Host normalization (lowercase, `.dedyn.io` suffix) and FQDN validation
live here; `ddns_apikey` only via `--json-stdin`.

### 3.13 `symbios-settings-security.sh`

Password policy (`none|low|medium|high|paranoid`) and WebUI public-access
flag (real boolean). Each field optional (two forms share the page);
whether traefik is reapplied after a public-access flip is decided by the
caller from old vs new values.

```bash
symbios-settings-security.sh set --policy high --public-access true [--check]
```

### 3.14 `symbios-settings-media.sh`

The 8 standard media paths (all required, all absolute). Flags mirror the
keys (`--media-root`, `--audio`, `--images`, `--videos`, `--books`,
`--documents`, `--inbox`, `--shared`); omitted options keep their values.
Values are stored with `printf -v`/indirect expansion, never `eval`
(form values may hold quotes or `$()`).

### 3.15 `symbios-settings-mailserver.sh`

SMTP relay (server/port/user/password/sender/TLS). Password only via
`--json-stdin`; `%EMAILADDRESS%`/`%EMAILLOCALPART%` expansion lives here.
The view runs `set --check` first, then its live smtplib probe, then the
real set. `remove` refuses while 2FA or mail notifications are enabled.

### 3.16 `symbios-settings-matrix.sh` / `symbios-settings-notifications.sh`

Matrix sender account (homeserver defaults to `https://`, full-ID and
room validation, secrets via stdin, empty secret deletes its key) and the
notification toggles (mail needs SMTP, matrix needs a complete account -
preconditions live in the scripts). Homeserver reachability and test
delivery stay Python probes.

### 3.17 `symbios-settings-openvpn.sh`

Tunnel metadata dict (`openvpn_clients`) via `dict-merge` (only given
fields update, stored fields are kept - so enable/disable is
`save --name N --enabled ...`), plus the `openvpn_configured` flag.
Cron (5 fields), ufw port list and fetch-mode rules are validated here.
Config upload, tunnel control and applying stay with
`symbios-write-openvpn-config.sh` / `symbios-openvpn-client.sh` /
`base-services/openvpn-client.yml`.

### 3.18 `symbios-settings-network-bridges.sh` / `symbios-settings-wlan-ap.sh`

Bridge assignments (whole-dict replace from stdin JSON; names must match
the assign script's `[A-Za-z0-9_.@-]` charset since they reach
`ip link set`) and WLAN AP settings (passphrase via stdin, 8+ chars,
country uppercased to 2 letters). Discovery scans and playbooks stay
where they are.

### 3.19 `symbios-settings-port-forwarding.sh`

Port-forwarding inventory state (router control stays with
`symbios-router-upnp.sh`): `set --method auto|manual|""` (manual marks
both configured flags done), `set --configured/--static-ip-configured`,
and `ufw-add/ufw-remove --port --proto` (canonicalized entries via
`list-add`/`list-del`; leading-zero ports compare decimally with `10#`).

### 3.20 `symbios-settings-filemanager.sh` / `symbios-settings-setup.sh`

Companion CLIs for non-`/settings/` endpoints that still own inventory
state: file manager custom scripts (validated name/command list) and the
setup wizard connection type (`home|root|airgapped`).

---

## 4. Script catalog

One line per script: purpose + arguments. Details always via
`<script> --help` on the host (new settings scripts and recent helpers
comply with the `--help` rule; older scripts predate it and gain usage
texts opportunistically).

### 4.0 Settings CLI scripts (full reference in section 3)

| Script | WebUI page |
|--------|------------|
| `symbios-inventory.py` | (shared writer, no page) |
| `symbios-settings-localization.sh` | `/settings/localization/` |
| `symbios-settings-ai.sh`, `-ai-speech.sh`, `-ai-image.sh`, `-ai-search.sh` | `/settings/ai*/` |
| `symbios-settings-auth.sh` | `/settings/auth/` |
| `symbios-settings-acme.sh` | `/settings/acme/` |
| `symbios-settings-ssh-keys.sh` | `/settings/ssh-keys/` |
| `symbios-settings-backup.sh` | `/settings/backup/` |
| `symbios-settings-dns.sh` | `/settings/dns/` |
| `symbios-settings-security.sh` | `/settings/security/` |
| `symbios-settings-media.sh` | `/settings/media/` |
| `symbios-settings-mailserver.sh` | `/settings/mailserver/` |
| `symbios-settings-matrix.sh` | `/settings/matrix/` |
| `symbios-settings-notifications.sh` | `/settings/notifications/` |
| `symbios-settings-openvpn.sh` | `/settings/openvpn/` |
| `symbios-settings-network-bridges.sh` | `/settings/network-bridges/` |
| `symbios-settings-wlan-ap.sh` | `/settings/wlan-accesspoint/` |
| `symbios-settings-port-forwarding.sh` | `/settings/port-forwarding/` |
| `symbios-settings-filemanager.sh` | `/filemanager/api/` (save-scripts) |
| `symbios-settings-setup.sh` | `/setup/` (network type) |

### 4.1 Execution, jobs, playbooks, state

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-exec.sh` | SSH exec gateway: audit-logs and runs WebUI host commands | `<command>` |
| `symbios-run-playbook.sh` | Run one Ansible playbook (local connection, host inventory) | `<playbook_path>` |
| `symbios-reapply.sh` | Re-run installed playbooks in background (from state file) | `[--only [--force] <playbook> ...]` |
| `symbios-reapply-status.sh` | Read the reapply status string for the WebUI | no args |
| `symbios-run-detached.sh` | Detached host jobs pollable by the WebUI | `start\|poll\|... <job-id> <command>` |
| `symbios-state.sh` | `installed-playbooks.yml` state file manager | `set\|unset\|list\|is-installed <path>` |
| `symbios-restart-docker-services.sh` | Restart all Docker Compose stacks cleanly after boot | no args |
| `symbios-uninstall.sh` | Uninstall a service (full wipe or program-only, per `# docs:` block) | `<playbook> full\|program` |
| `symbios-update.sh` | Git pull + run changed installed playbooks | no args |

### 4.2 System and host

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-set-hostname.sh` | Hostname from `base_domain`, idempotent, `--check` mode (template model) | `[--check]` |
| `symbios-power.sh` | Reboot / shutdown the host (WebUI, exec-modal notice) | `reboot\|shutdown` |
| `symbios-data-partition.sh` | `/symbios` data partition incl. LUKS setup/mount/rollback. Pre-mount: hardcodes paths, never sources `symbios-lib.sh` | `list\|status\|setup\|rollback` |
| `symbios-detect-network-type.sh` | Connection type (`home`/`root`/`airgapped`) as JSON | no args |
| `symbios-get-local-ip.sh` | Local RFC1918 IPv4 (`.host-ip` file, `hostname -I` fallback) | no args |
| `symbios-get-local-ips.sh` | Hostname + LAN IPv4 + global IPv6 as JSON | no args |
| `symbios-list-keyboards.sh` | XKB keyboard layouts (wrapped by settings-localization) | no args |
| `symbios-ssl-check.sh` | Traefik domain certificate validity as JSON | `[-d\|--domain <domain>]` |
| `symbios-service-status.sh` | System service statuses (TSV for Health page) | no args |
| `symbios-container-index.sh` | Docker container index + ACL logs for the WebUI | no args |
| `symbios-test-ssh.sh` | SSH connectivity test with the backup identity | `<host> <port> <user> [path]` |
| `update_host_ip.sh` | Snapshot host LAN IP to `.host-ip` | no args |

### 4.3 LDAP, users, groups, SSH keys

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-ldap.sh` | LDAP wrapper (search/add/modify/delete/list/next-uid, container-internal) | `<command> [options]` |
| `symbios-ldap-user.sh` | LDAP users create/delete/modify incl. SSH keys | `--create\|--delete\|--modify --uid ...` |
| `symbios-ldap-groups.sh` | LDAP groups create/delete/add/remove/list; fires `ldap-groups.d/*.hook` | `--create\|--delete\|--add-user\|--remove-user\|--list-members` |
| `symbios-ldap-list.sh` | LDAP users/groups as JSON for the WebUI | `--users\|--groups` |
| `symbios-write-authorized-keys.sh` | Root `authorized_keys` from stdin (keeps the gateway key) | stdin, no args |
| `symbios-sftp-share-homes.sh` | SFTP chroot home dirs for `media` / `shared-*` members | `[uid]` |

### 4.4 Network, router, VPN, bridges, DynDNS

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-network-scan.sh` | LAN devices + WiFi stations as JSON (60 s cached) | `[--fresh]` |
| `symbios-router-detect.sh` | Router detection via UPnP IGD (`fritzbox`/`generic_upnp`) | no args |
| `symbios-router-upnp.sh` | Port-forwarding dispatcher (FRITZ!Box vs generic UPnP) | `config\|add\|delete\|list\|...` |
| `symbios-router-fritz.py` | FRITZ!Box `data.lua` API backend (env credentials) | called via router-upnp |
| `symbios-openvpn-client.sh` | OpenVPN client tunnels | `list\|status\|up\|down\|enable\|disable\|delete\|fetch\|log` |
| `symbios-write-openvpn-config.sh` | OpenVPN client config from stdin to the data volume | `<name>`, stdin |
| `symbios-bridge-list.sh` | Linux bridges + physical interfaces as JSON | no args |
| `symbios-bridge-assign.sh` | Interface-to-bridge assignments (JSON dict via stdin, persisted) | stdin JSON |
| `symbios-ow-bridge-dhcp.sh` | DHCP lease maintenance on OpenWrt host bridges (timer) | no args |
| `dedyn.sh` | deSEC DynDNS updater (DNS records <- public IP) | no args |
| `dedyn-register.sh` | deSEC account registration, API token, domain setup | `captcha\|register\|login\|create-token\|create-domain\|setup\|activate` |

### 4.5 Backup, restore, updates

| Script | Purpose | Usage |
|--------|---------|-------|
| `backup.sh` | Backup dispatcher (runs `backup.d/*.backup`) | no args |
| `backup.d/` | 2 backup modules (docker DBs, LDAP) | via `backup.sh` |
| `symbios-backup.sh` | Backup engine: daily hardlink snapshot, local or rsync/SSH | no args (cron) |
| `symbios-backup-list.sh` | Backup snapshots as JSON (WebUI backup page) | no args |
| `symbios-restore.sh` | Per-service or full restore with `plan` dry-run | `plan\|restore <date> [service\|--full] [--yes]` |
| `autoupdate.sh` | Update dispatcher (runs `autoupdate.d/*.update`) | `[module ...]` |
| `autoupdate.d/` | 5 update modules (debian, docker, symbios, ...) | via `autoupdate.sh` |

### 4.6 Monitoring and health

| Script | Purpose | Usage |
|--------|---------|-------|
| `runchecks.sh` | Health daemon: `runchecks.d/*.check` every 5 min -> JSON | no args |
| `runchecks.d/` | 35 check scripts (basic + per-service healthchecks) | via `runchecks.sh` |
| `runchecks-watchdog.sh` | Restarts `runchecks.service` when results JSON goes stale | no args |
| `symbios-run-check.sh` | Single health check on demand (JSON result) | `<check-name>` |
| `symbios-system-stats.sh` | CPU/load/mem/swap/uptime/IO as JSON (`/proc` based) | no args |
| `symbios-top-procs.sh` | Top processes by CPU/mem/IO as JSON (delta-based I/O) | `[top_n]` |
| `symbios-docker-stats.sh` | `docker stats` snapshot JSON (normalized units) | `[timeout]` |
| `symbios-dashboard-snapshot.sh` | Minutely dashboard snapshot + 7-day history (cron) | no args |
| `traefik-qualys-ssl-labs-check.sh` | TLS grades via Qualys SSL Labs API | no args |

### 4.7 Service admin sync and maintenance

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-nextcloud-admin-sync.sh` | Nextcloud admins from LDAP `nextcloud-admins` | no args |
| `symbios-nextcloud-media-scan.sh` | Index new files on Nextcloud external media mounts | `[mount ...]` |
| `symbios-openwebui-admin-sync.sh` | OpenWebUI admin roles from LDAP `openwebui-admins` | no args |
| `symbios-home-assistant-admin-sync.sh` | Home Assistant admins from LDAP group | no args |
| `symbios-paperless-admin-sync.sh` | Paperless superuser flags from LDAP `paperless-admins` | no args |
| `symbios-navidrome-password-sync.sh` | Navidrome API passwords from LDAP changes (group hook) | `<event> <uid> [pwfile]` |
| `symbios-s3-user-sync.sh` | rest-server S3 htpasswd users from LDAP `s3-users` | `<event> <uid> [pwfile]` |
| `symbios-matrix-recreate-room.sh` | Recreate a broken Matrix room under the same alias (E2EE default) | `<ALIAS> [userid ...]` |
| `symbios-synapse-purge.sh` | Synapse DB cleanup (vacuum/purge; destructive modes manual only) | `daily\|weekly\|monthly\|purge\|...\|vacuum*` |
| `symbios-wordpress-db.sh` | Per-instance DBs/users on the shared MariaDB | `<instance> [...]` |
| `symbios-wordpress-env.sh` | Shared-db `.env` with root + per-instance passwords | `<instance> [...]` |
| `symbios-wordpress-fix-perms.sh` | Docroot ownership + SFTP ACL repair | `<name> ...` |
| `symbios-media-share.sh` | Group share dirs below `media_root/shared` | `--list\|--create\|--delete --name ...` |
| `symbios-traefik-proxy-apply.sh` | Validate/apply reverse-proxy forwards (Traefik provider) | `[--apply\|--list\|--import <dir>]` |

### 4.8 Power management (WoL / idle suspend)

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-wol-suspend-apply.sh` | Apply WoL + idle-suspend power targets | `--list\|--apply\|--wake\|--check\|--status` |
| `symbios-wol-watch-idle.sh` | Suspend a target over SSH after idle timeout | `<target> [--check]` |
| `symbios-wol-watch-tail.sh` | Tail access log, send WoL magic packet on demand | `<target>` |

### 4.9 Logs, files, notifications, features

| Script | Purpose | Usage |
|--------|---------|-------|
| `symbios-fetch-log.sh` | System log slice + line count in one SSH round-trip | `<path> [offset] [limit]` |
| `symbios-fetch-docker-log.sh` | Container log slice + total count in one round-trip | `<container_id> [offset] [limit]` |
| `symbios-file-manager.sh` | Web file manager host ops (list/stat/read/write/...) | verb subcommands |
| `symbios-notify.sh` | Notification dispatcher (mail + Matrix), stdin pipe | `[-s subject] [-m mail] ...`, stdin |
| `symbios-feature-apply.sh` | Feature executor (plugin.yml params -> playbook) | `<service> <feature>` |
| `symbios-feature-detect.sh` | Feature param detect script (`{value,label}` JSON) | `<service> <feature> <param>` |
| `symbios-boot-unlock/` | Pre-mount boot-unlock helpers (3 files; hardcode paths by design) | boot-time only |
| `symbios-dev-check-all.sh` | End-to-end service test incl. Authelia login/group checks | `[--service <name>] [--list-services]` |

### 4.10 Libraries (sourced, never executed)

| File | Purpose |
|------|---------|
| `symbios-lib.sh` | Central config: `g_*` paths from `inventory.yml`, `f_symbios_var` (read), `f_symbios_var_set` (write via `symbios-inventory.py`), JSON/LDAP/Traefik helpers |
| `symbios-backup-lib.sh` | Shared backup/restore helpers (sourced by `backup.sh`, `restore.sh`, ...) |
| `symbios-wol-common.sh` | Shared WoL watcher helpers |

---

## 5. Adding a settings domain (checklist)

1. Scaffold from the pilot: copy `symbios-settings-localization.sh` structure
   (`get`/`set`/`schema`, `--check`, exit 0/2/1, state token, `$g_symbios_dir`
   sibling calls, secrets only via `--json-stdin`).
2. Validate in the script, write via `symbios-inventory.py merge` (one
   transaction, values via stdin JSON when secrets are involved).
3. Thin the WebUI view: `run_command('symbios-settings-<slug>.sh ...')` +
   `create_job()` reapply, exec-modal dual-mode AJAX/fallback. No
   `_save_inventory_config` in migrated views. Probes (external HTTP),
   rendering and job orchestration stay Python.
4. Verify on the host: `--help`, `get`, `schema` (JSON parses),
   `set` round-trip, `--check` changes nothing, invalid input exits `2`,
   inventory byte-identical afterwards when testing with current values.
5. Add the script to the catalog in section 4 above and register secrets
   (if any) in the AGENTS.md secret inventory + `symbios-exec.sh` masking.
