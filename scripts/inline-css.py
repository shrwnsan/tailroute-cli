#!/usr/bin/env python3
"""Inline the landing's region stylesheets into one <style> at deploy time.

The source tree keeps one CSS file per page region (site/assets/css/*.css,
linked in cascade order from the `assets` region of site/index.html). Serving
19 extra files costs first-paint time, so the deploy job inlines them: every
<link rel="stylesheet"> inside the assets region is replaced by a single
<style> holding the files concatenated in the same order, with url() paths
rewritten from the CSS files' base (assets/css/) to the page's. Cascade order,
custom properties, and the region markers are preserved.

Idempotent: a page with no region stylesheets left in the assets region is
left untouched, so the deploy job can run this unconditionally. The source
tree is never modified — the deploy workflow runs this after it injects live
metrics and before the page check.

Usage: python3 scripts/inline-css.py [--root SITE_DIR]   (default: site)
"""

import argparse
import posixpath
import re
import sys
from pathlib import Path

REGION = re.compile(r"(<!-- region:assets[^\n]*-->)(.*?)(<!-- /region:assets -->)", re.S)
STYLESHEET_LINK = re.compile(r'<link rel="stylesheet" href="(assets/css/[^"]+)"\s*/?>\n?')
URL = re.compile(r"url\(\s*(['\"]?)(?!https?:|data:|/)([^)'\"]+)\1\s*\)")


def rewrite_urls(css: str) -> str:
    """Rewrite url() references from assets/css/-relative to page-relative."""

    def sub(m: re.Match) -> str:
        quote, target = m.group(1), m.group(2)
        return f"url({quote}{posixpath.normpath(posixpath.join('assets/css', target))}{quote})"

    return URL.sub(sub, css)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default="site", help="site directory (default: site)")
    args = parser.parse_args()

    page = Path(args.root) / "index.html"
    if not page.is_file():
        print(f"inline-css: {page} not found", file=sys.stderr)
        return 1
    html = page.read_text(encoding="utf-8")

    region = REGION.search(html)
    if not region:
        print("inline-css: no assets region found — nothing to do")
        return 0

    block = region.group(2)
    hrefs = STYLESHEET_LINK.findall(block)
    if not hrefs:
        print("inline-css: no stylesheets to inline — nothing to do")
        return 0

    missing = [h for h in hrefs if not (Path(args.root) / h).is_file()]
    if missing:
        print(f"inline-css: referenced stylesheet(s) missing: {', '.join(missing)}", file=sys.stderr)
        return 1

    css = "".join(rewrite_urls((Path(args.root) / h).read_text(encoding="utf-8")) for h in hrefs)
    style = f"    <style>\n{css}    </style>\n"

    original = region.group(0)
    first = STYLESHEET_LINK.search(original)
    new_region = STYLESHEET_LINK.sub("", original)
    new_region = new_region[: first.start()] + style + new_region[first.start() :]
    html = html[: region.start()] + new_region + html[region.end() :]

    page.write_text(html, encoding="utf-8")
    print(f"inline-css: inlined {len(hrefs)} stylesheets ({len(css)} bytes) into {page}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
