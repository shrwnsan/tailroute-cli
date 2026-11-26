#!/usr/bin/env python3
"""Inject live release metrics into the site at deploy time.

Counts CLI tagged releases (excludes app-v* releases, which are the menu bar
app's separate tag space) and the latest CLI version from the GitHub API, then
updates the pages in place: the landing's stat card and JSON-LD, and the
manual page's JSON-LD, version badge, release chart (SVG, hover data, data
table) and its JSON data blob. A failure leaves the pages as-is: slightly
stale numbers are this site's failure mode, a broken deploy is not.
Idempotent. Stdlib only.

The release feed (`.feed-item` entries) stays hand-written on purpose: each
entry is an editorial one-liner about what a release means, which no script
should generate.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

REPO = "shrwnsan/tailroute-cli"
PAGE = os.path.join(os.path.dirname(__file__), "..", "site", "index.html")
DOCS_PAGE = os.path.join(os.path.dirname(__file__), "..", "site", "docs", "index.html")

# The productization date (v0.6.0, one 2,071-line commit): the chart's
# "N of M shipped since Aug 24" headline counts from here.
PRODUCTIZATION_DATE = "2026-08-24"

# Chart geometry: the x axis always spans the release history at a constant
# pixel width; the y scale stretches so the topmost gridline stays one
# gridline above the latest count (room for the value label above the end
# dot). The hover mapping in chart.js reads the viewBox at runtime, so this
# block can be regenerated freely.
X_MIN, X_END, AXIS_END = 46, 698, 702
Y_BASE = 214          # y for 0 releases
Y_TOP = 6             # y for the topmost gridline (the ceil-to-10 maximum)
CHART_VB = (0, -14, 728, 260)   # x, y, w, h — y_min leaves label headroom


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
        print(f"update-metrics: implausible metrics (count={count}, latest={latest}) — leaving pages as-is")
        return 0

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    def landing(html):
        html = _replace_releases(html, count)
        html = _replace_version(html, latest)
        return _replace_span(html, "updated", f" \u00b7 site updated {today}")

    def manual(html):
        html = _replace_version(html, latest)
        html = _replace_chart(html, releases)
        return _replace_span(html, "cli-version", f"v{latest}")

    touched = 0
    for path, inject in ((PAGE, landing), (DOCS_PAGE, manual)):
        with open(path) as f:
            html = f.read()
        updated = inject(html)
        if updated == html:
            continue
        with open(path, "w") as f:
            f.write(updated)
        touched += 1

    if not touched:
        print(f"update-metrics: pages already current (releases={count}, version={latest})")
        return 0
    print(f"update-metrics: injected releases={count}, version={latest}, updated={today} ({touched} page(s))")
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
    pattern = re.compile(rf'(<span[^>]*\sdata-metric="{name}"[^>]*>)(.*?)(</span>)', re.S)
    if not pattern.search(html):
        print(f"update-metrics: WARNING span {name!r} not found")
        return html
    return pattern.sub(lambda m: m.group(1) + text + m.group(3), html)


# -----------------------------------------------------------------------------
# Release chart
# -----------------------------------------------------------------------------

def _chart_points(releases):
    """Oldest-first [(date, cumulative_count)] from the API's newest-first
    release dicts. Dates are the published_at UTC day; several releases on
    one day collapse to that day's final count (one point per date, the
    convention the hand-drawn chart used — also keeps every point hoverable,
    since same-x points would tie and shadow each other)."""
    per_day = {}
    order = []
    for i, r in enumerate(reversed(releases), start=1):
        day = (r["published_at"] or "")[:10]
        if not day:
            print("update-metrics: WARNING release without published_at — chart left as-is")
            return None
        if day not in per_day:
            order.append(day)
        per_day[day] = i
    return [(day, per_day[day]) for day in order]


def _replace_chart(html, releases):
    """Regenerate the proof chart from the release list: the header, the SVG
    (gridlines, month ticks, area+line paths, end dot + label), the hover
    data blob chart.js reads, and the data table. Any missing region leaves
    the chart untouched with a WARNING (the deploy fails noisily in
    check-site.py rather than shipping a half-drawn chart)."""
    import re
    from datetime import date

    pts = _chart_points(releases)
    if not pts or len(pts) < 2:
        print("update-metrics: WARNING fewer than two datable releases — chart left as-is")
        return html

    first_d = date.fromisoformat(pts[0][0])
    last_d = date.fromisoformat(pts[-1][0])
    span_days = max((last_d - first_d).days, 30)   # never a degenerate axis
    # pts are deduped to one per day; the totals are RELEASE counts, read
    # from the cumulative value the last day carries.
    total = pts[-1][1]
    y_max = max(10, ((total + 9) // 10) * 10)      # gridline ceiling, tens
    step = (Y_BASE - Y_TOP) / y_max                # px per release

    def day_num(d):
        return (d - first_d).days

    def x_at(d):
        return X_MIN + day_num(d) / span_days * (X_END - X_MIN)

    def y_at(v):
        return Y_BASE - v * step

    lines = []
    for (day, v) in pts:
        lines.append(f"{x_at(date.fromisoformat(day)):.1f},{y_at(v):.1f}")
    poly = " L".join(lines)
    area = f"M{poly.split(' L')[0]} L{poly} L{lines[-1].split(',')[0]},{Y_BASE} L{X_MIN},{Y_BASE} Z"

    grid = []
    for k in range(0, y_max // 10 + 1):
        v = k * 10
        y = y_at(v)
        opacity = "" if v == 0 else ' opacity="0.5"'
        grid.append(f'            <line class="axis" x1="{X_MIN}" y1="{y:.1f}" x2="{AXIS_END}" y2="{y:.1f}"{opacity}/>')
        grid.append(f'            <text class="axtext" x="{X_MIN - 8:.0f}" y="{y + 3:.1f}" text-anchor="end">{v}</text>')

    ticks = []
    m = date(first_d.year, first_d.month, 1)
    seen_last = False
    while not seen_last:
        if m >= last_d:
            seen_last = True
        if first_d <= m <= last_d or (seen_last and m <= last_d):
            x = x_at(m)
            if X_MIN <= x <= AXIS_END:
                ticks.append(f'            <text class="axtext" x="{x:.1f}" y="232" text-anchor="middle">{m.strftime("%b")}</text>')
        m = date(m.year + (m.month == 12), (m.month % 12) + 1, 1)

    last_x, last_y = x_at(last_d), y_at(total)
    before = max((v for d, v in pts if d < PRODUCTIZATION_DATE), default=0)
    since = total - before
    spring_txt = "one release in spring" if before == 1 else f"{before} releases in spring"

    svg = f"""          <svg viewBox="{CHART_VB[0]} {CHART_VB[1]} {CHART_VB[2]} {CHART_VB[3]}" role="img" tabindex="0" aria-label="Cumulative tagged releases, {first_d.strftime('%B')} to {last_d.strftime('%B %Y')}: {spring_txt}, then {since} more from late August, ending at {total}">
{chr(10).join(grid)}
{chr(10).join(ticks)}
            <path d="{area}" fill="var(--mark)" fill-opacity="0.1" stroke="none"/>
            <path d="M{poly}" fill="none" stroke="var(--mark)" stroke-width="2" stroke-linejoin="round"/>
            <circle cx="{last_x:.1f}" cy="{last_y:.1f}" r="4.5" fill="var(--mark)" stroke="var(--card)" stroke-width="2"/>
            <text x="{last_x:.1f}" y="{last_y - 6:.1f}" text-anchor="end" style="font-family:var(--mono);font-size:13px;font-weight:600" fill="var(--text)">{total}</text>
            <line id="xhair" x1="0" y1="{last_y:.1f}" x2="0" y2="{Y_BASE}" stroke="var(--line2)" stroke-width="1" opacity="0"/>
            <circle id="hoverdot" r="4" fill="var(--text)" stroke="var(--card)" stroke-width="2" opacity="0"/>
          </svg>"""

    blob = {"vb": list(CHART_VB),
            "pts": [[round(x_at(date.fromisoformat(d)), 1), round(y_at(v), 1), d, v] for d, v in pts]}
    blob_html = ('          <script type="application/json" id="chart-data">'
                 f'{json.dumps(blob, separators=(",", ":"))}</script>')

    rows = "\n".join(f'                <tr><td>{d}</td><td>{v}</td></tr>' for d, v in pts)
    table = (f"""          <details class="data">
            <summary>View data table</summary>
            <table>
              <thead><tr><th>Date</th><th>Cumulative tagged releases</th></tr></thead>
              <tbody>
{rows}
              </tbody>
            </table>
          </details>""")

    out = html
    import re as _re

    # Patterns anchor to line starts (with their indentation) so a re-run
    # replaces the whole lines and the generated block's canonical indent
    # cannot accumulate run over run.
    hi = _re.compile(r'^[ \t]*<span class="chart-hi">[^<]*</span>', _re.M)
    if not hi.search(out):
        print("update-metrics: WARNING chart-hi span not found")
    else:
        out = hi.sub(f'<span class="chart-hi">{since} of {total} releases shipped since Aug 24</span>', out)

    svg_re = _re.compile(r'^[ \t]*<svg viewBox="[^"]*" role="img"(?: tabindex="0")? aria-label="Cumulative tagged releases[^"]*">.*?^[ \t]*</svg>', _re.M | _re.S)
    if not svg_re.search(out):
        print("update-metrics: WARNING chart svg not found")
    else:
        out = svg_re.sub(lambda _: svg, out)

    blob_re = _re.compile(r'^[ \t]*<script type="application/json" id="chart-data">.*?</script>', _re.M | _re.S)
    details_re = _re.compile(r'^[ \t]*<details class="data">', _re.M)
    if blob_re.search(out):
        out = blob_re.sub(lambda _: blob_html, out)
    elif details_re.search(out):
        out = details_re.sub(lambda _: blob_html + "\n" + _.group(0), out, count=1)
    else:
        print("update-metrics: WARNING neither chart-data blob nor details block found")

    table_re = _re.compile(r'^[ \t]*<details class="data">.*?^[ \t]*</details>', _re.M | _re.S)
    if not table_re.search(out):
        print("update-metrics: WARNING chart data table not found")
    else:
        out = table_re.sub(lambda _: table, out)

    return out


if __name__ == "__main__":
    sys.exit(main())
