#!/usr/bin/env python3
"""Build the compact WebUI summary from one normalized Traefik host log.

The shell wrapper normalizes all access logs into one JSON Lines file per
host. This helper replaces a series of full-file jq group_by/unique passes
with a single accumulation, which is the dominant CPU cost of the hourly
Traefik statistics job on hosts with large logs.
"""

import argparse
import json
import math
import re
import sys
from collections import defaultdict

STATIC_PATH_RE = re.compile(
    r"\.(css|js|mjs|json|xml|txt|map|jpg|jpeg|png|gif|svg|webp|ico|"
    r"woff2?|ttf|eot|pdf|zip|gz|mp[34]|webm|ogg|wav|flac)$",
    re.IGNORECASE,
)

BROWSER_RULES = (
    ("googlebot", "Googlebot"),
    ("bingbot", "Bingbot"),
    ("bot|crawler|spider|slurp|bingpreview|facebookexternalhit", "Other bots"),
    ("curl", "curl"),
    ("wget", "Wget"),
    ("python|httpie|postman|go-http-client", "Other clients"),
    ("edg/|edgios|edga", "Edge"),
    ("firefox|fxios", "Firefox"),
    ("chrome|crios", "Chrome"),
    ("safari", "Safari"),
)

OS_RULES = (
    ("windows", "Windows"),
    ("android", "Android"),
    ("iphone|ipad|ipod|cpu os", "iOS"),
    ("mac os x|macintosh", "macOS"),
    ("linux", "Linux"),
)


def classify(value, rules, default):
    """Return the first matching label from an ordered list of regex rules."""
    for pattern, label in rules:
        if re.search(pattern, value, re.IGNORECASE):
            return label
    return default


def referrer_host(referrer):
    """Mirror the jq ref_host helper; None means the row is not counted."""
    if referrer in ("-", ""):
        return None
    if "://" in referrer:
        return referrer.split("://", 1)[1].split("/")[0].split(":")[0]
    return referrer.split("/")[0].split(":")[0]


class Stats:
    """One accumulated table row: request count, bytes and unique visitors."""

    def __init__(self):
        self.requests = 0
        self.bytes = 0
        self.visitors = set()

    def add(self, content_size, visitor_key=None):
        """Add one record, optionally adding its visitor tuple."""
        self.requests += 1
        self.bytes += content_size
        if visitor_key is not None:
            self.visitors.add(visitor_key)


def top_rows(groups, limit):
    """Return the top rows sorted like jq's sort_by(-requests, key)."""
    rows = [
        {
            "value": key,
            "requests": value.requests,
            "visitors": len(value.visitors),
            "bytes": value.bytes,
        }
        for key, value in groups.items()
    ]
    rows.sort(key=lambda row: (-row["requests"], row["value"]))
    return rows[:limit]


def group_map():
    """Return a defaultdict of Stats for one summary dimension."""
    return defaultdict(Stats)


def build_summary(records_path, host, generated):
    """Read one host log and return the summary object for the WebUI."""
    total = 0
    total_bytes = 0
    not_found = 0
    visitors = set()
    paths = set()
    referrers = set()
    dates = group_map()
    hours = group_map()
    statuses = group_map()
    pages = group_map()
    assets = group_map()
    not_found_paths = group_map()
    sites = group_map()
    clients = group_map()
    browsers = group_map()
    operating_systems = group_map()
    ua_cache = {}
    min_time = None
    max_time = None

    with open(records_path, "r", encoding="utf-8") as records_file:
        for line in records_file:
            record = json.loads(line)
            client = record.get("ClientHost", "-")
            status = record.get("DownstreamStatus", 0)
            content_size = record.get("DownstreamContentSize", 0)
            user_agent = record.get("request_User-Agent", "-")
            request_path = record.get("RequestPath", "-")
            referrer = record.get("request_Referer", "-")
            timestamp = record.get("time", "")
            date = timestamp[:10]
            hour = timestamp[11:13]
            counted = status < 400 or status >= 500
            visitor = (client, date, user_agent)

            total += 1
            total_bytes += content_size
            if status == 404:
                not_found += 1
            if counted:
                visitors.add(visitor)
            paths.add(request_path)
            if referrer not in ("-", ""):
                referrers.add(referrer)

            if min_time is None or timestamp < min_time:
                min_time = timestamp
            if max_time is None or timestamp > max_time:
                max_time = timestamp

            dates[date].add(content_size, (client, user_agent) if counted else None)
            hours[hour].add(content_size)
            statuses[status].add(content_size)

            if STATIC_PATH_RE.search(request_path):
                assets[request_path].add(content_size, visitor if counted else None)
            else:
                pages[request_path].add(content_size, visitor if counted else None)
            if status == 404:
                not_found_paths[request_path].add(content_size, visitor if counted else None)

            site = referrer_host(referrer)
            if site is not None:
                # The old jq filter dropped DownstreamStatus from site rows,
                # so all of them counted as visitors.
                sites[site].add(content_size, visitor)
            clients[client].add(content_size, visitor if counted else None)

            if user_agent not in ua_cache:
                ua_cache[user_agent] = (
                    classify(user_agent, BROWSER_RULES, "Other"),
                    classify(user_agent, OS_RULES, "Other"),
                )
            browser, os_name = ua_cache[user_agent]
            browsers[browser].add(content_size, visitor if counted else None)
            operating_systems[os_name].add(content_size, visitor if counted else None)

    def pct(count):
        if total == 0:
            return 0
        # jq's round() is half away from zero for these positive values, and
        # its division prints an integer result without a decimal point.
        rounded = math.floor((count * 1000 / total) + 0.5)
        if rounded % 10 == 0:
            return rounded // 10
        return rounded / 10

    daily = [
        {
            "date": date,
            "requests": stats.requests,
            "visitors": len(stats.visitors),
            "bytes": stats.bytes,
        }
        for date, stats in dates.items()
    ]
    daily.sort(key=lambda row: row["date"])
    hourly = [
        {"hour": hour, "requests": stats.requests} for hour, stats in hours.items()
    ]
    hourly.sort(key=lambda row: row["hour"])
    status_codes = [
        {
            "status": status,
            "requests": stats.requests,
            "percent": pct(stats.requests),
        }
        for status, stats in statuses.items()
    ]
    status_codes.sort(key=lambda row: (-row["requests"], row["status"]))

    return {
        "host": host,
        "generated_at": generated,
        "period": {"from": min_time or "", "to": max_time or ""},
        "totals": {
            "requests": total,
            "visitors": len(visitors),
            "bytes": total_bytes,
            "not_found": not_found,
            "unique_files": len(paths),
            "unique_referrers": len(referrers),
        },
        "daily": daily,
        "hourly": hourly,
        "status_codes": status_codes,
        "pages": top_rows(pages, 15),
        "assets": top_rows(assets, 10),
        "not_found_paths": top_rows(not_found_paths, 10),
        "referring_sites": top_rows(sites, 10),
        "clients": top_rows(clients, 10),
        "browsers": top_rows(browsers, 10),
        "operating_systems": top_rows(operating_systems, 10),
    }


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Build a compact Traefik statistics summary for the SymbiOS WebUI.",
        epilog=(
            "Output: one JSON object on stdout. Exit codes: 0 success, "
            "1 input/JSON error, 2 usage error."
        ),
    )
    parser.add_argument("records", help="normalized JSON Lines host log")
    parser.add_argument("--host", required=True, help="Traefik host name")
    parser.add_argument("--generated", required=True, help="generation timestamp")
    return parser.parse_args()


def main():
    """Entry point."""
    args = parse_args()
    try:
        summary = build_summary(args.records, args.host, args.generated)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Failed to build summary: {error}", file=sys.stderr)
        return 1
    json.dump(summary, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
