#!/usr/bin/env python3
"""Inject live release metrics into site/index.html at deploy time.

Counts CLI tagged releases (excludes app-v* releases, which are the menu bar
app's separate tag space) and the latest CLI version from the GitHub API, then
updates the stat card and JSON-LD in place. A failure leaves the page as-is:
slightly stale numbers are this page's failure mode, a broken deploy is not.
Idempotent. Stdlib only.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

REPO = "shrwnsan/tailroute-cli"
PAGE = os.path.join(os.path.dirname(__file__), "..", "site", "index.html")


def fetch_releases():
    url = f"https://api.github.com/repos/{REPO}/releases?per_page=100"
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    releases = [r for r in fetch_releases() if not r["tag_name"].startswith("app-")]
    count = len(releases)
    latest = releases[0]["tag_name"].lstrip("v") if releases else None
    if not (0 < count < 500) or not latest:
        print(f"update-metrics: implausible metrics (count={count}, latest={latest}) — leaving page as-is")
        return 0

    with open(PAGE) as f:
        html = f.read()
    original = html

    html = _replace_releases(html, count)
    html = _replace_version(html, latest)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    html = _replace_span(html, "updated", f" \u00b7 site updated {today}")

    if html == original:
        print(f"update-metrics: page already current (releases={count}, version={latest})")
        return 0
    with open(PAGE, "w") as f:
        f.write(html)
    print(f"update-metrics: injected releases={count}, version={latest}, updated={today}")
    return 0


def _replace_releases(html, count):
    import re
    pattern = re.compile(r'<dd data-metric="releases">.*?</dd>', re.S)
    if not pattern.search(html):
        print('update-metrics: WARNING releases dd not found')
        return html
    return pattern.sub(f'<dd data-metric="releases"><i>{count}</i></dd>', html)


def _replace_version(html, version):
    import re
    pattern = re.compile(r'("softwareVersion":\s*")[^"]+(")')
    if not pattern.search(html):
        print("update-metrics: WARNING softwareVersion not found")
        return html
    return pattern.sub(lambda m: m.group(1) + version + m.group(2), html)


def _replace_span(html, name, text):
    import re
    pattern = re.compile(rf'(<span data-metric="{name}">)(.*?)(</span>)', re.S)
    if not pattern.search(html):
        print(f"update-metrics: WARNING span {name!r} not found")
        return html
    return pattern.sub(lambda m: m.group(1) + text + m.group(3), html)


if __name__ == "__main__":
    sys.exit(main())
