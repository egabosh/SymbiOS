#!/usr/bin/env python3
"""Repack a chip dump into per-set zip archives for the FBNeo libretro core.

FBNeo opens one archive per game (need_fullpath, valid_extensions zip|7z) and
looks for the individual ROM chips inside it by name and CRC32. A RetroPie
style dump stores the chips as loose files in one directory (for example
roms/neogeo/201-p1.bin, 201-c1.bin, ...), so the core cannot load it as is.

This tool reads the set definitions (BurnRomInfo arrays) from an FBNeo driver
source, indexes the dump by CRC32, and writes one <set>.zip per set whose chips
are all present. The BIOS set (neogeo) is written as neogeo.zip next to the
games, where FBNeo expects it.

Chips are matched by CRC32, not by file name: the dump may use .bin while the
driver lists .p1/.c1, the content is what counts.

Exit codes: 0 = ok (also when nothing was complete), 1 = technical error,
2 = usage error.

Example:
  symbios-fbneo-repack.py --roms /srv/roms/neogeo --out /srv/roms/arcade
  symbios-fbneo-repack.py --roms /srv/roms/neogeo --out /srv/roms/arcade --dry-run
"""

import argparse
import os
import re
import sys
import zipfile
import zlib

# Default location of the driver source in a source-built FBNeo checkout (the
# kodi playbook builds it into the service dir).
DEFAULT_FBNEO_SRC = "/symbios/services/kodi/src/FBNeo"
DEFAULT_DRIVER = "src/burn/drv/neogeo/d_neogeo.cpp"

# One "struct BurnRomInfo <set>RomDesc[] = { ... };" block per set.
SET_RE = re.compile(r"struct\s+BurnRomInfo\s+(\w+)RomDesc\[\]\s*=\s*\{(.*?)\n\};", re.S)

# The driver block maps the struct prefix to the actual set name: C++ cannot
# start an identifier with a digit, so 2020bb lives in bb2020RomDesc.
DRIVER_RE = re.compile(
    r'struct\s+BurnDriver\s+\w+\s*=\s*\{\s*"([^"]+)"[^;]*?\b(\w+)RomInfo\b', re.S
)

# One "{ "name", size, crc, flags }" entry inside such a block.
ENTRY_RE = re.compile(
    r'\{\s*"([^"]*)"\s*,\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*([^}]*)\}'
)


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


def f_read_sets(f_driver):
    """Parse the driver source into {set: [(name, size, crc, optional), ...]}."""
    with open(f_driver, "r", encoding="utf-8", errors="replace") as f_handle:
        f_source = f_handle.read()

    # Struct prefix -> set name, taken from the driver blocks.
    f_names = {f_desc: f_set for f_set, f_desc in DRIVER_RE.findall(f_source)}

    f_sets = {}
    for f_desc, f_body in SET_RE.findall(f_source):
        f_roms = []
        for f_name, f_size, f_crc, f_flags in ENTRY_RE.findall(f_body):
            f_size = int(f_size, 0)
            f_crc = int(f_crc, 0)
            # Placeholder entries carry no name, size or checksum.
            if not f_name or f_size == 0 or f_crc == 0:
                continue
            # BRF_OPT marks a chip the driver runs without (additional BIOS
            # regions, alternate revisions): take it when the dump has it.
            f_roms.append((f_name, f_size, f_crc, "BRF_OPT" in f_flags))
        if f_roms:
            f_sets[f_names.get(f_desc, f_desc)] = f_roms
    return f_sets


def f_index_dump(f_root):
    """Index every file below the dump root by CRC32 -> [(path, size), ...]."""
    f_by_crc = {}
    for f_dir, _f_dirs, f_files in os.walk(f_root):
        for f_file in f_files:
            f_path = os.path.join(f_dir, f_file)
            try:
                f_size = os.path.getsize(f_path)
                if f_size == 0:
                    continue
                f_crc = f_crc32(f_path)
            except OSError as f_error:
                print(f"warning: skipping {f_path}: {f_error}", file=sys.stderr)
                continue
            f_by_crc.setdefault(f_crc, []).append((f_path, f_size))
    return f_by_crc


def f_pick(f_roms, f_by_crc):
    """Match a set's ROM list against the dump.

    Returns (picked, missing): the [(name, path)] chips to store and the names
    of the mandatory chips the dump does not have."""
    f_picked = []
    f_missing = []
    for f_name, f_size, f_crc, f_optional in f_roms:
        # Prefer a candidate with the expected size, in case a dump file
        # collides on the checksum (a truncated or padded copy).
        f_match = next((c for c in f_by_crc.get(f_crc, []) if c[1] == f_size), None)
        if f_match is None:
            if not f_optional:
                f_missing.append(f"{f_name} ({f_crc:08x})")
            continue
        f_picked.append((f_name, f_match[0]))
    return f_picked, f_missing


def f_write_zip(f_target, f_picked):
    """Write one set archive with the chip names the driver expects."""
    f_tmp = f_target + ".part"
    with zipfile.ZipFile(f_tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as f_zip:
        for f_name, f_path in f_picked:
            f_zip.write(f_path, arcname=f_name)
    os.replace(f_tmp, f_target)


def main():
    f_parser = argparse.ArgumentParser(
        description="Repack a chip dump into per-set zips for FBNeo.",
        epilog="Chips are matched by CRC32, so .bin/.p1 naming does not matter.",
    )
    f_parser.add_argument(
        "--roms", required=True, help="chip dump directory (read only)"
    )
    f_parser.add_argument("--out", required=True, help="target directory for the zips")
    f_parser.add_argument(
        "--fbneo-src",
        default=DEFAULT_FBNEO_SRC,
        help=f"FBNeo checkout (default: {DEFAULT_FBNEO_SRC})",
    )
    f_parser.add_argument(
        "--driver",
        help=f"driver source below the checkout (default: {DEFAULT_DRIVER})",
    )
    f_parser.add_argument(
        "--sets",
        help="comma separated set list (default: every set of the driver)",
    )
    f_parser.add_argument(
        "--force", action="store_true", help="rebuild archives that already exist"
    )
    f_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be written, write nothing",
    )
    f_args = f_parser.parse_args()

    # Resolve the driver source: an explicit file wins over the checkout.
    f_driver = f_args.driver or os.path.join(f_args.fbneo_src, DEFAULT_DRIVER)
    if not os.path.isfile(f_driver):
        print(f"error: driver source not found: {f_driver}", file=sys.stderr)
        return 1
    if not os.path.isdir(f_args.roms):
        print(f"error: dump directory not found: {f_args.roms}", file=sys.stderr)
        return 1

    # Read the set definitions and, when asked, narrow them down.
    f_sets = f_read_sets(f_driver)
    if not f_sets:
        print(f"error: no set definitions found in {f_driver}", file=sys.stderr)
        return 1
    if f_args.sets:
        f_wanted = [s.strip() for s in f_args.sets.split(",") if s.strip()]
        f_unknown = [s for s in f_wanted if s not in f_sets]
        if f_unknown:
            print(f"error: unknown set(s): {', '.join(f_unknown)}", file=sys.stderr)
            return 2
        f_sets = {s: f_sets[s] for s in f_wanted}

    # The BIOS archive goes first: the games need it in the same directory.
    f_order = sorted(f_sets, key=lambda s: (s != "neogeo", s))

    f_by_crc = f_index_dump(f_args.roms)
    print(f"dump: {len(f_by_crc)} distinct checksums in {f_args.roms}")

    if not f_args.dry_run:
        os.makedirs(f_args.out, exist_ok=True)

    f_written = 0
    f_skipped = 0
    f_incomplete = 0
    for f_set in f_order:
        f_picked, f_missing = f_pick(f_sets[f_set], f_by_crc)
        if f_missing or not f_picked:
            f_incomplete += 1
            print(f"incomplete: {f_set}: missing {', '.join(f_missing) or 'no chip'}")
            continue

        f_target = os.path.join(f_args.out, f_set + ".zip")
        if os.path.exists(f_target) and not f_args.force:
            f_skipped += 1
            print(f"exists: {f_set}")
            continue

        if f_args.dry_run:
            f_written += 1
            print(f"would write: {f_target} ({len(f_picked)} chips)")
            continue

        f_write_zip(f_target, f_picked)
        f_written += 1
        print(f"wrote: {f_target} ({len(f_picked)} chips)")

    print(
        f"sets: {len(f_order)}, written: {f_written}, "
        f"already present: {f_skipped}, incomplete: {f_incomplete}"
    )
    print("fbneo-repack-done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
