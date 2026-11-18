#!/usr/bin/env python3
# SymbiOS - Parse an RSS/Atom feed into normalized JSON for the WebUI news page.
# Copyright (c) 2026, Oliver Bohlen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Feed parser for the SymbiOS news feed.

Kept as a dedicated Python script because neither jq nor a standard CLI tool
parses RSS/Atom XML safely. The companion shell script does the fetch, locking
and snapshot writing; this script only turns one local XML file into JSON.
"""

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

MAX_SUMMARY = 300


def localname(tag):
    """Return the tag name without a possible XML namespace."""
    return tag.split('}', 1)[-1] if '}' in tag else tag


def child_text(element, *names):
    """Return the text of the first child matching one of the local names."""
    for child in list(element):
        if localname(child.tag) in names:
            return ''.join(child.itertext()).strip()
    return ''


def children(element, *names):
    """Yield children matching one of the local names."""
    for child in list(element):
        if localname(child.tag) in names:
            yield child


def feed_entries(root):
    """Return the entry elements of an RSS channel or an Atom feed."""
    if localname(root.tag) == 'rss':
        channels = list(children(root, 'channel'))
        return list(children(channels[0], 'item')) if channels else []
    if localname(root.tag) == 'feed':
        return list(children(root, 'entry'))
    # Some feeds omit the rss wrapper and start at channel level.
    if localname(root.tag) == 'channel':
        return list(children(root, 'item'))
    return []


def atom_link(entry):
    """Prefer the alternate link; fall back to the first link with an href."""
    links = list(children(entry, 'link'))
    for link in links:
        rel = link.get('rel', 'alternate')
        if rel == 'alternate' and link.get('href'):
            return link.get('href')
    for link in links:
        if link.get('href'):
            return link.get('href')
    return ''


def normalize_time(value):
    """Turn RSS/Atom dates into a sortable ISO UTC string, or '' on failure."""
    if not value:
        return ''
    try:
        date = parsedate_to_datetime(value)
    except (TypeError, ValueError, IndexError):
        try:
            date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (TypeError, ValueError):
            return ''
    if date is None:
        return ''
    if date.tzinfo is None:
        date = date.replace(tzinfo=timezone.utc)
    return date.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def plain_text(value):
    """Strip markup and collapse whitespace for a one-line summary."""
    text = re.sub(r'<[^>]+>', ' ', value or '')
    text = html.unescape(text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text[:MAX_SUMMARY]


def severity_of(title, categories, markers):
    """Return 'alert' when a marker occurs in a category or the title."""
    haystack = ' '.join([title] + list(categories)).lower()
    for marker in markers:
        if marker and marker.lower() in haystack:
            return 'alert'
    return 'info'


def parse_feed(path, markers, limit):
    """Parse the feed file and return a normalized item list."""
    tree = ET.parse(path)
    entries = feed_entries(tree.getroot())
    items = []
    for entry in entries:
        title = plain_text(child_text(entry, 'title'))
        link = atom_link(entry) or child_text(entry, 'link')
        guid = child_text(entry, 'guid', 'id') or link
        published_raw = child_text(entry, 'pubDate', 'published', 'updated', 'date')
        published = normalize_time(published_raw)
        summary = plain_text(child_text(entry, 'description', 'summary', 'content'))
        categories = []
        for category in children(entry, 'category'):
            term = category.get('term') or ''.join(category.itertext()).strip()
            if term:
                categories.append(term)
        item_id = guid or '{}|{}'.format(title, published_raw)
        items.append({
            'id': item_id,
            'title': title,
            'link': link,
            'published': published,
            'summary': summary,
            'categories': categories,
            'severity': severity_of(title, categories, markers),
        })
    items.sort(key=lambda item: item['published'] or '', reverse=True)
    return items[:limit]


def main(argv=None):
    """Parse CLI arguments and print the normalized feed as JSON."""
    parser = argparse.ArgumentParser(
        prog='symbios-news.py',
        description='Parse one RSS 2.0 or Atom feed file into normalized JSON.',
        epilog='Exit codes: 0 ok, 2 usage error, 1 unreadable/invalid feed.',
    )
    parser.add_argument('file', help='local feed file to parse')
    parser.add_argument('--markers', default='',
                        help='comma-separated severity markers (default: none)')
    parser.add_argument('--limit', type=int, default=50,
                        help='maximum number of items (default: 50)')
    args = parser.parse_args(argv)
    markers = [part.strip() for part in args.markers.split(',') if part.strip()]
    try:
        items = parse_feed(args.file, markers, args.limit)
    except (ET.ParseError, OSError) as error:
        print('symbios-news.py: {}'.format(error), file=sys.stderr)
        return 1
    json.dump({'items': items}, sys.stdout, ensure_ascii=False)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
