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

"""Generically rendered settings pages (schema + get --json driven).

One view serves every slug in settings_registry.SETTINGS: GET fetches the
script's `schema` and `get --json` and renders settings_generic.html;
POST sends the full field object via `set --json-stdin` and chains the
registry reapply (if any). Secrets submitted empty are omitted (keep
stored); secrets never travel as argv. Follows the exec-modal dual-mode
pattern (AJAX job/redirect JSON, fallback messages + redirect).
"""

import json
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .settings_registry import SETTINGS
from .setup_status import PAGE_EXPLAIN, get_page_badge
from .utils.http import is_ajax_request
from .utils.jobs import create_job
from .utils.settings_cli import run_settings_script, settings_failed
from .utils.ssh_exec import run_command
from .views import _get_inventory_config


def _script(cmd, timeout=30, stdin_data=None):
    """Run a settings script command, return (ok, stdout, stderr)."""
    return run_command(cmd, timeout=timeout, stdin_data=stdin_data)


def _load_schema(entry):
    """Fetch and normalize the script schema (list of field dicts)."""
    ok, stdout, stderr = _script('{} schema'.format(entry['script']),
                                 timeout=15)
    if not ok:
        return None, (stderr or stdout or 'Could not load schema.')
    try:
        schema = json.loads(stdout)
    except (ValueError, TypeError):
        return None, 'Invalid schema JSON from script.'
    if isinstance(schema, dict):
        schema = schema.get('fields', [])
    if not isinstance(schema, list):
        return None, 'Invalid schema shape from script.'
    fields = []
    for raw in schema:
        if not isinstance(raw, dict) or not raw.get('name'):
            continue
        fields.append({
            'name': raw['name'],
            'type': str(raw.get('type') or 'text').lower(),
            'label': raw.get('label') or raw['name'],
            'required': bool(raw.get('required')),
            'placeholder': raw.get('placeholder') or '',
            'pattern': raw.get('pattern') or '',
            'secret': bool(raw.get('secret')),
            'options': _normalize_options(raw.get('options') or []),
            'detect': raw.get('detect') or '',
            'note': raw.get('note') or '',
        })
    return fields, None


def _normalize_options(options):
    """Schema options: strings or {value, label} dicts -> uniform list."""
    out = []
    for opt in options:
        if isinstance(opt, dict):
            out.append({'value': str(opt.get('value', '')),
                        'label': str(opt.get('label', opt.get('value', '')))})
        else:
            out.append({'value': str(opt), 'label': str(opt)})
    return out


def _load_values(entry):
    """Fetch current values via get --json ({} when unavailable)."""
    ok, stdout, _stderr = _script('{} get --json'.format(entry['script']),
                                  timeout=15)
    if not ok or not stdout:
        return {}
    try:
        values = json.loads(stdout)
    except (ValueError, TypeError):
        return {}
    return values if isinstance(values, dict) else {}


def _resolve_detect(entry, field):
    """Resolve a select's detect subcommand to an option list."""
    if not field['detect']:
        return field['options']
    ok, stdout, _stderr = _script('{} {}'.format(entry['script'],
                                                shlex.quote(field['detect'])),
                                  timeout=15)
    if not ok or not stdout:
        return field['options']
    options = [{'value': line, 'label': line}
               for line in (l.strip() for l in stdout.splitlines())
               if line]
    return options or field['options']


@login_required
def settings_generic(request, slug):
    """Render and save one registry settings page."""
    entry = SETTINGS.get(slug)
    if entry is None:
        from django.shortcuts import Http404
        raise Http404('Unknown settings page: ' + slug)
    script = entry['script']

    if request.method == 'POST':
        return _save_generic(request, slug, entry, script)
    return _render_generic(request, slug, entry, script)


def _render_generic(request, slug, entry, script):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    fields, err = _load_schema(entry)
    if fields is None:
        fields = []
    values = _load_values(entry) if fields else {}
    for field in fields:
        name = field['name']
        if field['type'] == 'select' and field['detect']:
            field['options'] = _resolve_detect(entry, field)
        if field['secret']:
            # Secrets never come back; show only whether one is stored.
            field['value'] = ''
            field['secret_set'] = bool(values.get(name + '_set'))
        else:
            value = values.get(name, '')
            if value is None:
                value = ''
            elif not isinstance(value, (str, bool)):
                value = json.dumps(value)
            field['value'] = value
    badge = get_page_badge(entry.get('explain') or slug, vars_)
    return render(request, 'main/settings_generic.html', {
        'slug': slug,
        'fields': fields,
        'load_error': err,
        'vars': vars_,
        'page_key': slug,
        'page_icon': entry.get('icon', 'bi-gear'),
        'page_title': entry.get('title', slug),
        'page_explain': PAGE_EXPLAIN.get(entry.get('explain') or slug, ''),
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


def _save_generic(request, slug, entry, script):
    is_ajax = is_ajax_request(request)
    fields, err = _load_schema(entry)
    if fields is None:
        if is_ajax:
            return JsonResponse({'ok': False, 'error': err}, status=500)
        messages.error(request, f'Error: {err}')
        return redirect(request.path)
    # Full field object via stdin (secrets never as argv). Empty secrets
    # are omitted so untouched secrets stay stored (clearing stays on the
    # dedicated page, if any).
    payload = {}
    for field in fields:
        name = field['name']
        if field['type'] == 'bool':
            payload[name] = request.POST.get(name) in ('true', '1', 'on', 'yes')
        else:
            payload[name] = request.POST.get(name, '')
        if field['secret'] and not payload[name]:
            del payload[name]
    result = run_settings_script(
        '{} set --json-stdin'.format(script), timeout=30,
        stdin_data=json.dumps(payload))
    if not result:
        return settings_failed(request, result, request.path)
    playbooks = entry.get('playbooks') or []
    message = entry.get('message') or 'Settings saved.'
    if playbooks:
        flag = '--only {}'.format(' '.join(playbooks))
        if entry.get('force'):
            flag = '--only --force {}'.format(' '.join(playbooks))
        cmd = 'symbios-reapply.sh {}'.format(flag)
        title = 'Reapplying: ' + ', '.join(playbooks)
        if is_ajax:
            job_id = create_job(cmd, timeout=3600)
            return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                 'message': message, 'command': cmd})
        messages.success(request, message)
        messages.info(request, 'Reapplying playbooks in the background...')
        create_job(cmd, timeout=3600)
        return redirect(request.path)
    if is_ajax:
        return JsonResponse({'ok': True, 'message': message,
                             'redirect': request.path})
    messages.success(request, message)
    return redirect(request.path)
