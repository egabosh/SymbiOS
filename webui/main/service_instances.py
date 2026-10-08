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

"""Generic per-service instance configuration handled by the WebUI.

Any service playbook can declare a ``docs.config`` block describing a list of
instances (e.g. several WordPress/Nextcloud sites) together with a field
schema. The WebUI then renders a generic "Instances" tab on the service detail
page; saving (schema coercion + atomic write) goes through
scripts/symbios-instances.py on the host, which parses the same docs.config
source. Reads stay container-local via load_instances() below.

Persisted rows land in a YAML file inside the writable config dir:

    <config_root>/<docs.config.file>  (default services/<svc>/instances.yml)

The playbook loads the same file via include_vars and drives its loops from
it. Only base-system settings belong into inventory.yml; instance lists are
service data and live in the config dir instead.

docs.config schema (parsed by the playbook catalog, no validation enforced):

    #   config:
    #     title: Instances
    #     file: services/<service>/instances.yml
    #     fields:
    #       name:
    #         label: Name
    #         type: text            # text|password|number|bool|list|select
    #         required: true
    #         pattern: "^[a-z0-9-]+$"
    #         placeholder: my-instance
    #         options:            # only for type select
    #           - value: a
    #             label: Option A
"""
import os
import yaml

CONFIG_BASE = "/config"


def get_service_name(playbook):
    """Return the playbook's service directory name (services/<svc>.yml)."""
    base = playbook.rsplit("/", 1)[-1]
    return base[:-4] if base.endswith(".yml") else base


def get_config_meta(item):
    """Extract the normalized docs.config metadata from a catalog item.

    Returns None when the playbook does not declare an instances config.
    Fields are normalized to a dict of {name: fielddict} with defaults filled.
    """
    meta = ((item or {}).get("docs") or {}).get("config")
    if not meta:
        return None
    svc = get_service_name(item.get("playbook", ""))
    file_path = meta.get("file") or "services/%s/instances.yml" % svc
    fields = {}
    raw_fields = meta.get("fields")
    if isinstance(raw_fields, list):
        for f in raw_fields:
            name = f.get("name")
            if name:
                fields[name] = _normalize_field(name, f)
    elif isinstance(raw_fields, dict):
        for name, f in raw_fields.items():
            fields[name] = _normalize_field(name, f if isinstance(f, dict) else {"label": f or name})
    return {
        "title": meta.get("title") or "Instances",
        "file": file_path,
        "fields": fields,
        "field_order": list(fields.keys()),
        "fields_json": fields,   # for templates
    }


def _normalize_field(name, raw):
    ftype = str(raw.get("type") or "text").lower()
    spec = {
        "name": name,
        "label": raw.get("label") or name,
        "type": ftype,
        "required": bool(raw.get("required")),
        "placeholder": raw.get("placeholder") or "",
        "pattern": raw.get("pattern") or "",
        "options": raw.get("options") or [],
        "default": raw.get("default"),
    }
    return spec


def _config_path(meta):
    """Resolve the instances file inside the container's /config mount."""
    rel = meta.get("file") or "services/%s/instances.yml" % meta.get("_service", "")
    return os.path.join(CONFIG_BASE, rel)


def load_instances(meta):
    """Load the instance list from the config file (empty list when absent).

    The file stores a plain YAML list of mappings. Non-list content degrades
    to an empty list instead of raising. Reads stay container-local
    (read-only /config mount); writes go through symbios-instances.py on
    the host (schema coercion + atomic write, single writer).
    """
    path = _config_path(meta)
    try:
        with open(path) as fh:
            data = yaml.safe_load(fh) or []
    except (OSError, yaml.YAMLError):
        return []
    return data if isinstance(data, list) else []
