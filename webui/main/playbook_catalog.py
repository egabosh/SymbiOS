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
    if not lines or not lines[0].lstrip().startswith("# docs:"):
        return None
    yaml_lines = []
    for line in lines:
        if not line.startswith("#"):
            break
        yaml_lines.append(line[2:] if line.startswith("# ") else line[1:])
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


def compose_base(compose_file):
    """Derive the docker-compose service base name from a compose_file path.

    Paths may contain the Jinja placeholder '.{{ inventory_hostname }}', which is
    stripped so the exec gateway glob (/home/docker/<name>*) finds the real dir.
    """
    if not compose_file:
        return ""
    directory = compose_file.replace("/home/docker/", "").rstrip("/")
    if directory.endswith("/docker-compose.yml"):
        directory = directory[: -len("/docker-compose.yml")]
    directory = directory.split("/")[-1]
    return directory.replace(".{{ inventory_hostname }}", "")
