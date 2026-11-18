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

"""News feed page and its host-side refresh/acknowledge actions."""

import json
import shlex

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .decorators import login_required
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .views_home import _localize_time

NEWS_FILE = '/log/news.json'
NEWS_SCRIPT = 'symbios-news.sh'


def read_news_snapshot():
    """Return the news snapshot written by symbios-news.sh (or {})."""
    try:
        with open(NEWS_FILE) as handle:
            data = json.load(handle)
    except (FileNotFoundError, PermissionError, json.JSONDecodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _display_items(snapshot):
    """Add localized dates and read flags to every item for rendering."""
    unread_ids = {entry.get('id') for entry in (snapshot.get('unread_alerts') or [])
                  if isinstance(entry, dict)}
    items = []
    for raw in snapshot.get('items') or []:
        if not isinstance(raw, dict):
            continue
        item = dict(raw)
        item['published_local'] = _localize_time(item.get('published'))
        item['is_alert'] = item.get('severity') == 'alert'
        item['is_read'] = item.get('id') not in unread_ids
        items.append(item)
    return items


@login_required
def news(request):
    """Render the news page from the pre-fetched snapshot."""
    snapshot = read_news_snapshot()
    items = _display_items(snapshot)
    return render(request, 'main/news.html', {
        'news_items': items,
        'news_status': snapshot.get('status', ''),
        'news_error': snapshot.get('error', ''),
        'news_feed_url': snapshot.get('feed_url', ''),
        'news_updated': _localize_time(snapshot.get('updated')),
        'news_checked': _localize_time(snapshot.get('checked')),
        'news_unread': snapshot.get('unread', 0),
    })


def _news_action(request, target, title, message):
    """Run a news host action through the exec modal (with POST fallback)."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'}, status=405)
    cmd = '{} {}'.format(NEWS_SCRIPT, ' '.join(shlex.quote(part) for part in target))
    if is_ajax_request(request):
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=60)
        return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                             'message': message, 'command': cmd})
    try:
        ok, stdout, stderr = run_command(cmd, timeout=30)
    except Exception as error:
        messages.error(request, 'Error: {}'.format(error))
        return redirect('news')
    if ok:
        messages.success(request, message)
    else:
        messages.error(request, (stderr or stdout or 'Command failed')[:500])
    return redirect('news')


@login_required
def news_ack(request):
    """Mark one alert item, or all current alerts, as read."""
    item_id = (request.POST.get('item_id') or 'all').strip()
    if not item_id or '\n' in item_id or '\r' in item_id or len(item_id) > 300:
        return JsonResponse({'ok': False, 'error': 'Invalid item id.'}, status=400)
    return _news_action(
        request,
        ['ack', item_id],
        'Marking news as read...',
        'News item marked as read.',
    )


@login_required
def news_refresh(request):
    """Fetch the configured feed now instead of waiting for the hourly cron."""
    return _news_action(
        request,
        ['refresh'],
        'Refreshing news feed...',
        'News feed refreshed.',
    )
