# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
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

"""Dynamic catalog of all SymbiOS playbooks.

The WebUI container has the playbook sources mounted read-only at /repo, so it
parses the machine-readable '# docs:' blocks locally (no SSH round-trip, no
host helper). Nothing is hardcoded: the menu, the service overview and the
available actions are all derived from the playbooks.
"""
import os
import time
import yaml

REPO_BASE = "/repo"
CONFIG_BASE = "/config"
EXCLUDE_PLAYBOOKS = {"traefik-static.yml", "inventory.yml"}
# User-uploaded playbooks live under /config/user-playbooks/ (writable),
# while built-in playbooks live under /repo/{services,base-services} (read-only).
_REPO_GROUPS = ("services", "base-services")

# Cache the parsed catalog for a short time so it is not re-fetched on every
# request (the sidebar is rendered on several pages).
_CACHE = {"data": None, "updated": 0.0, "ttl": 30.0}


def parse_docs(path):
    """Return the 'docs:' mapping from a playbook's leading comment block."""
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return None
    if not lines:
        return None
    # First pass: find all comment lines (skipping blank lines between comment blocks)
    comment_lines = []
    in_comment_block = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            in_comment_block = True
            comment_lines.append(line)
        elif in_comment_block and stripped == "":
            # Allow blank lines between comment blocks (e.g. license + docs)
            continue
        elif in_comment_block:
            break
    # Now extract everything from "# docs:" onward
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
        return None
    try:
        doc = yaml.safe_load("\n".join(yaml_lines))
    except Exception:
        return None
    return doc.get("docs") if isinstance(doc, dict) else None


def _scan_dir(group, base, d):
    """Scan a single directory for playbooks and return catalog entries."""
    results = []
    if not os.path.isdir(d):
        return results
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".yml") or fn in EXCLUDE_PLAYBOOKS:
            continue
        docs = parse_docs(os.path.join(d, fn))
        if not docs:
            continue
        results.append({
            "group": group,
            "name": fn[:-4],
            "playbook": "%s/%s" % (group, fn),
            "title": docs.get("short_description", fn[:-4]),
            "docs": docs,
        })
    return results


def _load_local():
    results = []
    # Built-in playbooks (read-only repo mount)
    for group in _REPO_GROUPS:
        results += _scan_dir(group, REPO_BASE, os.path.join(REPO_BASE, group))
    # User-uploaded playbooks (writable config dir)
    user_dir = os.path.join(CONFIG_BASE, "user-playbooks")
    results += _scan_dir("user-playbooks", "user-playbooks", user_dir)
    return results


def get_catalog(force=False):
    now = time.time()
    if not force and _CACHE["data"] is not None and (now - _CACHE["updated"]) < _CACHE["ttl"]:
        return _CACHE["data"]
    data = _load_local()
    for item in data:
        item.setdefault("menu_label", _menu_label(item.get("playbook", "")))
    _CACHE["data"] = data
    _CACHE["updated"] = now
    return data


def _menu_label(playbook):
    """Compact sidebar label: filename without .yml, first letter capitalized."""
    name = playbook.split("/")[-1]
    if name.endswith(".yml"):
        name = name[:-4]
    if not name:
        return name
    return name[0].upper() + name[1:]


def get_playbook(playbook):
    for item in get_catalog():
        if item["playbook"] == playbook:
            return item
    return None
