# SymbiOS Standard Media Paths

Status: in implementation (sessions Oct 2026). Pilot precedent already merged:
`services/navidrome.yml` (`navidrome_music_path` / `navidrome_music_gid`)
proves the read-only mount + supplementary gid pattern works.

## Problem

Every service invents its own media locations. The defiant migration proved
the pain: the music library lives at the host-specific path
`/data-crypt/share/Musik/Uploaddatum` and had to be threaded through as
per-service playbook vars. The next service (Jellyfin, Nextcloud external
storage, Paperless consume) would reinvent this again.

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
| `media_gid` | Shared filesystem GID (fixed) | `31000` |

Defaults live under `data_root`. Per-host overrides point anywhere
(incl. external volumes such as `/data-crypt/share/...`, which only exist
after the volume move - same gating problem as the navidrome pilot, see
`migration-defiant.md` 7.8 Schritt 0).

## Consumers

- **Navidrome** (pilot): read-only `/music` from `media_audio`.
  Migrated from `navidrome_music_path` / `navidrome_music_gid` to the global
  `media_audio` (+ `media_gid`), old vars kept as deprecated fallback
  (`navidrome_music_path` keeps its name: `/music` is Navidrome terminology).
- **Jellyfin**: multiple libraries (videos/audio/images) from `media_videos` /
  `media_audio` / `media_images`, `:ro` mounts, non-root user with
  supplementary `media_gid`.
- **sftp-share**: `sftp_share_datadir = media_root` (Chroot), read/write
  enforced by LDAP group membership (`AllowGroups media*`) + on-disk perms.
- **youtube-dl** (later): download dir into `media_videos` / `media_inbox`.
- **Nextcloud** (later): external storage pointing at the media dirs (instead
  of duplicating files into `nextcloud-data`).
- **Paperless** (implemented): `media_documents` as document archive (paperless
  owns and writes it via a dedicated ACL, the media group only reads).
  Ingest moved to `media_inbox/paperless` (also the Samba `[paperless-in]`
  target). `./data` and `./export` stay service-local.
- **youtube-dl** (implemented): downloads land in
  `media_videos/downloads` so Jellyfin picks them up directly.
- **Nextcloud** (implemented): `media_audio` / `media_videos` /
  `media_images` / `media_documents` mounted `:ro` plus registered as
  global external storage (`occ files_external:create`, idempotent).
  Nextcloud can never modify the libraries (read-only mounts).
- **Home Assistant** (implemented): libraries mounted `:ro` below HA's own
  `/media` and exposed in the Media Browser via `media_dirs`
  (`audio`/`videos`/`images`); `./media` stays app-owned (TTS, camera clips).

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
- The defiant host-specific paths stay in `migrations/defiant/` until the
  feature lands; then 7.8 switches to the globals.
