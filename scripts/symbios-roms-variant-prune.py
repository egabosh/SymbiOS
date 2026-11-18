#!/usr/bin/env python3
"""Move redundant ROM variants out of a ROM tree that Kodi lists.

ROM sets name every dump after its title plus tags in square brackets. Most
of those tags describe a variant of the same game, not a different game:

  [o1]..[o4]  overdump   the dumper read more bytes than the cartridge
                         holds, the dump is padded with junk and is
                         superseded by the good dump
  [b1]..[b4]  bad dump   known wrong data (bad checksum, glitches)
  [f1]..[f3]  fixed      the scene repaired header/checksum for an old
                         emulator; current emulators do not need it
  [p1]..[p2]  patched    a user patch was applied, the dump is modified
  [t1]..[t3]  trainer    a cracker intro and cheats were prepended
  [a1]..[a4]  alternate  a different dump/revision of the same game
  [h1]..[h4]  hack       a modified game (levels, characters) - own content
  [T+Ger]     translation a fan translation - own content
  no tag                 a No-Intro style name. No-Intro is the group that
                         verifies dumps against a database, so its names
                         carry no tag; that is the clean dump, not a
                         "version without the intro".

Only the classes passed with --classes are moved, and by default only when
the same title still exists as a clean file in the same directory - a
variant that is the only copy of its title stays where it is (--force moves
those too). Nothing is deleted: the files are moved into an archive
directory that lies outside the ROM tree Kodi lists, so they stay available
and the list gets shorter.

Exit codes: 0 = ok, 1 = technical error, 2 = usage error.

Examples:
  symbios-roms-variant-prune.py --roms /srv/roms/RETRO \\
      --archive /srv/roms/_RETROPIE/dumps/varianten
  symbios-roms-variant-prune.py --roms /srv/roms/RETRO \\
      --archive /srv/roms/_RETROPIE/dumps/varianten --classes ob --apply
"""

import argparse
import os
import re
import shutil
import sys

# Letters that may appear as a variant tag ([o1], [b2], ...) plus the
# classes they stand for, in the order the summary prints them.
CLASS_NAMES = {
    "o": "overdump",
    "b": "bad dump",
    "f": "fixed",
    "p": "patched",
    "t": "trainer",
    "a": "alternate",
    "h": "hack",
}

# A variant tag: one letter of the classes above plus a number, e.g. [o1].
VARIANT_RE = re.compile(r"\[([a-z])(\d+)\]")


def f_markers(f_name):
    """Return the bracket markers of a file name, in order."""
    return VARIANT_RE.findall(f_name)


def f_first_marker(f_name):
    """Return the letter of the first variant tag, or '' when there is none."""
    f_found = f_markers(f_name)
    return f_found[0][0] if f_found else ""


def f_is_clean(f_name):
    """True for a verified or untagged dump ([!] or no variant tag at all)."""
    if not f_markers(f_name):
        return True
    return "[!]" in f_name


def f_base_title(f_name):
    """Title without extension, region and tags - the key that groups variants."""
    f_stem = os.path.splitext(f_name)[0]
    f_cut = [f_pos for f_pos in (f_stem.find("("), f_stem.find("[")) if f_pos >= 0]
    if f_cut:
        f_stem = f_stem[: min(f_cut)]
    return f_stem.strip().lower()


def f_find_systems(f_root):
    """Yield every directory below f_root that holds files directly.

    A ROM tree is usually grouped (arcade/, consoles/nes/, computers/c64/):
    a directory without files of its own is a group and is descended into.
    """
    try:
        f_entries = sorted(os.scandir(f_root), key=lambda f_e: f_e.name)
    except OSError as f_err:
        print(f"Cannot read {f_root}: {f_err}", file=sys.stderr)
        return
    f_files = [f_e for f_e in f_entries if f_e.is_file()]
    if f_files:
        yield f_root
        return
    for f_entry in f_entries:
        if f_entry.is_dir() and not f_entry.is_symlink():
            yield from f_find_systems(f_entry.path)


def f_plan_system(f_dir, f_classes, f_force):
    """Split the files of one system directory into move candidates and skips."""
    f_clean = {}
    f_files = []
    for f_entry in sorted(os.scandir(f_dir), key=lambda f_e: f_e.name):
        if not f_entry.is_file():
            continue
        f_files.append(f_entry)
        if f_is_clean(f_entry.name):
            f_clean.setdefault(f_base_title(f_entry.name), set()).add(f_entry.name)
    f_move, f_only_copy = [], []
    for f_entry in f_files:
        f_letter = f_first_marker(f_entry.name)
        # Empty string is a substring of any class list - check it first.
        if not f_letter or f_letter not in f_classes:
            continue
        # A name that carries [!] next to its variant tag is clean itself, so
        # it must not count as its own replacement ([p1][!] is a single file).
        f_replacement = f_clean.get(f_base_title(f_entry.name), set()) - {f_entry.name}
        if f_force or f_replacement:
            f_move.append(f_entry)
        else:
            f_only_copy.append(f_entry)
    return f_move, f_only_copy


def f_main():
    """Parse the command line, walk the ROM tree and move the variants."""
    f_parser = argparse.ArgumentParser(
        add_help=False,
        description="Move redundant ROM variants (overdumps, bad dumps, ...) "
                    "out of a ROM tree into an archive directory.",
    )
    f_parser.add_argument("--roms", action="append", default=[], metavar="DIR",
                          help="ROM root to scan (repeatable); every directory "
                               "below it that holds files is a system")
    f_parser.add_argument("--archive", metavar="DIR",
                          help="archive directory outside the ROM tree; the "
                               "files land in <archive>/<system>/")
    f_parser.add_argument("--classes", default="ob", metavar="LETTERS",
                          help="variant classes to move: o=overdump, b=bad "
                               "dump, f=fixed, p=patched, t=trainer, "
                               "a=alternate (default: ob)")
    f_parser.add_argument("--force", action="store_true",
                          help="also move variants that are the only copy of "
                               "their title")
    f_parser.add_argument("--apply", action="store_true",
                          help="really move the files (default: dry run)")
    f_parser.add_argument("-h", "--help", action="store_true",
                          help="show this help and exit")
    f_args = f_parser.parse_args()

    if f_args.help:
        print(__doc__)
        return 0
    if not f_args.roms or not f_args.archive:
        f_parser.print_usage(sys.stderr)
        print("Error: --roms and --archive are required.", file=sys.stderr)
        return 2
    f_classes = f_args.classes.strip().lower()
    f_unknown = [f_c for f_c in f_classes if f_c not in CLASS_NAMES]
    if not f_classes or f_unknown:
        f_parser.print_usage(sys.stderr)
        print(f"Error: unknown class(es) {''.join(f_unknown) or '(empty)'}; "
              f"allowed: {''.join(CLASS_NAMES)}", file=sys.stderr)
        return 2

    f_archive = os.path.abspath(f_args.archive)
    for f_root in f_args.roms:
        f_root_abs = os.path.abspath(f_root)
        if not os.path.isdir(f_root_abs):
            print(f"Error: ROM root {f_root_abs} does not exist.", file=sys.stderr)
            return 1
        # An archive below the ROM root would stay visible in Kodi.
        if f_archive == f_root_abs or f_archive.startswith(f_root_abs + os.sep):
            print(f"Error: archive {f_archive} lies inside the ROM root "
                  f"{f_root_abs} - it must stay outside the tree Kodi lists.",
                  file=sys.stderr)
            return 1

    print(f"Classes: {', '.join(f'{f_c}={CLASS_NAMES[f_c]}' for f_c in f_classes)}"
          f" | archive: {f_archive} | mode: "
          f"{'apply' if f_args.apply else 'dry run'}")
    print(f"{'system':<16}{'variants':>9}{'move':>7}{'only copy':>11}{'GB':>8}")

    f_total_move = f_total_keep = 0
    f_total_bytes = 0
    f_conflicts = 0
    for f_root in f_args.roms:
        for f_system in f_find_systems(os.path.abspath(f_root)):
            f_move, f_only_copy = f_plan_system(f_system, f_classes, f_args.force)
            if not f_move and not f_only_copy:
                continue
            f_bytes = sum(f_e.stat().st_size for f_e in f_move)
            print(f"{os.path.basename(f_system):<16}{len(f_move) + len(f_only_copy):>9}"
                  f"{len(f_move):>7}{len(f_only_copy):>11}{f_bytes / 2 ** 30:>8.2f}")
            f_total_move += len(f_move)
            f_total_keep += len(f_only_copy)
            f_total_bytes += f_bytes
            if not f_args.apply:
                continue
            f_target_dir = os.path.join(f_archive, os.path.basename(f_system))
            os.makedirs(f_target_dir, exist_ok=True)
            for f_entry in f_move:
                f_target = os.path.join(f_target_dir, f_entry.name)
                if os.path.exists(f_target):
                    print(f"  conflict, kept both: {f_entry.name}", file=sys.stderr)
                    f_conflicts += 1
                    continue
                try:
                    shutil.move(f_entry.path, f_target)
                except OSError as f_err:
                    print(f"  move failed: {f_entry.name}: {f_err}", file=sys.stderr)
                    return 1

    print(f"{'SUM':<16}{f_total_move + f_total_keep:>9}{f_total_move:>7}"
          f"{f_total_keep:>11}{f_total_bytes / 2 ** 30:>8.2f}")
    if f_total_keep:
        print("Kept in place: no clean copy of the same title exists "
              "(--force moves those too).")
    print(f"roms-variant-prune: moved={f_total_move} "
          f"only_copy={f_total_keep} conflicts={f_conflicts} "
          f"mode={'apply' if f_args.apply else 'dry-run'}")
    return 0


if __name__ == "__main__":
    sys.exit(f_main())
