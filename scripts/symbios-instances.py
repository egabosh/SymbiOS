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
# symbios-instances.py - Schema-aware manager for per-service instance lists.
#
# Services with a docs.config block (e.g. WordPress, Nextcloud) store their
# instance rows in <config>/services/<name>/instances.yml. This CLI reads
# the field schema from the playbook's "# docs:" block in the git repo
# (same source the WebUI catalog parses - single source of truth),
# coerces stdin JSON rows against it (bool/number/list/text + patterns,
# same rules webui/main/service_instances.py enforced), and delegates the
# atomic write to symbios-config.py. Reads stay cheap in the WebUI
# container (read-only /config mount); writes go through here.
#
# Only base-system settings belong into inventory.yml; instance lists are
# service data and live in the config dir instead.

import argparse
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("symbios-instances.py: PyYAML is required (python3-yaml)", file=sys.stderr)
    sys.exit(1)

DEFAULT_GIT_ROOT = "/symbios/git/SymbiOS"
DEFAULT_CONFIG_DIR = "/symbios/base-services/symbios-ui/config"

_BOOL_TYPES = {"bool", "boolean", "checkbox"}
_NUMBER_TYPES = {"number", "int", "float"}
_LIST_TYPES = {"list"}


def e_usage(msg):
    """Print a validation error and exit 2."""
    print("symbios-instances.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(2)


def e_technical(msg):
    """Print a technical error and exit 1."""
    print("symbios-instances.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(1)


def get_service_name(playbook):
    """Return the service dir name for services/<svc>.yml (mirrors the WebUI)."""
    base = playbook.rsplit("/", 1)[-1]
    return base[:-4] if base.endswith(".yml") else base


def load_docs_config(git_root, playbook):
    """Parse the docs.config block from the playbook (mirrors playbook_catalog).

    Returns (service, file_rel, fields) or exits 2 when absent/unreadable.
    """
    if os.path.isabs(playbook) or ".." in playbook.split("/"):
        e_usage("playbook must be repo-relative, got {!r}".format(playbook))
    path = os.path.normpath(os.path.join(git_root, playbook))
    base = os.path.normpath(git_root)
    if path != base and not path.startswith(base + os.sep):
        e_usage("playbook escapes the repo: {!r}".format(playbook))
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError as e:
        e_technical("cannot read playbook {}: {}".format(playbook, e))
    comment_lines = []
    in_block = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            in_block = True
            comment_lines.append(line)
        elif in_block and stripped == "":
            continue
        elif in_block:
            break
    yaml_lines = []
    in_docs = False
    for line in comment_lines:
        content = line[2:] if line.startswith("# ") else line[1:]
        if not in_docs:
            if content.startswith("docs:"):
                in_docs = True
                yaml_lines.append(content)
        else:
            yaml_lines.append(content)
    if not yaml_lines:
        e_usage("playbook {} declares no # docs: block".format(playbook))
    try:
        docs = yaml.safe_load("\n".join(yaml_lines)) or {}
    except yaml.YAMLError as e:
        e_technical("cannot parse # docs: block in {}: {}".format(playbook, e))
    meta = (docs.get("docs") or {}).get("config")
    if not meta:
        e_usage("playbook {} declares no docs.config block".format(playbook))
    svc = get_service_name(playbook)
    file_rel = meta.get("file") or "services/%s/instances.yml" % svc
    raw_fields = meta.get("fields") or {}
    fields = {}
    items = raw_fields if isinstance(raw_fields, dict) else {}
    if isinstance(raw_fields, list):
        items = {}
        for f in raw_fields:
            if isinstance(f, dict) and f.get("name"):
                items[f["name"]] = f
    for name, raw in items.items():
        raw = raw if isinstance(raw, dict) else {"label": raw or name}
        fields[name] = {
            "name": name,
            "label": raw.get("label") or name,
            "type": str(raw.get("type") or "text").lower(),
            "required": bool(raw.get("required")),
            "placeholder": raw.get("placeholder") or "",
            "pattern": raw.get("pattern") or "",
            "options": raw.get("options") or [],
            "default": raw.get("default"),
            "separator": raw.get("separator") or ",",
        }
    return svc, file_rel, fields


def coerce_row(fields, raw_row):
    """Validate and coerce one row (same rules as the WebUI before).

    Returns (row, error). Rows hold only defined fields with YAML-safe
    values; bool fields are always present.
    """
    row = {}
    for fname, spec in fields.items():
        raw = raw_row.get(fname, "")
        ftype = spec["type"]
        if ftype in _BOOL_TYPES:
            # NOTE: an absent/empty bool reads as True (checkbox quirk,
            # inherited verbatim from the retired WebUI coerce_row). A
            # round-trip can therefore add a missing bool key as true;
            # playbooks default missing bools to false, so prefer
            # explicit values in docs.config defaults.
            row[fname] = raw in (True, "true", "1", "on", "yes") or raw == ""
            continue
        if ftype in _NUMBER_TYPES:
            if raw in ("", None):
                row[fname] = None
                continue
            try:
                row[fname] = float(raw) if ftype == "float" else int(raw)
            except (ValueError, TypeError):
                return None, "%s: '%s' is not a number" % (spec["label"], raw)
            continue
        if ftype in _LIST_TYPES:
            values = []
            if isinstance(raw, list):
                values = [str(v).strip() for v in raw if str(v).strip()]
            else:
                for part in str(raw or "").split(spec["separator"]):
                    part = part.strip()
                    if part:
                        values.append(part)
            row[fname] = values
            continue
        value = str(raw or "").strip()
        if spec["required"] and not value:
            return None, "%s is required" % spec["label"]
        pattern = spec.get("pattern")
        if value and pattern:
            try:
                if (not re.match(pattern + "$", value)
                        and not re.match("^(" + pattern + ")$", value)
                        and not re.match("^" + pattern + "$", value)):
                    return None, "%s does not match %s" % (spec["label"], pattern)
            except re.error:
                pass
        if value or spec["required"]:
            row[fname] = value
    return row, None


def engine(args, sub_args, stdin_data=None):
    """Run symbios-config.py from the same dir, return (ok, out, err)."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "symbios-config.py")
    cmd = [script, "--config-dir", args.config_dir] + sub_args
    try:
        proc = subprocess.run(cmd, input=stdin_data, capture_output=True,
                              text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        e_technical("cannot run symbios-config.py: {}".format(e))
    return proc.returncode == 0, (proc.stdout or "").strip(), \
        (proc.stderr or "").strip()


def cmd_get(args):
    """Print the instance list as JSON (missing file -> [])."""
    svc, file_rel, _fields = load_docs_config(args.git_root, args.playbook)
    _ok, out, _err = engine(args, ["--file", file_rel, "get", "--json"])
    # A missing file is not an error for reads (same as the WebUI: absent
    # means no instances yet).
    if not _ok:
        print("[]")
        return
    print(out or "[]")


def cmd_schema(args):
    """Print the normalized docs.config fields as JSON."""
    _svc, _rel, fields = load_docs_config(args.git_root, args.playbook)
    print(json.dumps([fields[name] for name in fields]))


def cmd_save(args):
    """Coerce stdin JSON rows against the schema and store them."""
    _svc, file_rel, fields = load_docs_config(args.git_root, args.playbook)
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else []
    except json.JSONDecodeError as e:
        e_usage("invalid JSON on stdin: {}".format(e))
    raw_rows = payload.get("rows") if isinstance(payload, dict) else payload
    if not isinstance(raw_rows, list):
        e_usage("stdin must hold a JSON list (or {\"rows\": [...]})")
    rows = []
    for raw_row in raw_rows:
        if not isinstance(raw_row, dict):
            e_usage("each row must be a JSON object")
        row, err = coerce_row(fields, raw_row)
        if err:
            e_usage(err)
        rows.append(row)
    doc = yaml.dump(rows, default_flow_style=False, sort_keys=False,
                    allow_unicode=True)
    check = ["--check"] if args.check else []
    ok, out, err = engine(args, ["--file", file_rel, "write"] + check, doc)
    if not ok:
        e_technical("failed to write {}: {}".format(file_rel, err or out))
    print(out)
    if args.check:
        return
    if out.strip().splitlines()[0] == "unchanged":
        print("instances-unchanged")
    else:
        print("instances-changed: {} row(s)".format(len(rows)))


def main(argv=None):
    """Parse arguments and dispatch to the subcommand, return exit code."""
    parser = argparse.ArgumentParser(
        prog="symbios-instances.py",
        description="Schema-aware manager for per-service instance lists "
                    "(docs.config). Reads the field schema from the "
                    "playbook's # docs: block, coerces stdin JSON rows, and "
                    "delegates the atomic write to symbios-config.py.",
        epilog="Examples:\n"
               "  symbios-instances.py --playbook services/wordpress.yml get\n"
               "  symbios-instances.py --playbook services/wordpress.yml schema\n"
               "  echo '[{\"name\": \"blog\"}]' | symbios-instances.py \\\n"
               "    --playbook services/wordpress.yml save\n"
               "\nExit codes: 0 ok/unchanged, 2 usage or validation error, "
               "1 technical error.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--playbook", required=True,
                        help="playbook path relative to the repo, e.g. services/wordpress.yml")
    parser.add_argument("--git-root", default=os.environ.get("SYMBIOS_GIT_ROOT", DEFAULT_GIT_ROOT),
                        help="repo root with the playbooks (default: %(default)s)")
    parser.add_argument("--config-dir", default=os.environ.get("SYMBIOS_CONFIG", DEFAULT_CONFIG_DIR),
                        help="config dir jail (default: %(default)s)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_get = sub.add_parser("get", help="print the instance list as JSON")
    p_get.set_defaults(func=cmd_get)

    p_schema = sub.add_parser("schema", help="print the docs.config fields as JSON")
    p_schema.set_defaults(func=cmd_schema)

    p_save = sub.add_parser("save", help="coerce stdin JSON rows and store them")
    p_save.add_argument("--check", action="store_true",
                        help="validate only, change nothing")
    p_save.set_defaults(func=cmd_save)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
