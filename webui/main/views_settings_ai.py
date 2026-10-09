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


from django.http import JsonResponse
from .decorators import login_required
from .views import _get_inventory_config

import json
import urllib.request
import urllib.error

@login_required
def settings_ai_test(request):
    """AJAX POST - optional connection check against an OpenAI-compatible server.

    Probes the /models endpoint (also tries /v1/models for servers entered
    without the /v1 prefix) with the given API key. Does not save anything.
    """
    if request.method != 'POST':
        return JsonResponse({'valid': False, 'error': 'POST required'}, status=400)

    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    server = request.POST.get('ai_server', '').strip() or vars_.get('ai_server', '')
    apikey = request.POST.get('ai_apikey', '').strip() or vars_.get('ai_apikey', '')

    if not server:
        return JsonResponse({'valid': False,
                             'error': 'No AI server URL. Enter one or save first.'})
    if not server.startswith(('http://', 'https://')):
        server = 'https://' + server

    base = server.rstrip('/')
    candidates = [base + '/models']
    if not base.endswith('/v1'):
        candidates.append(base + '/v1/models')

    last_error = None
    for url in candidates:
        ok, detail = _probe_openai_models(url, apikey)
        if ok:
            return JsonResponse({'valid': True, 'message': detail})
        last_error = detail
    return JsonResponse({'valid': False, 'error': last_error or 'Connection check failed.'})


def _probe_openai_models(url, apikey):
    """Probe an OpenAI-compatible /models endpoint, return (ok, message)."""
    headers = {'Accept': 'application/json'}
    if apikey:
        headers['Authorization'] = f'Bearer {apikey}'
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            count = None
            try:
                data = json.loads(resp.read().decode('utf-8', errors='replace'))
                count = len(data.get('data', [])) if isinstance(data, dict) else None
            except Exception:
                pass
            msg = f'Server reachable ({url}).'
            if count is not None:
                msg += f' {count} model(s) available.'
            return True, msg
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False, f'HTTP {e.code} - invalid or missing API key.'
        if e.code == 404:
            return False, f'No /models endpoint found at {url} (HTTP 404).'
        return False, f'HTTP {e.code} from {url}.'
    except urllib.error.URLError as e:
        return False, f'Could not reach {url}: {e.reason}'
    except Exception as e:
        return False, f'Could not reach {url}: {e}'


def _test_url_list(request, fallback_vars, url_param_names):
    """AJAX POST - probe the given URL params (or inventory fallback) with GET.

    Returns the first reachable URL, else the last error. Saves nothing.
    """
    if request.method != 'POST':
        return JsonResponse({'valid': False, 'error': 'POST required'}, status=400)
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    urls = []
    for param in url_param_names:
        url = (request.POST.get(param, '').strip() or vars_.get(param, '') or
               fallback_vars.get(param, '')).strip()
        if url:
            # SearXNG carries a <query> placeholder - probe the base instead.
            url = url.replace('<query>', 'test')
            urls.append(url)
    if not urls:
        return JsonResponse({'valid': False,
                             'error': 'No URL configured. Enter one or save first.'})
    last_error = None
    for url in urls:
        if not url.startswith(('http://', 'https://')):
            url = 'https://' + url
        try:
            req = urllib.request.Request(url, headers={'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                return JsonResponse({'valid': True,
                                     'message': f'Server reachable ({url}, HTTP {resp.status}).'})
        except urllib.error.HTTPError as e:
            # Any HTTP answer proves the host is alive (auth errors count as reachable).
            return JsonResponse({'valid': True,
                                 'message': f'Server reachable ({url}, HTTP {e.code}).'})
        except Exception as e:
            last_error = f'Could not reach {url}: {e}'
    return JsonResponse({'valid': False, 'error': last_error or 'Connection check failed.'})


@login_required
def settings_ai_speech_test(request):
    """AJAX POST - probe STT/TTS base URLs (OpenAI-compatible /models or plain GET)."""
    if request.method != 'POST':
        return JsonResponse({'valid': False, 'error': 'POST required'}, status=400)
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    apikey = (request.POST.get('ai_stt_key', '').strip() or vars_.get('ai_stt_key', '') or
              request.POST.get('ai_tts_key', '').strip() or vars_.get('ai_tts_key', '') or
              vars_.get('ai_apikey', ''))
    for param in ('ai_stt_url', 'ai_tts_url'):
        server = request.POST.get(param, '').strip() or vars_.get(param, '')
        if not server:
            continue
        if not server.startswith(('http://', 'https://')):
            server = 'https://' + server
        base = server.rstrip('/')
        candidates = [base + '/models']
        if not base.endswith('/v1'):
            candidates.append(base + '/v1/models')
        probed = False
        for url in candidates:
            probed = True
            ok, detail = _probe_openai_models(url, apikey)
            if ok:
                return JsonResponse({'valid': True, 'message': f'{param}: {detail}'})
            if 'HTTP 401' in detail or 'HTTP 403' in detail:
                return JsonResponse({'valid': True, 'message': f'{param}: server reachable ({detail})'})
        if probed:
            continue
    return _test_url_list(request, {}, ['ai_stt_url', 'ai_tts_url'])


@login_required
def settings_ai_image_test(request):
    return _test_url_list(request, {}, ['ai_image_url', 'ai_image_edit_url'])


@login_required
def settings_ai_search_test(request):
    return _test_url_list(request, {}, ['ai_tika_url', 'ai_searxng_url'])

