#!/usr/bin/env python3
"""Prepare DOS game folders for DOSBox Pure, the libretro core the kodi playbook builds.

DOSBox Pure starts a game from a file, never from a directory: Kodi refuses a
path without a file extension, and the core writes the changes of a running
game (savegames, installed data) into the loaded content. Loaded from a
directory it would write into the ROM tree itself, which a media server usually
exports read-only. Loaded from an archive it stores the changes as a separate
<game>.pure.zip in the frontend save directory.

The archive is named <game>.dosz: a plain zip container (the core mounts it
through the same code path as .zip) with the extension DOSBox Pure declares for
its own content. That matters in the frontend: it picks the game client by file
extension and asks the user whenever two clients claim the same one - the
arcade core claims .zip for its sets, so a .zip game would raise a client
dialog every time. .dosz is claimed by the DOS core alone.

Start menu: the core boots into its own start menu and lists the executables of
the archive there, remembering the chosen one in AUTOBOOT.DBP. That menu can
only be driven by a gamepad or by a mouse that reports absolute pointer
coordinates - the frontend (Kodi) hands out a relative pointer, so a keyboard
and mouse only setup can never leave the menu. The tool therefore picks the
start file itself and stores it as AUTOBOOT.DBP inside the archive (the same
file the menu writes, line 1 = the program, an absolute C:\\ path because the
core reads it before it switches to the C: drive). The core then skips the menu
and starts the game directly.

The pick is a heuristic: a file whose name matches the game title wins, then a
generic launcher name (start, game, play, ...), then any other program, and
installers, unpackers, driver stubs and diagnostic tools lose. An archive whose
candidates all look like tools (a game distributed as an installer, Doom for
example) keeps the menu, because the game has to be installed first.

A zip entry keeps its long name, but the DOS layer of the core has no long name
support: the drive stores a short name per entry and truncates any longer name
before it looks it up, so the marker names the short form the drive reports
(first four and last four characters of the base name).

Subcommands:
  pack       write one <game>.dosz per game folder and move the verified
             folder out of the tree the frontend lists (nothing is deleted)
  autostart  add the start marker to archives that already exist

Exit codes: 0 = ok, 1 = technical error, 2 = usage error.

Examples:
  symbios-dosbox-repack.py pack --roms /srv/roms/RETRO/computers/pc \\
      --archive /srv/roms/_RETROPIE/dumps/pc-unzipped
  symbios-dosbox-repack.py pack --roms /srv/roms/RETRO/computers/pc \\
      --archive /srv/roms/_RETROPIE/dumps/pc-unzipped --apply
  symbios-dosbox-repack.py autostart --roms /srv/roms/RETRO/computers/pc --apply
"""

import argparse
import os
import re
import shutil
import sys
import zipfile
import zlib

# Extensions the core starts a game from (addon.xml of game.libretro.dosbox-pure
# lists them as exe|com|bat|conf; the disk image types need a mount and are not
# a start file of a plain folder).
START_EXTENSIONS = (".exe", ".com", ".bat", ".conf")

# Extensions the start menu of the core offers, so the ones the marker may name.
RUN_EXTENSIONS = (".exe", ".com", ".bat")

# Name of the marker file the core reads on boot and writes from its menu.
MARKER_NAME = "AUTOBOOT.DBP"

# Characters a DOS name may carry, as the bit table of the core
# (DOS_ValidCharBits): letters, digits and _$~!#%&'()-{}@^`. Everything else is
# rejected by the DOS layer, so the drive replaces it in the short name.
DOS_VALID_CHARS = (
    0, 0, 0, 0, 250, 43, 255, 3, 255, 255, 255, 199, 1, 0, 0, 232,
    1, 192, 5, 254, 224, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
)

# File names that never start a game: installers, unpackers, driver stubs,
# diagnostics. Matched as a prefix so "install2" and "setupcd" count as well;
# every entry is specific enough not to hit a game title ("set" would hit
# "settlers", "dig" would hit "digger", so those stay out). A packed game
# (tatou.com) and a program named after the game (command.exe in Xenon 2) are
# start files, so neither name is on the list.
NOT_A_GAME = (
    "install", "instal", "setup", "uninst", "dosinst", "patch", "crack",
    "config", "setsound", "sndsetup", "sndset", "dxsetup", "gsetup",
    "vinstall", "vset", "detect", "readme", "readnote", "file_id", "info",
    "intro", "order", "register", "help", "mpscopy", "copyfil",
    "wizpat", "teledisk", "catalog", "edit", "serial", "trainer", "bootdisk",
    "_mstest", "basica", "gwbasic", "winstall", "ckit", "mkgame", "appendf",
    "uncmp", "decomp", "deice", "dearj", "unzip", "pkzip", "pkunz", "pkz",
    "arj", "lha", "lharc", "rar", "unrar", "unp", "extract", "lzexe",
    "exepack", "pklite", "pksmart", "dos4gw", "dos32a", "cwsdpmi",
    "cwsparam", "dpmi16bi", "pmode", "dosx", "dos16m", "wdosx", "stub",
    "scidhuv", "sierradg", "graphics", "doskey", "mscdex", "emm386", "himem",
    "smartdrv", "mouse", "chkdsk", "fdisk", "format",
)

# Programs that start the game in one fixed video or sound mode: usable, but a
# plain game program is the better guess.
MODE_LAUNCHER = ("vga", "ega", "cga", "tandy", "herc", "mda", "svga", "vesa", "snd", "sound")

# Programs named after what they do rather than after the game.
GENERIC_LAUNCHER = (
    "start", "game", "play", "run", "go", "main", "menu", "loader", "launch",
    "begin", "exec", "boot",
)


def f_start_files(f_dir):
    """Return True when the directory holds a start file below it."""
    for f_root, _, f_files in os.walk(f_dir):
        for f_name in f_files:
            if os.path.splitext(f_name)[1].lower() in START_EXTENSIONS:
                return True
    return False


def f_zip_name(f_name):
    """Return a name a zip entry can carry (CP437 for undecodable bytes)."""
    try:
        f_name.encode("utf-8")
        return f_name
    except UnicodeEncodeError:
        # A DOS tree may hold file names in the DOS code page (0xb7 for a
        # middle dot, for example). Python hands such bytes over as surrogates,
        # which a zip entry cannot store; decoding them as CP437 keeps the
        # byte values recoverable - the core maps them back to the code page.
        return f_name.encode("utf-8", "surrogateescape").decode("cp437", "replace")


def f_collect(f_dir):
    """Return [(abs path, archive name, is dir)] in a stable order."""
    f_entries = []
    for f_root, f_dirs, f_files in os.walk(f_dir):
        f_dirs.sort()
        f_files.sort()
        f_rel_root = os.path.relpath(f_root, f_dir)
        f_prefix = "" if f_rel_root == "." else f_rel_root.replace(os.sep, "/") + "/"
        # Directory entries keep an empty directory (a SAVE folder, for
        # example) alive inside the archive.
        for f_name in f_dirs:
            f_entries.append(
                (os.path.join(f_root, f_name), f_zip_name(f_prefix + f_name) + "/", True)
            )
        for f_name in f_files:
            f_path = os.path.join(f_root, f_name)
            f_entries.append((f_path, f_zip_name(f_prefix + f_name), False))
    return f_entries


def f_crc32(f_path):
    """Return the CRC32 of a file as an integer."""
    f_value = 0
    with open(f_path, "rb") as f_handle:
        while True:
            f_block = f_handle.read(1 << 20)
            if not f_block:
                break
            f_value = zlib.crc32(f_block, f_value)
    return f_value & 0xFFFFFFFF


def f_norm(f_text):
    """Return lowercase letters and digits only."""
    return re.sub(r"[^a-z0-9]", "", f_text.lower())


def f_stem(f_name):
    """Return the file name of an archive entry without directory and extension."""
    return os.path.splitext(f_name.rsplit("/", 1)[-1])[0].lower()


def f_start_rank(f_name, f_norm_game):
    """Return how likely a program starts the game (lower is better)."""
    f_base = f_stem(f_name)
    f_norm_base = f_norm(f_base)
    # A helper keeps its rank even when the game title mentions the word (an
    # "Original Install" release is an installer, not the game).
    if any(f_base.startswith(f_helper) for f_helper in NOT_A_GAME):
        return 4
    # A name that appears in the game title ("duke3d" in "Duke Nukem 3D") is
    # the strongest hint there is. Three characters at least: a one letter
    # launcher (A.EXE next to E.EXE) is no evidence at all.
    if len(f_norm_base) >= 3 and f_norm_base in f_norm_game:
        return 0
    if f_base in GENERIC_LAUNCHER:
        return 1
    if f_base in MODE_LAUNCHER:
        return 3
    return 2


def f_dos_byte(f_char):
    """Return the byte the DOS layer sees for one character of an archive name.

    The DOS layer of the core has no Unicode: it converts an entry name to the
    DOS code page (CP437) and then filters the bytes. A name read as UTF-8 or
    as CP437 therefore has to be mapped back before it can be compared.
    """
    f_code = ord(f_char)
    if f_code <= 0xFF:
        return f_code
    try:
        return f_char.encode("cp437")[0]
    except UnicodeEncodeError:
        # The code page conversion of the core turns an unmappable character
        # into a question mark, which the name filter then rejects.
        return ord("?")


def f_dos_char(f_char):
    """Return the character the core keeps of a name (DOS_ToUpperAndFilter)."""
    f_code = f_dos_byte(f_char)
    if DOS_VALID_CHARS[f_code // 8] & (1 << (f_code % 8)):
        return f_char
    if "a" <= f_char <= "z":
        return chr(f_code & 0x5F)
    if f_code < 0x80:
        return "-"
    return bytes([f_code]).decode("cp437").upper()


def f_dos_filter(f_text):
    """Return a name part with every character the core rejects replaced."""
    return "".join(f_dos_char(f_char) for f_char in f_text)


def f_dos_component(f_part):
    """Return the 8.3 name the core stores for one path component of a zip.

    A zip entry keeps its long name, but the core has no long name support in
    its DOS layer: the drive tree stores a short name per entry and that is the
    only name a DOS program (or the start marker) can address. Short names stay
    as they are; everything else becomes the first four and the last four
    characters of the base name plus three characters of the extension.
    """
    f_dot = f_part.rfind(".")
    # The core treats a dot in the first position as "no extension".
    if f_dot <= 0:
        f_base, f_ext = f_part, ""
    else:
        f_base, f_ext = f_part[:f_dot], f_part[f_dot + 1:]
    if len(f_base) <= 8 and len(f_ext) <= 3 and "." not in f_base:
        # Already a short name; only a rejected character forces a rewrite.
        f_short = f_base + ("" if not f_ext else "." + f_ext)
        if f_dos_filter(f_short) == f_short:
            return f_short
    f_left = f_base[:4] if len(f_base) > 8 else f_base
    f_right = f_base[-4:] if len(f_base) > 8 else ""
    f_short = f_dos_filter(f_left + f_right)
    if f_ext:
        f_short += "." + f_dos_filter(f_ext[:3])
    return f_short


def f_dos_path(f_name):
    """Return the path the core addresses for an archive entry."""
    return "/".join(f_dos_component(f_part) for f_part in f_name.split("/"))


def f_pick_start(f_game, f_files):
    """Return (entry name, reason) of the program that starts the game.

    f_files holds (archive name, size) of every file in the game. reason is
    "picked" when a start file was found, otherwise it says why the game keeps
    the menu: "no candidate", "tool only" or "name clash".
    """
    f_norm_game = f_norm(os.path.splitext(f_game)[0])
    f_pool = []
    for f_name, f_size in f_files:
        if f_name.rsplit("/", 1)[-1].upper() == MARKER_NAME:
            continue
        if os.path.splitext(f_name.rsplit("/", 1)[-1])[1].lower() not in RUN_EXTENSIONS:
            continue
        # Rank first, then the top level, then the biggest file: an installer
        # in the root never beats the game in a subdirectory.
        f_pool.append((f_start_rank(f_name, f_norm_game), f_name.count("/"), -f_size, f_name))
    if not f_pool:
        return None, "no candidate"
    f_rank, _, _, f_name = min(f_pool)
    if f_rank >= 4:
        return None, "tool only"
    # Two entries can end up with the same short name (zaxxon.sound.1984.com and
    # zaxxon.nosound.1984.com both become ZAXX1984.COM). The drive keeps one of
    # them under that name, so the marker would start whichever won - the menu
    # lets the player pick, and it names the full entry.
    f_dos_name = f_dos_path(f_name)
    if any(f_other != f_name and f_dos_path(f_other) == f_dos_name
           for f_other, _ in f_files):
        return None, "name clash"
    return f_name, "picked"


def f_marker_data(f_name):
    """Return (entry name, data) of the start marker for a program in the archive."""
    # The core builds "C:\\<program>" from line 1 and changes to that directory
    # before it runs it; CRLF is what its own menu writes. The name has to be
    # the short name the drive reports (f_dos_path): the DOS layer truncates
    # anything longer before it looks it up, and a space would split the
    # command line the core builds.
    f_dos_name = f_dos_path(f_name)
    return MARKER_NAME, ("C:\\" + f_dos_name.replace("/", "\\")).upper().encode("ascii") + b"\r\n"


def f_write_zip(f_target, f_entries, f_marker):
    """Write one game archive, replacing the target only when it is complete."""
    f_tmp = f_target + ".part"
    with zipfile.ZipFile(f_tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as f_zip:
        # write() detects a directory itself and stores an empty entry for it.
        for f_path, f_arcname, _ in f_entries:
            f_zip.write(f_path, arcname=f_arcname)
        if f_marker:
            f_zip.writestr(f_marker[0], f_marker[1])
    os.replace(f_tmp, f_target)


def f_verify(f_target, f_entries, f_marker):
    """Compare an archive against the source files; return a problem or None."""
    f_wanted = {f_arcname: (f_path, f_is_dir) for f_path, f_arcname, f_is_dir in f_entries}
    f_extra = {} if f_marker is None else {f_marker[0]: f_marker[1]}
    with zipfile.ZipFile(f_target) as f_zip:
        # testzip() reads every entry and checks its CRC, so a truncated
        # archive or a broken member shows up here and not in the core.
        f_broken = f_zip.testzip()
        if f_broken:
            return f"broken entry: {f_broken}"
        f_seen = set()
        for f_info in f_zip.infolist():
            f_arcname = f_info.filename
            f_seen.add(f_arcname)
            if f_arcname in f_extra:
                if f_info.CRC != zlib.crc32(f_extra[f_arcname]):
                    return f"checksum mismatch: {f_arcname}"
                continue
            if f_arcname not in f_wanted:
                return f"unexpected entry: {f_arcname}"
            f_path, f_is_dir = f_wanted[f_arcname]
            if f_is_dir:
                continue
            if f_info.file_size != os.path.getsize(f_path):
                return f"size mismatch: {f_arcname}"
            if f_info.CRC != f_crc32(f_path):
                return f"checksum mismatch: {f_arcname}"
    f_missing = set(f_wanted) - f_seen
    if f_missing:
        return f"missing entry: {sorted(f_missing)[0]}"
    return None


def f_rewrite_marker(f_target, f_marker):
    """Rewrite an existing archive with the start marker added, replaced or dropped."""
    f_tmp = f_target + ".part"
    with zipfile.ZipFile(f_target) as f_in, \
            zipfile.ZipFile(f_tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as f_out:
        for f_info in f_in.infolist():
            if f_info.filename.rsplit("/", 1)[-1].upper() == MARKER_NAME:
                continue
            # Streaming keeps a large disk image out of memory.
            with f_in.open(f_info) as f_src, f_out.open(f_info, "w") as f_dst:
                shutil.copyfileobj(f_src, f_dst, 1 << 20)
        if f_marker:
            f_out.writestr(f_marker[0], f_marker[1])
    os.replace(f_tmp, f_target)


def f_read_marker(f_zip):
    """Return the start marker stored in an archive, or None."""
    for f_info in f_zip.infolist():
        if f_info.filename.rsplit("/", 1)[-1].upper() == MARKER_NAME:
            return f_zip.read(f_info)
    return None


def f_marker_is_helper(f_data):
    """Return True when a marker names a helper instead of a game."""
    f_line = f_data.split(b"\r")[0].split(b"\n")[0].decode("cp437", "replace").strip()
    f_base = os.path.splitext(f_line.replace("\\", "/").rsplit("/", 1)[-1])[0].lower()
    return any(f_base.startswith(f_helper) for f_helper in NOT_A_GAME)


def f_archive_files(f_zip):
    """Return (archive name, size) of every file entry of an archive."""
    return [(f_info.filename, f_info.file_size) for f_info in f_zip.infolist()
            if not f_info.is_dir()]


def f_mode_pack(f_args, f_roms):
    """Write one archive per game folder and move the verified folder away."""
    # The packed folders must leave the tree the frontend lists, otherwise the
    # next scan would offer them again (as a folder next to their archive).
    f_archive = os.path.abspath(f_args.archive)
    if f_archive == f_roms or f_archive.startswith(f_roms + os.sep):
        print(f"error: archive directory must lie outside {f_roms}", file=sys.stderr)
        return 2

    f_games = sorted(
        f_name
        for f_name in os.listdir(f_roms)
        if os.path.isdir(os.path.join(f_roms, f_name))
    )
    if not f_games:
        print(f"error: no game folders in {f_roms}", file=sys.stderr)
        return 1
    print(f"roms: {len(f_games)} folders in {f_roms}")
    print(f"archive: {f_archive}")

    if f_args.apply:
        os.makedirs(f_archive, exist_ok=True)

    f_counts = {"written": 0, "exists": 0, "no start": 0, "moved": 0,
                "conflict": 0, "failed": 0, "menu": 0}
    for f_game in f_games:
        f_dir = os.path.join(f_roms, f_game)
        f_target = os.path.join(f_roms, f_game + ".dosz")

        if not f_start_files(f_dir):
            f_counts["no start"] += 1
            print(f"no start file: {f_game}")
            continue

        if os.path.exists(f_target) and not f_args.force:
            f_counts["exists"] += 1
            print(f"exists: {f_target}")
        else:
            f_entries = f_collect(f_dir)
            f_marker = None
            if f_args.autostart:
                f_name, f_reason = f_pick_start(f_game, [(f_arcname, os.path.getsize(f_path))
                                                         for f_path, f_arcname, f_is_dir in f_entries
                                                         if not f_is_dir])
                if f_name is None:
                    f_counts["menu"] += 1
                    print(f"menu kept ({f_reason}): {f_game}")
                else:
                    f_marker = f_marker_data(f_name)
            if f_args.apply:
                # One unreadable game must not abort the run: report it, drop
                # the half-written archive and continue with the next folder.
                try:
                    f_write_zip(f_target, f_entries, f_marker)
                except (OSError, UnicodeEncodeError) as f_err:
                    print(f"error: {f_game}: {f_err}", file=sys.stderr)
                    f_target_part = f_target + ".part"
                    if os.path.exists(f_target_part):
                        os.unlink(f_target_part)
                    f_counts["failed"] += 1
                    continue
                f_problem = f_verify(f_target, f_entries, f_marker)
                if f_problem:
                    print(f"error: {f_game}: {f_problem}", file=sys.stderr)
                    os.unlink(f_target)
                    f_counts["failed"] += 1
                    continue
            f_counts["written"] += 1
            print(f"{'wrote' if f_args.apply else 'would write'}: {f_target} "
                  f"({len(f_entries)} entries{'' if f_marker is None else ', autostart'})")

        # Only a verified archive replaces its folder, and only on request:
        # the folder stays available until the run is applied.
        if not f_args.apply:
            continue
        f_dest = os.path.join(f_archive, f_game)
        if os.path.exists(f_dest):
            f_counts["conflict"] += 1
            print(f"conflict, kept both: {f_game}", file=sys.stderr)
            continue
        try:
            shutil.move(f_dir, f_dest)
        except OSError as f_err:
            print(f"move failed: {f_game}: {f_err}", file=sys.stderr)
            f_counts["failed"] += 1
            continue
        f_counts["moved"] += 1

    print(f"games: {len(f_games)}, written: {f_counts['written']}, "
          f"already present: {f_counts['exists']}, no start file: {f_counts['no start']}, "
          f"menu kept: {f_counts['menu']}, moved: {f_counts['moved']}, "
          f"conflicts: {f_counts['conflict']}, failed: {f_counts['failed']}")
    return 1 if f_counts["failed"] else 0


def f_mode_autostart(f_args, f_roms):
    """Add the start marker to the archives of a directory."""
    f_games = sorted(f_name for f_name in os.listdir(f_roms)
                     if f_name.lower().endswith(".dosz"))
    if not f_games:
        print(f"error: no .dosz archives in {f_roms}", file=sys.stderr)
        return 1
    print(f"archives: {len(f_games)} in {f_roms}")

    f_counts = {"marked": 0, "unmarked": 0, "unchanged": 0, "kept": 0, "failed": 0,
                "no candidate": 0, "tool only": 0, "name clash": 0}
    for f_game in f_games:
        f_target = os.path.join(f_roms, f_game)
        try:
            with zipfile.ZipFile(f_target) as f_zip:
                f_existing = f_read_marker(f_zip)
                f_name, f_reason = f_pick_start(f_game, f_archive_files(f_zip))
        except (OSError, zipfile.BadZipFile) as f_err:
            print(f"error: {f_game}: {f_err}", file=sys.stderr)
            f_counts["failed"] += 1
            continue

        # A marker that names a helper never starts the game: it is the stale
        # pick of an older version of the helper list (a packer prints its usage
        # and quits at once) or a wrong choice. It counts as absent, so the
        # decision below writes the right marker or drops it for good.
        if f_existing is not None and f_marker_is_helper(f_existing):
            f_existing = None
            f_helper_marker = True
        else:
            f_helper_marker = False

        if f_name is None:
            # The menu stays: it is the only way to install a game that ships
            # as an installer (the game does not exist yet).
            f_counts["kept"] += 1
            f_counts[f_reason] = f_counts.get(f_reason, 0) + 1
            print(f"menu kept ({f_reason}): {f_game}")
            # A marker that names one of two entries sharing a short name
            # starts whichever entry the drive happened to keep, so it cannot
            # be trusted either.
            if f_helper_marker or (f_existing is not None and f_reason == "name clash"):
                f_counts["unmarked"] += 1
                if not f_args.apply:
                    print(f"would unmark ({f_reason}): {f_game}")
                    continue
                try:
                    f_rewrite_marker(f_target, None)
                    with zipfile.ZipFile(f_target) as f_zip:
                        if f_read_marker(f_zip) is not None:
                            raise OSError("marker still present after rewrite")
                except (OSError, zipfile.BadZipFile) as f_err:
                    print(f"error: {f_game}: {f_err}", file=sys.stderr)
                    f_counts["failed"] += 1
                    continue
                print(f"unmarked ({f_reason}): {f_game}")
            continue

        f_marker = f_marker_data(f_name)
        if f_existing == f_marker[1]:
            f_counts["unchanged"] += 1
            print(f"unchanged: {f_game}")
            continue
        if f_existing is not None and not f_args.force:
            f_counts["unchanged"] += 1
            print(f"marker kept (chosen in the menu): {f_game}")
            continue

        f_counts["marked"] += 1
        if not f_args.apply:
            print(f"would mark: {f_game} -> {f_marker[1].decode().strip()}")
            continue
        try:
            f_rewrite_marker(f_target, f_marker)
            with zipfile.ZipFile(f_target) as f_zip:
                if f_read_marker(f_zip) != f_marker[1]:
                    raise OSError("marker missing after rewrite")
        except (OSError, zipfile.BadZipFile) as f_err:
            print(f"error: {f_game}: {f_err}", file=sys.stderr)
            f_counts["failed"] += 1
            continue
        print(f"marked: {f_game} -> {f_marker[1].decode().strip()}")

    print(f"archives: {len(f_games)}, marked: {f_counts['marked']}, "
          f"unmarked: {f_counts['unmarked']}, "
          f"unchanged: {f_counts['unchanged']}, menu kept: {f_counts['kept']} "
          f"(no candidate: {f_counts['no candidate']}, "
          f"tool only: {f_counts['tool only']}, "
          f"name clash: {f_counts['name clash']}), "
          f"failed: {f_counts['failed']}")
    return 1 if f_counts["failed"] else 0


def f_main():
    # A ROM tree may hold names that are not valid UTF-8 (DOS code page
    # bytes); printing such a name must not kill the run.
    sys.stdout.reconfigure(errors="backslashreplace")
    sys.stderr.reconfigure(errors="backslashreplace")
    f_parser = argparse.ArgumentParser(
        description="Prepare DOS game folders for DOSBox Pure.",
        epilog="Both subcommands are dry runs unless --apply is given.",
    )
    f_sub = f_parser.add_subparsers(dest="mode", required=True)

    f_pack = f_sub.add_parser(
        "pack", help="write one <game>.dosz per game folder and move the folder away")
    f_pack.add_argument("--roms", required=True,
                        help="directory holding the game folders (read only)")
    f_pack.add_argument("--archive", required=True,
                        help="target directory for the packed folders, outside the "
                        "tree the frontend lists (a group folder below the ROM root "
                        "is listed as well)")
    f_pack.add_argument("--force", action="store_true",
                        help="rebuild archives that already exist")
    f_pack.add_argument("--apply", action="store_true",
                        help="write the archives and move the verified folders")
    f_pack.add_argument("--no-autostart", dest="autostart", action="store_false",
                        help="leave the start menu in place (no AUTOBOOT.DBP)")

    f_auto = f_sub.add_parser(
        "autostart",
        help="add the start marker to archives that already exist",
        description="Add the start marker (AUTOBOOT.DBP) to archives that already "
                    "exist, so the core starts the game instead of its menu. A "
                    "game without a usable start file keeps the menu; a marker "
                    "that names a helper (packer, installer) or one of two "
                    "entries that share a short name is dropped again.")
    f_auto.add_argument("--roms", required=True,
                        help="directory holding the .dosz archives")
    f_auto.add_argument("--force", action="store_true",
                        help="replace a marker that was chosen in the start menu")
    f_auto.add_argument("--apply", action="store_true",
                        help="rewrite the archives")

    f_args = f_parser.parse_args()
    if not os.path.isdir(f_args.roms):
        print(f"error: directory not found: {f_args.roms}", file=sys.stderr)
        return 1
    f_roms = os.path.abspath(f_args.roms)

    if f_args.mode == "pack":
        f_result = f_mode_pack(f_args, f_roms)
    else:
        f_result = f_mode_autostart(f_args, f_roms)

    print(f"dosbox-repack: mode={f_args.mode}, "
          f"write={'apply' if f_args.apply else 'dry-run'}")
    if f_result:
        return f_result
    print("dosbox-repack-done")
    return 0


if __name__ == "__main__":
    sys.exit(f_main())
