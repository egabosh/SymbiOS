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
page and persists the rows to a YAML file inside the writable config dir:

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

# Supported input types and their YAML round-tripping behavior.
_BOOL_TYPES = {"bool", "boolean", "checkbox"}
_NUMBER_TYPES = {"number", "int", "float"}
_LIST_TYPES = {"list"}
_TEXT_TYPES = {"text", "password", "select", "string"}


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
    to an empty list instead of raising.
    """
    path = _config_path(meta)
    try:
        with open(path) as fh:
            data = yaml.safe_load(fh) or []
    except (OSError, yaml.YAMLError):
        return []
    return data if isinstance(data, list) else []


def save_instances(meta, rows):
    """Persist the instance list and return (ok, error). Atomic write, and the
    saved format is compatible with Ansible include_vars (plain list of maps).
    """
    path = _config_path(meta)
    try:
        directory = os.path.dirname(path)
        if not os.path.isdir(directory):
            os.makedirs(directory, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            yaml.dump(rows if isinstance(rows, list) else [], fh,
                      default_flow_style=False, sort_keys=False, allow_unicode=True)
        os.replace(tmp, path)
        return True, None
    except Exception as exc:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass
        return False, str(exc or "write failed")


def coerce_row(meta, raw_row):
    """Validate and coerce one submitted row against the field schema.

    Returns (row, error). ``row`` contains only defined fields with YAML-safe
    values (booleans as bool, numbers as int/float, lists as lists). Bool
    fields are always present (default False). Unknown/blank optional text
    fields are dropped.
    """
    row = {}
    for fname, spec in meta.get("fields", {}).items():
        raw = raw_row.get(fname, "")
        ftype = spec["type"]

        if ftype in _BOOL_TYPES:
            row[fname] = raw in (True, "true", "1", "on", "yes") or raw == ""
            continue

        if ftype in _NUMBER_TYPES:
            if raw in ("", None):
                row[fname] = None
                continue
            try:
                row[fname] = float(raw) if ftype in ("float",) else (int(raw) if ftype != "float" else float(raw))
            except (ValueError, TypeError):
                return None, "%s: '%s' is not a number" % (spec["label"], raw)
            continue

        if ftype in _LIST_TYPES:
            values = []
            if isinstance(raw, list):
                values = [str(v).strip() for v in raw if str(v).strip()]
            else:
                sep = spec.get("separator") or ","
                for part in str(raw or "").split(sep):
                    part = part.strip()
                    if part:
                        values.append(part)
            row[fname] = values
            continue

        # text / password / select
        value = str(raw or "").strip()
        if spec["required"] and not value:
            return None, "%s is required" % spec["label"]
        pattern = spec.get("pattern")
        if value and pattern:
            import re
            try:
                if not re.match(pattern + "$", value) and not re.match("^(" + pattern + ")$", value):
                    if not re.match("^" + pattern + "$", value):
                        return None, "%s does not match %s" % (spec["label"], pattern)
            except re.error:
                pass
        if value or spec["required"]:
            row[fname] = value
    return row, None


def coerce_rows(meta, raw_rows):
    """Coerce a list of raw rows. Returns (rows, error_or_None)."""
    rows = []
    for raw in raw_rows:
        row, err = coerce_row(meta, raw)
        if err:
            return None, err
        rows.append(row)
    return rows, None