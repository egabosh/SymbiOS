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

"""Web FileManager: browse and edit host files through the WebUI.

All host operations run on the host via scripts/symbios-file-manager.sh
(through the SSH exec gateway). Read-only verbs are answered synchronously;
every change verb is dispatched via create_job() so the browser shows the
shared exec output modal until the operation finishes.
"""

import base64
import json
import os
import re
import shlex

from django.http import HttpResponse, JsonResponse, StreamingHttpResponse
from django.shortcuts import render

from .decorators import login_required
from .utils.jobs import create_job
from .utils.ssh_exec import run_command, run_command_bytes_stream
from .views import _get_inventory_config, _save_inventory_config

# Host-side operation script (in scripts/ which is on the host PATH).
_FM = 'symbios-file-manager.sh'

# WebUI transfer guards. Downloads stream incrementally through the SSH gateway
# (no size limit); the single-request upload path is only for small files -
# larger files move through the chunked staging pipeline (_UPLOAD_CHUNK_BYTES
# per part), so neither path buffers more than a bounded amount in the WebUI.
_SMALL_UPLOAD_BYTES = 16 * 1024 * 1024
_UPLOAD_CHUNK_BYTES = 8 * 1024 * 1024
_UPLOAD_STAGING_PREFIX = '/tmp/symbios-fm-upload.'


def _valid_name(raw):
    """A single file name component: non-empty, no slashes, no dot trickery."""
    name = (raw or '').strip()
    if not name or '/' in name or name in ('.', '..'):
        raise ValueError('Invalid file name.')
    if '\x00' in name or '\n' in name or '\t' in name:
        raise ValueError('Invalid file name.')
    return name


def _staging_path(raw):
    """A staging path created by the host's upload-start verb (no traversal)."""
    tmp = (raw or '').strip()
    if not tmp.startswith(_UPLOAD_STAGING_PREFIX):
        raise ValueError('Invalid staging file.')
    if '/' in tmp[len(_UPLOAD_STAGING_PREFIX):] or '\x00' in tmp:
        raise ValueError('Invalid staging file.')
    return tmp


def _q(text):
    """Shell-quote a single argument for embedding in a host command."""
    text = str(text)
    if '\x00' in text:
        raise ValueError('NUL byte not allowed in argument.')
    return shlex.quote(text)


def _norm_path(raw, default='/'):
    """Normalize a file manager path (absolute, no trailing slash tricks)."""
    path = (raw or '').strip()
    if not path:
        return default
    if not path.startswith('/'):
        raise ValueError('Path must be absolute.')
    if '\x00' in path or '\n' in path:
        raise ValueError('Path contains invalid characters.')
    return path


def _load_scripts():
    """User-defined scripts from inventory.yml (`all.vars.file_manager_scripts`).

    Each script is a dict with a display `name` and a shell `command` that may
    contain {{path}}/{{dir}}/{{name}}/{{stem}} placeholders (shell-quoted on
    the host). No scripts are shipped by default.
    """
    config = _get_inventory_config()
    raw = config.get('all', {}).get('vars', {}).get('file_manager_scripts') or []
    scripts = []
    if isinstance(raw, list):
        for item in raw:
            if not isinstance(item, dict):
                continue
            name = str(item.get('name') or '').strip()
            command = str(item.get('command') or '').strip()
            if not name or not command:
                continue
            scripts.append({'name': name, 'command': command})
    return scripts


def _run(verb, *args, timeout=60):
    """Run a read-only FileManager verb; return its stdout text."""
    cmd = '{0} {1}'.format(_FM, ' '.join([verb] + [_q(a) for a in args]))
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    if not ok:
        detail = (stderr or stdout or 'command failed').strip()
        raise RuntimeError(detail[:400])
    return stdout


def _split_paths(raw):
    """Parse a JSON array of paths from a POST field."""
    try:
        paths = json.loads(raw)
    except Exception:
        raise ValueError('Invalid paths payload.')
    if not isinstance(paths, list) or not paths:
        raise ValueError('No files selected.')
    return [_norm_path(p) for p in paths]


def _job_response(verb, args, title, message, timeout=600):
    """Dispatch a change verb via create_job() and return the overlay payload."""
    cmd = '{0} {1}'.format(_FM, ' '.join([verb] + [_q(a) for a in args]))
    job_id = create_job(cmd, timeout=timeout)
    return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                         'message': message, 'command': cmd})


@login_required
def filemanager(request):
    """File manager page."""
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    root = _norm_path(vars_.get('file_manager_root'), '/symbios')
    default_path = request.GET.get('path') or root
    scripts = _load_scripts()
    return render(request, 'main/filemanager.html', {
        'scripts': scripts,
        'scripts_json': json.dumps(scripts),
        'ph': {
            'path': '{{path}}',
            'dir': '{{dir}}',
            'name': '{{name}}',
            'stem': '{{stem}}',
        },
        'root': root,
        'default_path': default_path,
        'default_path_json': json.dumps(default_path),
        'page_key': 'filemanager',
        'page_icon': 'bi-folder2-open',
        'page_title': 'FileManager',
        'page_status': 'none',
        'page_explain': ('Browse and edit files on this server. Text files open in '
                         'a built-in editor; uploads/downloads stream through the '
                         'WebUI. Change operations (delete, rename, chmod, chown, '
                         'scripts) run with live output in the command overlay.'),
    })


@login_required
def filemanager_api(request):
    """JSON API for read verbs (GET) and change verbs (POST, exec overlay)."""
    action = request.GET.get('action') or request.POST.get('action') or ''
    try:
        if action == 'list':
            path = _norm_path(request.GET.get('path'))
            out = _run('list', path)
            return JsonResponse({'ok': True, 'entries': json.loads(out)})
        if action == 'stat':
            path = _norm_path(request.GET.get('path'))
            out = _run('stat', path)
            return JsonResponse({'ok': True, 'entry': json.loads(out)})
        if action == 'read':
            path = _norm_path(request.GET.get('path'))
            out = _run('read', path)
            return JsonResponse({'ok': True, **json.loads(out)})
        if action == 'users':
            out = _run('users')
            return JsonResponse({'ok': True, **json.loads(out)})

        if request.method != 'POST':
            return JsonResponse({'ok': False, 'error': 'POST required for action.'},
                                status=400)

        if action == 'write':
            path = _norm_path(request.POST.get('path'))
            content = request.POST.get('content', '')
            payload = base64.b64encode(content.encode('utf-8')).decode('ascii')
            job_id = create_job('{0} write {1}'.format(_FM, _q(path)), timeout=300,
                                stdin_data=payload)
            return JsonResponse({'ok': True, 'job': job_id, 'title': 'Saving file...',
                                 'message': 'File saved.', 'command': None})

        if action == 'create':
            dir_path = _norm_path(request.POST.get('dir'))
            name = (request.POST.get('name') or '').strip()
            if not name or '/' in name or name in ('.', '..'):
                return JsonResponse({'ok': False, 'error': 'Invalid file name.'}, status=400)
            path = dir_path.rstrip('/') + '/' + name
            content = request.POST.get('content', '')
            payload = base64.b64encode(content.encode('utf-8')).decode('ascii')
            job_id = create_job('{0} write {1}'.format(_FM, _q(path)), timeout=300,
                                stdin_data=payload)
            return JsonResponse({'ok': True, 'job': job_id, 'title': 'Creating file...',
                                 'message': 'File created.', 'command': None})

        if action == 'upload':
            dir_path = _norm_path(request.POST.get('dir'))
            f = request.FILES.get('file')
            if not f:
                return JsonResponse({'ok': False, 'error': 'No file attached.'}, status=400)
            name = _valid_name(f.name)
            data = f.read()
            if len(data) > _SMALL_UPLOAD_BYTES:
                return JsonResponse({'ok': False,
                                     'error': 'File exceeds the {0} MB single-request upload '
                                              'limit. The UI splits larger files into '
                                              'incremental chunks.'.format(
                                                  _SMALL_UPLOAD_BYTES // (1024 * 1024))},
                                    status=413)
            payload = base64.b64encode(data).decode('ascii')
            job_id = create_job('{0} upload {1} {2}'.format(_FM, _q(dir_path), _q(name)),
                                timeout=600, stdin_data=payload)
            return JsonResponse({'ok': True, 'job': job_id, 'title': 'Uploading {0}...'.format(name),
                                 'message': 'Upload started.', 'command': None})

        if action == 'upload-start':
            dir_path = _norm_path(request.POST.get('dir'))
            name = _valid_name(request.POST.get('name'))
            ok, out, err = run_command('{0} upload-start {1} {2}'.format(
                _FM, _q(dir_path), _q(name)), timeout=30)
            if not ok or not out.strip():
                return JsonResponse({'ok': False,
                                     'error': (err or 'upload-start failed').strip()[:300]},
                                    status=500)
            try:
                tmp = json.loads(out.strip()).get('tmp')
            except Exception:
                return JsonResponse({'ok': False, 'error': 'Bad upload-start response.'},
                                    status=500)
            return JsonResponse({'ok': True, 'tmp': tmp})

        if action == 'upload-part':
            tmp = _staging_path(request.POST.get('tmp'))
            f = request.FILES.get('file')
            if not f:
                return JsonResponse({'ok': False, 'error': 'No chunk attached.'}, status=400)
            chunk = f.read()
            if not chunk:
                return JsonResponse({'ok': False, 'error': 'Empty chunk.'}, status=400)
            if len(chunk) > _UPLOAD_CHUNK_BYTES:
                return JsonResponse({'ok': False, 'error': 'Chunk too large.'}, status=400)
            payload = base64.b64encode(chunk).decode('ascii')
            ok, out, err = run_command('{0} upload-part {1}'.format(_FM, _q(tmp)),
                                       timeout=300, stdin_data=payload)
            if not ok:
                return JsonResponse({'ok': False,
                                     'error': (err or out or 'upload-part failed').strip()[:300]},
                                    status=500)
            return JsonResponse({'ok': True})

        if action == 'upload-finish':
            dir_path = _norm_path(request.POST.get('dir'))
            name = _valid_name(request.POST.get('name'))
            tmp = _staging_path(request.POST.get('tmp'))
            ok, out, err = run_command('{0} upload-finish {1} {2} {3}'.format(
                _FM, _q(dir_path), _q(name), _q(tmp)), timeout=30)
            if not ok:
                return JsonResponse({'ok': False,
                                     'error': (err or out or 'upload-finish failed').strip()[:300]},
                                    status=500)
            return JsonResponse({'ok': True})

        if action == 'upload-abort':
            tmp = _staging_path(request.POST.get('tmp'))
            run_command('{0} upload-abort {1}'.format(_FM, _q(tmp)), timeout=30)
            return JsonResponse({'ok': True})

        if action == 'mkdir':
            path = _norm_path(request.POST.get('path'))
            if path in ('/', ''):
                return JsonResponse({'ok': False, 'error': 'Invalid directory path.'}, status=400)
            return _job_response('mkdir', [path], 'Creating directory...', 'Directory created.')

        if action == 'delete':
            paths = _split_paths(request.POST.get('paths'))
            if any(p == '/' for p in paths):
                return JsonResponse({'ok': False, 'error': 'Refusing to delete the root directory.'},
                                    status=400)
            return _job_response('delete', paths, 'Deleting {0} item(s)...'.format(len(paths)),
                                 'Items deleted.')

        if action == 'rename':
            src = _norm_path(request.POST.get('src'))
            dst = _norm_path(request.POST.get('dst'))
            if dst == '/':
                return JsonResponse({'ok': False, 'error': 'Refusing to rename to the root.'},
                                    status=400)
            return _job_response('rename', [src, dst], 'Renaming...', 'Renamed.')

        if action == 'move':
            dest = _norm_path(request.POST.get('dest'))
            if dest == '/':
                return JsonResponse({'ok': False, 'error': 'Destination cannot be the root.'},
                                    status=400)
            paths = _split_paths(request.POST.get('paths'))
            return _job_response('move', [dest] + paths, 'Moving {0} item(s)...'.format(len(paths)),
                                 'Moved.', timeout=1200)

        if action == 'copy':
            dest = _norm_path(request.POST.get('dest'))
            if dest == '/':
                return JsonResponse({'ok': False, 'error': 'Destination cannot be the root.'},
                                    status=400)
            paths = _split_paths(request.POST.get('paths'))
            return _job_response('copy', [dest] + paths, 'Copying {0} item(s)...'.format(len(paths)),
                                 'Copied.', timeout=1200)

        if action == 'chmod':
            mode = (request.POST.get('mode') or '').strip()
            if not re.match(r'^[0-7]{3,4}$', mode):
                return JsonResponse({'ok': False, 'error': 'Invalid mode (octal 3-4 digits).'},
                                    status=400)
            recursive = '1' if request.POST.get('recursive') == '1' else '0'
            paths = _split_paths(request.POST.get('paths'))
            return _job_response('chmod', [mode, recursive] + paths, 'Changing permissions...',
                                 'Permissions updated.')

        if action == 'chown':
            owner = (request.POST.get('owner') or '').strip()
            group = (request.POST.get('group') or '').strip()
            if owner and not re.match(r'^[A-Za-z0-9_.-]+$', owner):
                return JsonResponse({'ok': False, 'error': 'Invalid owner name.'}, status=400)
            if group and not re.match(r'^[A-Za-z0-9_.-]+$', group):
                return JsonResponse({'ok': False, 'error': 'Invalid group name.'}, status=400)
            if not owner and not group:
                return JsonResponse({'ok': False, 'error': 'Choose an owner or a group.'},
                                    status=400)
            recursive = '1' if request.POST.get('recursive') == '1' else '0'
            paths = _split_paths(request.POST.get('paths'))
            return _job_response('chown', [owner, group, recursive] + paths,
                                 'Changing owner/group...', 'Owner/group updated.')

        if action == 'run-script':
            script_name = (request.POST.get('script') or '').strip()
            paths = _split_paths(request.POST.get('paths'))
            script = next((s for s in _load_scripts() if s['name'] == script_name), None)
            if not script:
                return JsonResponse({'ok': False, 'error': 'Unknown script: ' + script_name},
                                    status=400)
            args = [script['command']] + paths
            title = 'Running script: {}'.format(script['name'])
            cmd = '{0} run-script {1}'.format(_FM, ' '.join([_q(a) for a in args]))
            job_id = create_job(cmd, timeout=7200)
            return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                 'message': 'Script started.', 'command': cmd})

        if action == 'save-scripts':
            try:
                raw = json.loads(request.POST.get('scripts'))
            except Exception:
                return JsonResponse({'ok': False, 'error': 'Invalid scripts payload.'},
                                    status=400)
            if not isinstance(raw, list):
                return JsonResponse({'ok': False, 'error': 'Scripts must be a list.'},
                                    status=400)
            cleaned = []
            for item in raw:
                if not isinstance(item, dict):
                    continue
                name = str(item.get('name') or '').strip()
                command = str(item.get('command') or '').strip()
                if not name or not command or '\n' in name:
                    continue
                if not name.replace('-', '').replace('_', '').replace(' ', '').replace('.', '').isalnum():
                    return JsonResponse({'ok': False, 'error': 'Invalid script name: ' + name},
                                        status=400)
                if len(command) > 4000:
                    return JsonResponse({'ok': False, 'error': 'Command too long (max 4000 chars).'},
                                        status=413)
                cleaned.append({'name': name, 'command': command})
            try:
                config = _get_inventory_config()
                config.setdefault('all', {}).setdefault('vars', {})
                if cleaned:
                    config['all']['vars']['file_manager_scripts'] = cleaned
                else:
                    config['all']['vars'].pop('file_manager_scripts', None)
                _save_inventory_config(config)
            except Exception as e:
                return JsonResponse({'ok': False, 'error': 'Failed to save scripts: {}'.format(e)},
                                    status=500)
            return JsonResponse({'ok': True, 'scripts': cleaned})

        return JsonResponse({'ok': False, 'error': 'Unknown action: ' + action}, status=400)
    except ValueError as e:
        return JsonResponse({'ok': False, 'error': str(e)}, status=400)
    except RuntimeError as e:
        return JsonResponse({'ok': False, 'error': str(e)}, status=500)


@login_required
def filemanager_download(request):
    """Stream a single file to the browser (binary-safe, incremental).

    The bytes are drained chunk-wise from the SSH gateway, so the file size is
    only bounded by the host's disk - the WebUI container never buffers the
    whole payload. The size reported by ``stat`` is sent as Content-Length so
    the browser can show a download progress bar.
    """
    try:
        path = _norm_path(request.GET.get('path'))
    except ValueError as e:
        return HttpResponse(str(e), status=400)
    try:
        meta = json.loads(_run('stat', path, timeout=15))
    except RuntimeError as e:
        return HttpResponse(str(e), status=404)
    if meta.get('type') == 'dir':
        return HttpResponse('Cannot download a directory. Use the copy/move features instead.',
                            status=400)
    size = int(meta.get('size') or 0)
    name = os.path.basename(path.rstrip('/'))
    stream = run_command_bytes_stream('{0} download {1}'.format(_FM, _q(path)),
                                      timeout=900, chunk_size=1024 * 1024)
    resp = StreamingHttpResponse(iter(stream), content_type='application/octet-stream')
    resp['Content-Disposition'] = 'attachment; filename="{0}"'.format(name)
    resp['Content-Length'] = str(size)
    return resp