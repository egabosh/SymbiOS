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
# symbios-playbook-refs.py - List inventory vars a playbook consumes.
#
# Prints the sorted inventory variable names referenced in a playbook's
# task bodies, its templates/files dirs, and recursively followed static
# include_tasks/import_tasks (shared-tasks etc.), one per line. Only names
# from inventory.yml all.vars count - loop vars, facts and filters never
# match. Used by symbios-settings-check.sh to validate uses_vars blocks
# (docs-driven resolver needs complete declarations); not used at runtime.
#
# Usage: symbios-playbook-refs.py [--git-root DIR] <playbook>
#   playbook: repo-relative path, e.g. base-services/traefik.yml
#
# Exit codes: 0 ok, 2 usage error, 1 technical error.

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("symbios-playbook-refs.py: PyYAML is required (python3-yaml)",
          file=sys.stderr)
    sys.exit(1)

DEFAULT_GIT_ROOT = "/symbios/git/SymbiOS"
_TOKEN_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
_STOP = {"and", "or", "not", "is", "in", "true", "false", "none",
        "defined", "undefined", "if", "else", "elif", "for", "as"}
_MAX_DEPTH = 5


def e_usage(msg):
    print("symbios-playbook-refs.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(2)


def e_technical(msg):
    print("symbios-playbook-refs.py: error: {}".format(msg), file=sys.stderr)
    sys.exit(1)


def load_inv_vars(git_root):
    """Return the inventory template's all.vars key set."""
    path = os.path.join(git_root, "inventory.yml")
    try:
        with open(path) as f:
            inv = yaml.safe_load(f) or {}
    except OSError as e:
        e_technical("cannot read inventory.yml: {}".format(e))
    except yaml.YAMLError as e:
        e_technical("cannot parse inventory.yml: {}".format(e))
    return set(((inv.get("all") or {}).get("vars") or {}).keys())


def read_text(path):
    """Read a file, return '' when missing (optional includes)."""
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def refs_in_text(text, inv_vars):
    """Inventory vars referenced in {{ }}, {% %} and when: lines."""
    found = set()
    for m in re.finditer(r"\{\{.*?\}\}|\{%.*?%\}", text, re.S):
        for tok in _TOKEN_RE.findall(m.group(0)):
            if tok in inv_vars:
                found.add(tok)
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") or "when:" not in s:
            continue
        frag = s.split("when:", 1)[1]
        for tok in _TOKEN_RE.findall(frag):
            if (tok in inv_vars and tok.lower() not in _STOP
                    and not tok.startswith("ansible_")):
                found.add(tok)
    return found


_TEMPLATE_EXTS = ("j2", "yml", "yaml", "conf", "json", "xml")


def _is_template_file(name):
    return name.split(".")[-1] in _TEMPLATE_EXTS


def shared_templates(git_root):
    """Template files outside any stem dir (root level, files/, ...).

    Playbook files (*.yml) are excluded: they are apply units, not shared
    templates (task sharing goes through include_tasks, followed
    separately). Basename matching below would otherwise attribute every
    cross-mentioned playbook name.
    """
    out = []
    for base in ("base-services", "services"):
        top = os.path.join(git_root, base)
        if not os.path.isdir(top):
            continue
        stems = {os.path.splitext(f)[0] for f in os.listdir(top)
                 if f.endswith(".yml")}
        for root, _ds, fs in os.walk(top):
            rel = os.path.relpath(root, top)
            if rel != "." and rel.split(os.sep)[0] in stems:
                continue  # stem dir: owned, not shared
            for name in sorted(fs):
                if name.endswith(".yml"):
                    continue
                if _is_template_file(name):
                    out.append(os.path.join(root, name))
    return out


def collect(playbook_path, inv_vars, seen, depth=0, shared=()):
    """Recursively collect refs (playbook + static includes + templates)."""
    found = set()
    if depth > _MAX_DEPTH:
        return found
    text = read_text(playbook_path)
    if not text:
        return found
    # own body without full-line comments
    body = "\n".join(l for l in text.splitlines()
                     if not l.strip().startswith("#"))
    found |= refs_in_text(body, inv_vars)
    # adjacent templates dir (services/<name>/, base-services/<name>/)
    base = os.path.dirname(playbook_path)
    stem = os.path.splitext(os.path.basename(playbook_path))[0]
    cand = os.path.join(base, stem)
    if os.path.isdir(cand):
        for root, _ds, fs in os.walk(cand):
            for name in sorted(fs):
                if not _is_template_file(name):
                    continue
                found |= refs_in_text(read_text(os.path.join(root, name)),
                                      inv_vars)
    # shared templates this unit deploys (referenced by file name, e.g.
    # traefik-services.j2 deployed by traefik.yml)
    for path in shared:
        if os.path.basename(path) in text:
            found |= refs_in_text(read_text(path), inv_vars)
    # static includes, one idempotent pass each (visited set stops cycles)
    pb_dir = os.path.dirname(playbook_path)
    for m in re.finditer(r"^\s*(?:include_tasks|import_tasks):\s*(\S+)",
                         text, re.M):
        inc = m.group(1).strip().strip("\"'")
        if not inc or "{{" in inc or "{%" in inc:
            continue  # dynamic include: not statically resolvable
        inc_path = os.path.normpath(os.path.join(pb_dir, inc))
        if inc_path in seen or not os.path.isfile(inc_path):
            continue
        seen.add(inc_path)
        found |= collect(inc_path, inv_vars, seen, depth + 1, shared)
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="symbios-playbook-refs.py",
        description="Print inventory vars a playbook consumes "
                    "(tasks, templates, static includes), one per line.",
        epilog="Exit codes: 0 ok, 2 usage error, 1 technical error.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--git-root",
                        default=os.environ.get("SYMBIOS_GIT_ROOT",
                                               DEFAULT_GIT_ROOT),
                        help="repo root (default: %(default)s)")
    parser.add_argument("playbook", nargs="?",
                        help="repo-relative playbook, e.g. base-services/traefik.yml "
                             "(omit with --map)")
    parser.add_argument("--map", action="store_true",
                        help="print VAR -> playbooks map for all host playbooks "
                             "(one '<var>: <pb> ...' line per var, sorted)")
    args = parser.parse_args(argv)
    inv_vars = load_inv_vars(args.git_root)
    if args.map:
        import glob as _glob
        table = {}
        pbs = sorted(_glob.glob(os.path.join(args.git_root, "base-services", "*.yml"))
                     + _glob.glob(os.path.join(args.git_root, "services", "*.yml")))
        shared = shared_templates(args.git_root)
        for pb_path in pbs:
            rel = os.path.relpath(pb_path, args.git_root)
            for var in collect(pb_path, inv_vars, {pb_path}, shared=shared):
                table.setdefault(var, []).append(rel)
        for var in sorted(table):
            print("{}: {}".format(var, " ".join(table[var])))
        return 0
    if not args.playbook:
        e_usage("playbook argument required (or use --map)")
    if os.path.isabs(args.playbook) or ".." in args.playbook.split("/"):
        e_usage("playbook must be repo-relative, got {!r}".format(args.playbook))
    path = os.path.normpath(os.path.join(args.git_root, args.playbook))
    base = os.path.normpath(args.git_root)
    if path != base and not path.startswith(base + os.sep):
        e_usage("playbook escapes the repo: {!r}".format(args.playbook))
    if not os.path.isfile(path):
        e_technical("playbook not found: {}".format(args.playbook))
    shared = shared_templates(args.git_root)
    for var in sorted(collect(path, inv_vars, {path}, shared=shared)):
        print(var)
    return 0


if __name__ == "__main__":
    sys.exit(main())
