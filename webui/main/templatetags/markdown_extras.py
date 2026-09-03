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

from django import template
from django.utils.safestring import mark_safe

import markdown as md

register = template.Library()


@register.filter(name='markdown')
def markdown_filter(text):
    """Render a markdown string as safe HTML."""
    return mark_safe(md.markdown(text, extensions=['fenced_code', 'tables', 'nl2br']))


@register.filter(name='dict_get')
def dict_get(d, key):
    """Get a value from a dictionary by variable key in templates."""
    if isinstance(d, dict):
        return d.get(key, '')
    return ''


@register.filter(name='hc_name')
def hc_name(playbook):
    """Derive the healthcheck check name from a playbook path.

    'base-services/traefik.yml' -> 'traefik'
    'services/home-assistant.yml' -> 'home-assistant'
    """
    name = playbook.rsplit('/', 1)[-1]  # strip directory
    name = name.rsplit('.', 1)[0]       # strip .yml
    return name


@register.filter(name='service_url')
def service_url(svc):
    """Resolve and render a service's external URL, or '' if none.

    Reads ``docs.url`` from the catalog item and resolves any Jinja-like
    variables such as ``{{ base_domain }}`` against the configured
    ``base_domain`` in inventory.yml. Returns an empty string when the
    service declares no reachable URL.
    """
    if not isinstance(svc, dict):
        return ''
    raw_url = (svc.get('docs') or {}).get('url')
    if not raw_url:
        return ''
    import os
    base_domain = ''
    try:
        config_path = os.environ.get('CONFIG_PATH', '/config/inventory.yml')
        import yaml
        with open(config_path) as fh:
            cfg = yaml.safe_load(fh) or {}
        base_domain = cfg.get('all', {}).get('vars', {}).get('base_domain', '')
    except Exception:
        pass
    if base_domain:
        raw_url = raw_url.replace('{{ base_domain }}', base_domain)
    return raw_url

