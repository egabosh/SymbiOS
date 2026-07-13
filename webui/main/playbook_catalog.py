"""Dynamic catalog of all SymbiOS playbooks.

The WebUI container does not have the playbook sources mounted (to avoid
exposing repo secrets). Instead it asks the host exec gateway for the catalog:
the gateway parses the machine-readable '# docs:' blocks of every playbook and
returns only that metadata as JSON. Nothing is hardcoded: the menu, the service
overview and the available actions are all derived from the playbooks.

See symbios-exec.sh (verb: `service list`).
"""
import time
import json

EXCLUDE_PLAYBOOKS = {"traefik-static.yml"}

# Cache the parsed catalog for a short time so it is not re-fetched on every
# request (the sidebar is rendered on several pages).
_CACHE = {"data": None, "updated": 0.0, "ttl": 30.0}


def _fetch_via_ssh():
    try:
        from .utils.ssh_exec import run_command
        ok, out, err = run_command("service list", timeout=60)
        if ok and out:
            return json.loads(out)
    except Exception:
        return None
    return None


def get_catalog(force=False):
    now = time.time()
    if not force and _CACHE["data"] is not None and (now - _CACHE["updated"]) < _CACHE["ttl"]:
        return _CACHE["data"]
    data = _fetch_via_ssh()
    if data is None:
        data = _CACHE["data"] or []
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
