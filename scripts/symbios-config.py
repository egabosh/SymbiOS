#!/usr/bin/env python3
# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# symbios-config.py - Generic YAML document engine for config-dir files.
#
# Sibling of symbios-inventory.py (which owns inventory.yml exclusively).
# This CLI owns every OTHER writable YAML file below the SymbiOS config
# dir: service instances (services/<name>/instances.yml), feature state
# (services/<name>/features-state.yml), external systems, and future
# per-domain files. Same guarantees: transactional, atomic (tmp file +
# fsync + os.replace) + .bak of the last good version.
#
# Path jail: --file must be relative and stay below --config-dir
# (absolute paths and ".." are rejected with exit 2), so no caller can
# reach outside the config tree. Domain validation (schemas, required
# fields) lives in the calling script or view - this engine only knows
# generic YAML shapes, never domains. No Django dependencies.

import argparse
import contextlib
import fcntl
import json
import os
import sys

try:
    import yaml
except ImportError:
    print("symbios-config.py: PyYAML is required (python3-yaml)", file=sys.stderr)
    sys.exit(1)

DEFAULT_CONFIG_DIR = "/symbios/base-services/symbios-ui/config"


def e_usage(msg):
    """Print a validation error and exit 2."""
    print("symbios-config.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(2)


def e_technical(msg):
    """Print a technical error and exit 1."""
    print("symbios-config.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(1)


def ensure_parent(path):
    """Create the parent dir (idempotent, safe outside the lock)."""
    try:
        parent = os.path.dirname(path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
    except OSError as e:
        e_technical("cannot create dir for {}: {}".format(path, e))


@contextlib.contextmanager
def locked(path):
    """Hold an exclusive lock file across load/modify/write (see
    symbios-inventory.py: locking only the write still loses updates)."""
    try:
        lock = open(path + ".lock", "w")
    except OSError as e:
        e_technical("cannot lock {}: {}".format(path, e))
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
    except OSError as e:
        e_technical("cannot lock {}: {}".format(path, e))
    try:
        yield
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except OSError:
            pass
        lock.close()


def resolve_path(config_dir, rel):
    """Jail a relative file path below the config dir (exit 2 on escape)."""
    if not rel or os.path.isabs(rel):
        e_usage("file must be a relative path, got {!r}".format(rel))
    path = os.path.normpath(os.path.join(config_dir, rel))
    base = os.path.normpath(config_dir)
    if path != base and not path.startswith(base + os.sep):
        e_usage("file escapes the config dir: {!r}".format(rel))
    if path == base:
        e_usage("file must not be the config dir itself")
    return path


def load_doc(path):
    """Load a YAML document (missing file -> None, broken YAML -> exit 1)."""
    try:
        with open(path) as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        return None
    except yaml.YAMLError as e:
        e_technical("cannot parse {}: {}".format(path, e))
    except OSError as e:
        e_technical("cannot read {}: {}".format(path, e))


def write_doc(path, doc, check_only):
    """Write back atomically with .bak backup (or report only with check).

    Caller MUST hold locked(path): the load happened under the same lock.
    """
    if check_only:
        return
    try:
        if os.path.exists(path):
            with open(path) as f:
                old = f.read()
            with open(path + ".bak", "w") as b:
                b.write(old)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            yaml.dump(doc, f, default_flow_style=False, sort_keys=False,
                      allow_unicode=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError as e:
        e_technical("cannot write {}: {}".format(path, e))


def deep_merge(base, overlay):
    """Recursively merge overlay dict into base dict (scalars/lists win)."""
    out = dict(base)
    for key, value in overlay.items():
        if (key in out and isinstance(out[key], dict)
                and isinstance(value, dict)):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def cmd_get(args):
    """Print the document (raw YAML, or JSON with --json)."""
    path = resolve_path(args.config_dir, args.file)
    doc = load_doc(path)
    if doc is None:
        e_technical("file not found: {}".format(args.file))
    if args.json:
        print(json.dumps(doc))
    else:
        print(yaml.dump(doc, default_flow_style=False, sort_keys=False,
                        allow_unicode=True), end="")


def cmd_write(args):
    """Replace the document with YAML from stdin (any shape, must parse)."""
    path = resolve_path(args.config_dir, args.file)
    try:
        raw = sys.stdin.read()
        doc = yaml.safe_load(raw) if raw.strip() else None
    except yaml.YAMLError as e:
        e_usage("invalid YAML on stdin: {}".format(e))
    if doc is None:
        e_usage("stdin must hold a YAML document, got empty input")
    ensure_parent(path)
    with locked(path):
        old = load_doc(path)
        if doc == old:
            print("unchanged")
            return
        write_doc(path, doc, args.check)
    print("wrote {} ({} top-level {})".format(
        args.file,
        len(doc) if isinstance(doc, (dict, list)) else 1,
        "entries" if isinstance(doc, list) else "keys"))
    if args.check:
        print("(check mode - nothing was written)")


def cmd_merge(args):
    """Deep-merge a JSON object from stdin into a mapping document."""
    path = resolve_path(args.config_dir, args.file)
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    if not isinstance(data, dict):
        e_usage("stdin must hold a JSON object, got {}".format(type(data).__name__))
    ensure_parent(path)
    with locked(path):
        old = load_doc(path)
        if old is None:
            old = {}
        if not isinstance(old, dict):
            e_usage("existing {} is not a mapping".format(args.file))
        merged = deep_merge(old, data)
        if merged == old:
            print("unchanged")
            return
        write_doc(path, merged, args.check)
        print("merged {} ({} keys)".format(args.file, len(data)))
        if args.check:
            print("(check mode - nothing was written)")


def main(argv=None):
    """Parse arguments and dispatch to the subcommand, return exit code."""
    parser = argparse.ArgumentParser(
        prog="symbios-config.py",
        description="Generic YAML document engine for files below the "
                    "SymbiOS config dir (instances, feature state, external "
                    "systems, ...). Sibling of symbios-inventory.py, which "
                    "owns inventory.yml exclusively. Domain validation lives "
                    "in the caller, never here.",
        epilog="Examples:\n"
               "  symbios-config.py --file services/wp/instances.yml get --json\n"
               "  symbios-config.py --file services/wp/instances.yml write < rows.yml\n"
               "  echo '{\"feat\": {\"enabled\": true}}' | symbios-config.py \\\n"
               "    --file services/openwrt-vm/features-state.yml merge\n"
               "\nExit codes: 0 ok/unchanged, 2 usage or validation error, "
               "1 technical error.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--config-dir",
                        default=os.environ.get("SYMBIOS_CONFIG", DEFAULT_CONFIG_DIR),
                        help="config dir jail (default: %(default)s)")
    parser.add_argument("--file", required=True,
                        help="relative path below the config dir")
    sub = parser.add_subparsers(dest="command", required=True)

    p_get = sub.add_parser("get", help="print the document (raw YAML)")
    p_get.add_argument("--json", action="store_true",
                       help="print the document as JSON")
    p_get.set_defaults(func=cmd_get)

    p_write = sub.add_parser("write", help="replace the document with YAML from stdin")
    p_write.add_argument("--check", action="store_true",
                         help="report what would change, change nothing")
    p_write.set_defaults(func=cmd_write)

    p_merge = sub.add_parser("merge", help="deep-merge a JSON object from stdin")
    p_merge.add_argument("--check", action="store_true",
                         help="report what would change, change nothing")
    p_merge.set_defaults(func=cmd_merge)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
