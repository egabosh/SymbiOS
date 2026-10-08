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
# symbios-inventory.py - The ONLY host-side writer of inventory.yml.
#
# All symbios-settings-*.sh scripts validate their domain and then call
# this CLI for the actual YAML write. It knows NO domains, NO playbooks and
# NO validation beyond generic YAML types - domain logic lives in the
# calling bash script. No Django dependencies, runs on plain host python3
# with PyYAML (both guaranteed present, Ansible needs them too).
#
# Writes are transactional (one load/merge/dump cycle), atomic (tmp file +
# fsync + os.replace) and keep a .bak of the last good version - the same
# guarantees as _save_inventory_config in webui/main/views.py.
#
# Secrets MUST NEVER travel as argv (visible in ps): use `merge` with a
# JSON object on stdin instead of `set` for secret values.

import argparse
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("symbios-inventory.py: PyYAML is required (python3-yaml)", file=sys.stderr)
    sys.exit(1)

DEFAULT_INVENTORY = "/symbios/base-services/symbios-ui/config/inventory.yml"
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def e_usage(msg):
    """Print a validation error and exit 2."""
    print("symbios-inventory.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(2)


def e_technical(msg):
    """Print a technical error and exit 1."""
    print("symbios-inventory.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(1)


def check_key(key):
    """Validate an inventory variable name, exit 2 when invalid."""
    if not KEY_RE.match(key or ""):
        e_usage("invalid variable name: {!r} (must match {})".format(key, KEY_RE.pattern))


def load_inventory(path):
    """Load inventory.yml, return the config dict (exit 1 on failure)."""
    try:
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        e_technical("inventory file not found: {}".format(path))
    except yaml.YAMLError as e:
        e_technical("cannot parse {}: {}".format(path, e))
    except OSError as e:
        e_technical("cannot read {}: {}".format(path, e))


def write_inventory(path, cfg, check_only):
    """Write back atomically with .bak backup (or report only with check)."""
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
            yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError as e:
        e_technical("cannot write {}: {}".format(path, e))


def fmt_value(value):
    """Format a scalar for human-readable output."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


def is_storable(value):
    """Check a merge value holds only generic YAML types."""
    if value is None or isinstance(value, (str, bool, int, float)):
        return True
    if isinstance(value, list):
        return all(is_storable(item) for item in value)
    if isinstance(value, dict):
        return all(isinstance(k, str) and is_storable(v)
                   for k, v in value.items())
    return False


def cmd_get(args):
    """Print a single all.vars value (lists: one item per line, or JSON)."""
    check_key(args.key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.get("all", {}).get("vars", {}) or {}
    if args.key not in vars_ or vars_[args.key] is None:
        e_technical("key not set: {}".format(args.key))
    value = vars_[args.key]
    if args.json:
        print(json.dumps(value))
        return
    if isinstance(value, list):
        for item in value:
            print(fmt_value(item))
        return
    print(fmt_value(value))


def apply_changes(vars_, changes):
    """Merge changes into vars_; None values delete the key.

    Returns the list of human-readable change lines.
    """
    lines = []
    for key, value in changes:
        check_key(key)
        if value is None:
            if key in vars_:
                del vars_[key]
                lines.append("deleted {}".format(key))
        else:
            if key not in vars_ or vars_[key] != value:
                vars_[key] = value
                if isinstance(value, (list, dict)):
                    lines.append("set {}={}".format(key, json.dumps(value)))
                else:
                    lines.append("set {}={}".format(key, fmt_value(value)))
    return lines


def cmd_set(args):
    """Store one string value (non-string types go through merge)."""
    check_key(args.key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    lines = apply_changes(vars_, [(args.key, args.value)])
    if not lines:
        print("unchanged")
        return
    write_inventory(args.inventory, cfg, args.check)
    for line in lines:
        print(line)
    if args.check:
        print("(check mode - nothing was written)")


def cmd_merge(args):
    """Merge a JSON object from stdin in one transaction (null deletes)."""
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    if not isinstance(data, dict):
        e_usage("stdin must hold a JSON object, got {}".format(type(data).__name__))
    for key in data:
        check_key(key)
        if not is_storable(data[key]):
            e_usage("unsupported type for key {!r}: only strings, booleans, "
                    "numbers, lists and string-keyed dicts of those can be "
                    "stored".format(key))
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    lines = apply_changes(vars_, list(data.items()))
    if not lines:
        print("unchanged")
        return
    write_inventory(args.inventory, cfg, args.check)
    for line in lines:
        print(line)
    if args.check:
        print("(check mode - nothing was written)")


def cmd_del(args):
    """Delete one key (idempotent: missing keys report unchanged)."""
    check_key(args.key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    lines = apply_changes(vars_, [(args.key, None)])
    if not lines:
        print("unchanged")
        return
    write_inventory(args.inventory, cfg, args.check)
    for line in lines:
        print(line)
    if args.check:
        print("(check mode - nothing was written)")


def get_dict(vars_, name):
    """Return the named dict from vars_ (missing -> {}, wrong type -> exit 2)."""
    value = vars_.get(name)
    if value is None:
        return {}
    if not isinstance(value, dict):
        e_usage("key {!r} is not a dict".format(name))
    return value


def cmd_dict_get(args):
    """Print one dict entry as JSON (exit 1 when missing)."""
    check_key(args.dict_key)
    check_key(args.key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.get("all", {}).get("vars", {}) or {}
    entry = get_dict(vars_, args.dict_key).get(args.key)
    if entry is None:
        e_technical("entry not set: {}.{}".format(args.dict_key, args.key))
    print(json.dumps(entry))


def cmd_dict_set(args):
    """Set one dict entry from a JSON value on stdin (creates the dict)."""
    check_key(args.dict_key)
    check_key(args.key)
    try:
        raw = sys.stdin.read()
        value = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    if value is None:
        e_usage("stdin must hold a JSON value, got empty input")
    if not is_storable(value):
        e_usage("unsupported type: only strings, booleans, numbers, lists "
                "and string-keyed dicts of those can be stored")
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    changed = get_dict(vars_, args.dict_key).get(args.key) != value
    vars_.setdefault(args.dict_key, {})[args.key] = value
    if not changed:
        print("unchanged")
        return
    write_inventory(args.inventory, cfg, args.check)
    print("set {}.{}={}".format(args.dict_key, args.key,
                                json.dumps(value)))
    if args.check:
        print("(check mode - nothing was written)")


def cmd_dict_merge(args):
    """Merge a JSON object from stdin into one dict entry (creates it)."""
    check_key(args.dict_key)
    check_key(args.key)
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    if not isinstance(data, dict):
        e_usage("stdin must hold a JSON object, got {}".format(type(data).__name__))
    for key in data:
        if not isinstance(key, str) or not is_storable(data[key]):
            e_usage("unsupported entry for key {!r}".format(key))
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    entry = get_dict(vars_, args.dict_key).get(args.key, {})
    if not isinstance(entry, dict):
        e_usage("entry {}.{} is not a dict".format(args.dict_key, args.key))
    merged = dict(entry)
    merged.update(data)
    if merged == entry and args.key in get_dict(vars_, args.dict_key):
        print("unchanged")
        return
    vars_.setdefault(args.dict_key, {})[args.key] = merged
    write_inventory(args.inventory, cfg, args.check)
    print("set {}.{}={}".format(args.dict_key, args.key,
                                json.dumps(merged)))
    if args.check:
        print("(check mode - nothing was written)")


def cmd_dict_keys(args):
    """Print the keys of a dict, one per line (missing dict: no output)."""
    check_key(args.dict_key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.get("all", {}).get("vars", {}) or {}
    for key in get_dict(vars_, args.dict_key):
        print(key)


def cmd_dict_show(args):
    """Print a string-valued dict as k=v lines (missing dict: no output)."""
    check_key(args.dict_key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.get("all", {}).get("vars", {}) or {}
    for key, value in get_dict(vars_, args.dict_key).items():
        print("{}={}".format(key, fmt_value(value) if value is not None else ""))


def get_list(vars_, name):
    """Return the named list from vars_ (missing -> [], wrong type -> exit 2)."""
    value = vars_.get(name)
    if value is None:
        return []
    if not isinstance(value, list):
        e_usage("key {!r} is not a list".format(name))
    return value


def read_stdin_value():
    """Read one JSON value from stdin (empty input or null -> exit 2)."""
    try:
        raw = sys.stdin.read()
        value = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    if value is None:
        e_usage("stdin must hold a JSON value, got empty input")
    if not is_storable(value):
        e_usage("unsupported type: only strings, booleans, numbers, lists "
                "and string-keyed dicts of those can be stored")
    return value


def cmd_list_add(args):
    """Append a stdin JSON value to a list unless already present."""
    check_key(args.key)
    value = read_stdin_value()
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    items = get_list(vars_, args.key)
    if value in items:
        print("unchanged")
        return
    vars_.setdefault(args.key, []).append(value)
    write_inventory(args.inventory, cfg, args.check)
    print("added {}={}".format(args.key, json.dumps(value)))
    if args.check:
        print("(check mode - nothing was written)")


def cmd_list_del(args):
    """Remove all stdin-JSON-equal entries from a list (idempotent)."""
    check_key(args.key)
    value = read_stdin_value()
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    items = get_list(vars_, args.key)
    kept = [item for item in items if item != value]
    if len(kept) == len(items):
        print("unchanged")
        return
    vars_[args.key] = kept
    write_inventory(args.inventory, cfg, args.check)
    print("deleted {}={}".format(args.key, json.dumps(value)))
    if args.check:
        print("(check mode - nothing was written)")


def cmd_dict_del(args):
    """Delete one dict entry (idempotent: missing entries report unchanged)."""
    check_key(args.dict_key)
    check_key(args.key)
    cfg = load_inventory(args.inventory)
    vars_ = cfg.setdefault("all", {}).setdefault("vars", {})
    d = get_dict(vars_, args.dict_key)
    if args.key not in d:
        print("unchanged")
        return
    del d[args.key]
    write_inventory(args.inventory, cfg, args.check)
    print("deleted {}.{}".format(args.dict_key, args.key))
    if args.check:
        print("(check mode - nothing was written)")


def main(argv=None):
    """Parse arguments and dispatch to the subcommand, return exit code."""
    parser = argparse.ArgumentParser(
        prog="symbios-inventory.py",
        description="The ONLY host-side writer of inventory.yml. "
                    "Reads/writes scalars under all.vars. Domain validation "
                    "lives in the calling symbios-settings-*.sh script, not here.",
        epilog="Examples:\n"
               "  symbios-inventory.py get timezone\n"
               "  symbios-inventory.py set timezone Europe/Berlin\n"
               "  echo '{\"timezone\": \"Europe/Berlin\", \"ai_server\": null}' \\\n"
               "    | symbios-inventory.py merge\n"
               "  symbios-inventory.py del ai_apikey\n"
               "\nExit codes: 0 ok/unchanged, 2 usage or validation error, "
               "1 technical error.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--inventory", default=os.environ.get("SYMBIOS_INVENTORY", DEFAULT_INVENTORY),
                        help="path to inventory.yml (default: %(default)s)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_get = sub.add_parser("get", help="print one all.vars value")
    p_get.add_argument("key", help="variable name under all.vars")
    p_get.add_argument("--json", action="store_true",
                       help="print the value as JSON (needed for lists)")
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="store one string value")
    p_set.add_argument("key", help="variable name under all.vars")
    p_set.add_argument("value", help="string value (non-string types: use merge)")
    p_set.add_argument("--check", action="store_true",
                       help="report what would change, change nothing")
    p_set.set_defaults(func=cmd_set)

    p_merge = sub.add_parser("merge", help="merge a JSON object from stdin (null deletes the key)")
    p_merge.add_argument("--check", action="store_true",
                         help="report what would change, change nothing")
    p_merge.set_defaults(func=cmd_merge)

    p_del = sub.add_parser("del", help="delete one key (idempotent)")
    p_del.add_argument("key", help="variable name under all.vars")
    p_del.add_argument("--check", action="store_true",
                       help="report what would change, change nothing")
    p_del.set_defaults(func=cmd_del)

    p_dget = sub.add_parser("dict-get", help="print one dict entry as JSON")
    p_dget.add_argument("dict_key", help="dict variable name under all.vars")
    p_dget.add_argument("key", help="entry key inside the dict")
    p_dget.set_defaults(func=cmd_dict_get)

    p_dset = sub.add_parser("dict-set", help="set one dict entry from a JSON value on stdin")
    p_dset.add_argument("dict_key", help="dict variable name under all.vars")
    p_dset.add_argument("key", help="entry key inside the dict")
    p_dset.add_argument("--check", action="store_true",
                        help="report what would change, change nothing")
    p_dset.set_defaults(func=cmd_dict_set)

    p_ddel = sub.add_parser("dict-del", help="delete one dict entry (idempotent)")
    p_ddel.add_argument("dict_key", help="dict variable name under all.vars")
    p_ddel.add_argument("key", help="entry key inside the dict")
    p_ddel.add_argument("--check", action="store_true",
                        help="report what would change, change nothing")
    p_ddel.set_defaults(func=cmd_dict_del)

    p_dmerge = sub.add_parser("dict-merge", help="merge a JSON object from stdin into one dict entry")
    p_dmerge.add_argument("dict_key", help="dict variable name under all.vars")
    p_dmerge.add_argument("key", help="entry key inside the dict")
    p_dmerge.add_argument("--check", action="store_true",
                          help="report what would change, change nothing")
    p_dmerge.set_defaults(func=cmd_dict_merge)

    p_dkeys = sub.add_parser("dict-keys", help="print the keys of a dict, one per line")
    p_dkeys.add_argument("dict_key", help="dict variable name under all.vars")
    p_dkeys.set_defaults(func=cmd_dict_keys)

    p_dshow = sub.add_parser("dict-show", help="print a string-valued dict as k=v lines")
    p_dshow.add_argument("dict_key", help="dict variable name under all.vars")
    p_dshow.set_defaults(func=cmd_dict_show)

    p_ladd = sub.add_parser("list-add", help="append a stdin JSON value to a list unless present")
    p_ladd.add_argument("key", help="list variable name under all.vars")
    p_ladd.add_argument("--check", action="store_true",
                        help="report what would change, change nothing")
    p_ladd.set_defaults(func=cmd_list_add)

    p_ldel = sub.add_parser("list-del", help="remove stdin-JSON-equal entries from a list")
    p_ldel.add_argument("key", help="list variable name under all.vars")
    p_ldel.add_argument("--check", action="store_true",
                        help="report what would change, change nothing")
    p_ldel.set_defaults(func=cmd_list_del)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
