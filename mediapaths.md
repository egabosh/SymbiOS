# SymbiOS Standard Media Paths

Status: implemented and verified end-to-end on symbios-dev (sessions Oct
2026); this document is the design record. User-facing summary in README.md
("Shared media directories"), contributor rules in AGENTS.md
("Standard media paths").

## Problem

Every service invents its own media locations, so each new service
(Jellyfin, Nextcloud external storage, Paperless consume) re-threads
another host-specific path through per-service playbook vars. Central
media locations end that repetition: one source of truth, edited in the
WebUI, consumed by services instead of per-service vars.

## Decisions (locked)

- Predefined names and default directory names are **English, lowercase**:
  `audio`, `images`, `videos`, `books`, `documents`, `inbox` below `media_root`.
- Seventh variable `media_inbox` (`/symbios/media/inbox`): the only shared
  writable ingest point (SFTP uploads, yt-dlp, Paperless consume source).
  Libraries stay read-only.
- One shared filesystem GID `media_gid: 31000` (**fixed value**, never derived
  from the LDAP group hash). The LDAP `media` group is the access source of
  truth; the fixed GID owns the on-disk dirs (setgid + default ACLs).
- The `media` LDAP group has a fixed GID and is **protected against deletion**
  in the WebUI and in `symbios-ldap-groups.sh --delete`.
- `sftp-share` talks **directly against LDAP** (NSS/PAM via
  `symbios_base_services`, same as Authelia at
  `ldap://symbios-base-ldap:389`). No `br-ldap` network exists or is needed.
  The old `SFTPUSERS` materialization is removed. Chroot stays a single
  root-owned dir with `media_root` mounted below it; fine-grained rights come
  from filesystem permissions, not per-user chroots.
- SSH public keys are stored **in LDAP** (`sshPublicKey`, `openssh-lpk`
  schema) and managed in the WebUI user dialog. Password auth stays via
  PAM-LDAP; pubkey auth via `AuthorizedKeysCommand ldapsearch`.
- WebUI in two stages: (1) pubkey field in the user dialog now; (2) a
  dedicated Media settings page only once >= 2 consumers are migrated
  (until then the raw config editor is enough).

## Variables (inventory.yml, literal paths, no Jinja)

| Variable | Purpose | Default |
|----------|---------|---------|
| `media_root` | Base dir for all media below | `/symbios/media` |
| `media_audio` | Read-only audio library (music, podcasts, audiobooks) | `/symbios/media/audio` |
| `media_images` | Photo/image library | `/symbios/media/images` |
| `media_videos` | Video library / movies / series | `/symbios/media/videos` |
| `media_books` | E-books, audiobooks | `/symbios/media/books` |
| `media_documents` | Document library / archive (e.g. Paperless) | `/symbios/media/documents` |
| `media_inbox` | Shared writable ingest | `/symbios/media/inbox` |
| `media_shared` | Group shares base (`shared/<name>`, one LDAP group each) | `/symbios/media/shared` |
| `media_gid` | Shared filesystem GID (fixed) | `31000` |

Defaults live under `data_root`. Per-host overrides may point anywhere,
including external volumes - which only exist after the volume is mounted,
so validate (or offer creation) before pointing a library at them.

## Access model (implemented)

Three tiers below `media_root`:

1. **Private** (`home/<uid>`, `0700` owner-only): only the user itself
   (root bypasses for backups). Created automatically for every SFTP-
   eligible user by `symbios-sftp-share-homes.sh` (playbook + entrypoint +
   ldap-groups hook on `member-added` for `media` and `shared-*`).
   Pitfall: `mkdir` inherits parent setgid and a lone `chmod 0700` skips
   the syscall when 0777 already matches (coreutils "retained") - always
   clear explicitly (`chmod 0700` + `chmod g-s`). The `home/` base itself
   is `0711` (traverse-only, no listing).
2. **Group shares** (`shared/<name>`, `2770`): exactly the members of one
   LDAP group (default auto-created `shared-<name>`). Managed by
   `symbios-media-share.sh` (`--list/--create/--delete`; delete refuses
   non-empty dirs and only removes auto-created groups) and the Shares
   WebUI page (`shares.html`, membership via the Groups page).
3. **Libraries** (audio/images/videos/books/documents): every `media`
   member reads, nobody writes except the owner app (plus `:ro` mounts and
   `2750` as second and third lock).

SFTP side: chroot is `media_root` (`2751`: group lists, everyone
traverses), `AllowGroups media shared-*`, default landing is the chroot
root, `Match Group media` lands in `/inbox` instead. `%u` is NOT expanded
in `internal-sftp -d` args, so per-user start dirs are impossible; Match
blocks must stay last in `sftp-share.conf`. Port 28 has no fail2ban
coverage - rate-limit at the daemon (`MaxAuthTries 3`, `LoginGraceTime 60`,
`MaxStartups 3:50:10`).

## Consumers

- **Navidrome** (pilot): read-only `/music` from `media_audio`.
  Migrated from `navidrome_music_path` / `navidrome_music_gid` to the global
  `media_audio` (+ `media_gid`), old vars kept as deprecated fallback
  (`navidrome_music_path` keeps its name: `/music` is Navidrome terminology).
- **Jellyfin**: multiple libraries (videos/audio/images) from `media_videos` /
  `media_audio` / `media_images`, `:ro` mounts, non-root user with
  supplementary `media_gid`.
- **sftp-share**: `sftp_share_datadir = media_root` (Chroot), read/write
  enforced by LDAP group membership (`AllowGroups media shared-*`) +
  on-disk perms.
- **youtube-dl**: downloads land in
  `media_videos/downloads` so Jellyfin picks them up directly.
- **Nextcloud**: `media_audio` / `media_videos` /
  `media_images` / `media_documents` mounted `:ro` plus registered as
  global external storage (`occ files_external:create`, idempotent).
  Nextcloud can never modify the libraries (read-only mounts).
- **Paperless**: `media_documents` as document archive (paperless owns and
  writes it via `USERMAP_GID=media` plus a dedicated ACL, the media group
  only reads). Ingest moved to `media_inbox/paperless` (also the Samba
  `[paperless-in]` target). `./data` and `./export` stay service-local.
- **Home Assistant**: libraries mounted `:ro` below HA's own
  `/media` and exposed in the Media Browser via `media_dirs`
  (`audio`/`videos`/`images`); `./media` stays app-owned (TTS, camera clips).

## Open follow-ups (not started)

- Backup strategy for `/symbios/media`: libraries likely belong into
  `backup_exclude`, documents/inbox likely not - undecided.
- Brute-force protection for SFTP port 28 beyond daemon limits
  (fail2ban on container logs or router-side rate limiting).
- Least-privilege LDAP bind user for the SFTP container (today: shared
  `readuser`, which reads the whole directory).
- Samba `[paperless-in]` user: the `paperless` system account does not
  exist where uid 998 is taken (e.g. by `systemd-network`) - map or
  create a working upload identity.

## Three semantics (do not conflate)

1. **Read-only library** (Navidrome, Jellyfin): container needs read access
   only. Solved via supplementary `media_gid` (fixed 31000) plus `:ro` mounts.
2. **Ingest directory** (Paperless consume, SFTP uploads, yt-dlp): container
   writes, moves and deletes. Destructive. Must never point at a library dir -
   use `media_inbox` (or a subdir of it).
3. **App-owned data** (Nextcloud data, thumbs, caches): belongs to the app
   alone, stays under `/symbios/services/<name>/`.

## Permission model

Containers run as different UIDs (navidrome 33, nextcloud www-data,
paperless 998, ...). One shared `media` group; every media-consuming
container user joins it via supplementary `media_gid`; `g+s` and default
ACLs on the media root so new files inherit the group. Read-only mounts
additionally get `:ro`. SFTP umask is `0007` so uploads stay group-readable.
LDAP users resolve to their real `uidNumber` (20000+) inside the SFTP
container via NSS - no materialized local accounts.

GID allocation: infrastructure groups use the fixed range 31xxx
(`media` = 31000). Playbook-created service groups keep the hash range
20000-29999 from `symbios-ldap-groups.sh`; system groups stay at
30000/30001 (`ldap-admins`/`ldap-users`).

## Non-goals

- No per-service media vars for new services - use the globals from day one.
- Host-specific migration paths live in `migrations/<host>/`, never here.
