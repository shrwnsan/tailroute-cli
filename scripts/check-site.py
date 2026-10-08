#!/usr/bin/env python3
"""Static checks for the tailroute landing site.

The page makes promises a reviewer should not have to re-check by hand:

- no third-party subresources (fonts included) — the self-hosted analytics
  ingest is the one first-party exception,
- the release metrics the deploy script injects are present and findable,
- JSON-LD structured data parses and the FAQ stays in sync with it,
- every in-page anchor resolves and the public anchor ids stay put,
- titles use the CLI name, and retired claims stay retired,
- the shared text colours meet the WCAG AA contrast minimum on their surfaces.

Default mode runs the launch-blocking checks and is safe on every branch.
--strict adds the design-system checks (tokens only, no entrance animations,
component contracts) used on the site integration branch. --region NAME
limits the strict checks to one page region and its CSS file; it is an error
until the page carries region markers.

Pages are parsed with html.parser; CSS is read from site/assets/css/*.css and
from inline <style> blocks. The metrics check imports the helpers from
scripts/update-metrics.py (the hyphen rules out a plain import) and replays
the exact substitutions the deploy makes, without writing anything.

Python 3 standard library only, like update-metrics.py.
"""
import argparse
import html
import importlib.util
import io
import json
import re
import sys
from contextlib import redirect_stdout
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

# ---------------------------------------------------------------------------
# Contract constants. Change the page's promises here, in one place.
# ---------------------------------------------------------------------------

# The only host a subresource may load from (the page serves from this domain).
OWN_DOMAIN = "tailroute.app"

# First-party hosts a subresource may additionally load from: the self-hosted
# Plausible ingest, same registrable domain, DNS-only behind grey cloud. It
# must stay that way — proxying it through a CDN challenges cross-origin
# event POSTs and pageviews drop silently.
FIRST_PARTY_HOSTS = frozenset({"pulse.tailroute.app"})

# Claims the page must never make again: unsourced, stale, or contradictory.
BANNED_PHRASES = (
    "fonts.googleapis.com",
    "fonts.gstatic.com",
    "right-click-to-open",
    "every install sha256-verified",
    "$100 travel router",
    "public threat model",
    "~60s",
)
# Additional claims that only the redesigned copy may retire.
STRICT_BANNED_PHRASES = (
    "No stars to flex",
    "22 releases in 72 hours",
    "Shipped, not",
    "Get started",
)

# Anchor ids the landing must keep resolving (inbound links depend on them).
REQUIRED_IDS = ("top", "features", "proof", "core", "limits", "faq", "support")
STRICT_REQUIRED_IDS = ("install",)

# Entrance-animation classes; content must be visible without them.
REVEAL_CLASSES = ("reveal", "d1", "d2", "d3")

# Old design-token names the token cleanup deletes; the page must stop
# referencing them so the cleanup can land.
LEGACY_TOKENS = (
    "--bg",
    "--bg2",
    "--card",
    "--card2",
    "--line2",
    "--dim",
    "--faint",
    "--lime",
    "--lime-soft",
    "--lime-line",
    "--lime-ink",
    "--mark",
    "--amber",
    "--amber-soft",
    "--amber-line",
    "--paper",
    "--paper-ink",
    "--paper-dim",
    "--disp",
    "--sans",
    "--mono",
)

# Every install path ends with the user verifying the daemon state.
ACTIVATION_TEXT = "tailroute status"

# Text and stroke tokens the contrast check vouches for, each against the
# page's three dark surfaces; --mesh-ink is vouched against its --mesh fill.
# The minimum is the WCAG AA bar for normal text.
AA_MIN_CONTRAST = 4.5
CONTRAST_PAIRS = (
    ("--text", ("--ground", "--surface", "--surface-2")),
    ("--text-dim", ("--ground", "--surface", "--surface-2")),
    ("--text-faint", ("--ground", "--surface", "--surface-2")),
    ("--mesh", ("--ground", "--surface", "--surface-2")),
    ("--mesh-mark", ("--ground", "--surface", "--surface-2")),
    ("--vpn", ("--ground", "--surface", "--surface-2")),
    ("--mesh-ink", ("--mesh",)),
)

# The one Gatekeeper disclosure sentence every .gk-note element must carry.
GATEKEEPER_NOTE = (
    "The app isn't notarized yet. The first time you open it, macOS asks you "
    "to approve it in System Settings \u2192 Privacy & Security \u2192 Open Anyway."
)

# Region markers are mandatory: the page is split into per-region files and
# the regions check runs by default (--region scopes the strict checks).
REQUIRE_REGIONS = True
# Top-level regions in page order (head regions first).
EXPECTED_REGIONS = (
    "assets",
    "meta",
    "nav",
    "hero",
    "features",
    "proof",
    "core",
    "limits",
    "faq",
    "support",
    "finale",
    "footer",
)

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------

RAW_COLOUR_RE = re.compile(r"#[0-9a-fA-F]{3,8}(?![0-9a-fA-F])|\brgba?\(|\bhsla?\(")
CUSTOM_PROPERTY_RE = re.compile(r"(--[A-Za-z0-9-]+)\s*:\s*([^;{}]+);")
HEX_COLOUR_RE = re.compile(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})")
VAR_REFERENCE_RE = re.compile(r"var\((--[A-Za-z0-9-]+)\)")
FONT_SIZE_RE = re.compile(r"font-size\s*:\s*(?P<value>[^;{}]+)")
UPPERCASE_RE = re.compile(r"text-transform\s*:\s*uppercase")
STYLE_BLOCK_RE = re.compile(r"<style\b[^>]*>(.*?)</style>", re.S)
CSS_URL_PATTERNS = (
    re.compile(r"""url\(\s*["']?(?P<url>[^"')]+?)["']?\s*\)""", re.I),
    re.compile(r"""@import\s+url\(\s*["']?(?P<url>[^"')]+?)["']?\s*\)""", re.I),
    re.compile(r"""@import\s+["'](?P<url>[^"']+)["']""", re.I),
)
REGION_RE = re.compile(
    r"<!--\s*(?P<close>/?)region:(?P<name>[a-z0-9-]+)(?:\s+owner:\S+)?\s*-->"
)
DATA_METRIC_RE = r'data-metric="{name}"'

# Elements whose listed attributes name a loaded subresource. <a href> is
# navigation, not a subresource, and stays allowed.
SUBRESOURCE_ATTRS = {
    "link": ("href",),
    "script": ("src",),
    "img": ("src", "srcset"),
    "source": ("src", "srcset"),
    "video": ("src", "poster"),
    "iframe": ("src",),
}

VOID_ELEMENTS = frozenset(
    "area base br col embed hr img input link meta param source track wbr".split()
)

DEFAULT_ROOT = Path(__file__).resolve().parent.parent / "site"
UPDATE_METRICS_PATH = Path(__file__).resolve().parent / "update-metrics.py"


# ---------------------------------------------------------------------------
# Page model
# ---------------------------------------------------------------------------

@dataclass
class Node:
    tag: str
    attrs: dict
    line: int
    parts: list  # ("text", str) or ("el", Node), in document order


@dataclass
class Page:
    rel: str  # path relative to the site root, posix style
    text: str
    tree: Node


@dataclass
class CssSource:
    rel: str
    text: str
    base_line: int = 1

    def line_at(self, offset):
        return self.base_line + self.text.count("\n", 0, offset)


@dataclass
class RegionSpan:
    name: str
    line: int
    depth: int  # 0 = top level, 1 = nested one level
    start: int  # offset of the first character after the open marker
    end: int  # offset of the first character of the close marker


@dataclass
class Failure:
    file: str
    line: int
    detail: str


class _TreeBuilder(HTMLParser):
    """Builds a small element tree, keeping each tag's source line."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root", {}, 1, [])
        self._stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), self.getpos()[0], [])
        self._stack[-1].parts.append(("el", node))
        if tag not in VOID_ELEMENTS:
            self._stack.append(node)

    def handle_startendtag(self, tag, attrs):
        node = Node(tag, dict(attrs), self.getpos()[0], [])
        self._stack[-1].parts.append(("el", node))

    def handle_endtag(self, tag):
        for i in range(len(self._stack) - 1, 0, -1):
            if self._stack[i].tag == tag:
                del self._stack[i:]
                return

    def handle_data(self, data):
        if data:
            self._stack[-1].parts.append(("text", data))


def parse_html(text):
    builder = _TreeBuilder()
    builder.feed(text)
    builder.close()
    return builder.root


def walk(node):
    """Yield every element in the subtree, depth-first, in document order."""
    for kind, value in node.parts:
        if kind == "el":
            yield value
            yield from walk(value)


def class_list(node):
    return (node.attrs.get("class") or "").split()


def text_content(node, skip_class=None):
    """Concatenated text of the subtree; skips elements with skip_class."""
    out = []
    for kind, value in node.parts:
        if kind == "text":
            out.append(value)
        elif skip_class is None or skip_class not in class_list(value):
            out.append(text_content(value, skip_class))
    return "".join(out)


def normalize_text(text):
    """Fold quotes, dashes, entities, and whitespace so spellings compare equal."""
    text = html.unescape(text)
    for curly, straight in (("\u2019", "'"), ("\u2018", "'"), ("\u201c", '"'), ("\u201d", '"')):
        text = text.replace(curly, straight)
    for dash, hyphen in (("\u2014", "-"), ("\u2013", "-"), ("\u2011", "-"), ("\u2212", "-")):
        text = text.replace(dash, hyphen)
    text = text.replace("\u00a0", " ")
    return re.sub(r"\s+", " ", text).strip()


def external_host(url):
    """Host of an absolute http(s) or protocol-relative URL, else None."""
    url = (url or "").strip()
    if not url:
        return None
    split = urlsplit(url)
    if split.scheme in ("http", "https") or (not split.scheme and split.netloc):
        return (split.hostname or "").lower() or None
    return None


def subresource_host_allowed(host):
    """Same-origin, or a first-party host (see FIRST_PARTY_HOSTS)."""
    return not host or host == OWN_DOMAIN or host in FIRST_PARTY_HOSTS


def inline_styles(page):
    """Inline <style> blocks as CSS sources with real line numbers."""
    sources = []
    for match in STYLE_BLOCK_RE.finditer(page.text):
        body = match.group(1)
        base_line = page.text.count("\n", 0, match.start(1)) + 1
        sources.append(CssSource(page.rel, body, base_line))
    return sources


# ---------------------------------------------------------------------------
# Region markers
# ---------------------------------------------------------------------------

def scan_regions(text):
    """Parse region markers.

    Returns (spans, errors, top_level_order). spans holds one RegionSpan per
    successfully closed region; errors is a list of (line, message).
    """
    spans, errors, top_level = [], [], []
    stack = []  # (name, content_start, line)
    for match in REGION_RE.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        name = match.group("name")
        if match.group("close"):
            if not stack:
                errors.append((line, f"closing marker for /region:{name} has no open region:{name}"))
            elif stack[-1][0] != name:
                errors.append((line, f"/region:{name} closes while region:{stack[-1][0]} is still open"))
                names = [entry[0] for entry in stack]
                if name in names:
                    while stack and stack[-1][0] != name:
                        stack.pop()
                    if stack:
                        opened = stack.pop()
                        spans.append(RegionSpan(opened[0], opened[2], len(stack), opened[1], match.start()))
            else:
                opened = stack.pop()
                spans.append(RegionSpan(name, opened[2], len(stack), opened[1], match.start()))
        else:
            if any(entry[0] == name for entry in stack):
                errors.append((line, f"region:{name} is already open"))
            if len(stack) >= 2:
                errors.append((line, f"region:{name} nests more than one level deep"))
            stack.append((name, match.end(), line))
            if len(stack) == 1:
                top_level.append(name)
    for name, _, line in stack:
        errors.append((line, f"region:{name} is never closed"))
    return spans, errors, top_level


def blank_outside_region(text, name):
    """Blank every character outside the named regions, keeping newlines.

    The result parses with unchanged line numbers, so scoped checks still
    report true source lines. Returns None when the region does not exist.
    """
    spans, _, _ = scan_regions(text)
    keep = [False] * len(text)
    found = False
    for span in spans:
        if span.name == name:
            found = True
            for i in range(span.start, span.end):
                keep[i] = True
    if not found:
        return None
    return "".join(
        char if (keep[i] or char == "\n") else " " for i, char in enumerate(text)
    )


# ---------------------------------------------------------------------------
# Checks — each returns a list of Failure
# ---------------------------------------------------------------------------

def check_third_party(pages, css_sources):
    """No subresource may load from another origin. <a href> is navigation."""
    fails = []
    for page in pages:
        for element in walk(page.tree):
            for attr in SUBRESOURCE_ATTRS.get(element.tag, ()):
                value = element.attrs.get(attr)
                if not value:
                    continue
                if attr == "srcset":
                    urls = [part.strip().split()[0] for part in value.split(",") if part.strip()]
                else:
                    urls = [value.strip()]
                for url in urls:
                    host = external_host(url)
                    if not subresource_host_allowed(host):
                        fails.append(Failure(
                            page.rel, element.line,
                            f'<{element.tag} {attr}> loads from "{host}"'
                            f" — every subresource must be same-origin or first-party",
                        ))
            style = element.attrs.get("style")
            if style:
                for pattern in CSS_URL_PATTERNS[:1]:
                    for match in pattern.finditer(style):
                        host = external_host(match.group("url"))
                        if not subresource_host_allowed(host):
                            fails.append(Failure(
                                page.rel, element.line,
                                f'inline style loads from "{host}"'
                                f" — every subresource must be same-origin or first-party",
                            ))
    for source in css_sources:
        for pattern in CSS_URL_PATTERNS:
            for match in pattern.finditer(source.text):
                host = external_host(match.group("url"))
                if not subresource_host_allowed(host):
                    fails.append(Failure(
                        source.rel, source.line_at(match.start()),
                        f'CSS loads from "{host}" — every subresource must be same-origin or first-party',
                    ))
    return fails


def jsonld_blocks(page):
    for element in walk(page.tree):
        if element.tag == "script":
            if (element.attrs.get("type") or "").strip().lower() == "application/ld+json":
                yield element, text_content(element)


def check_jsonld(pages):
    fails = []
    for page in pages:
        for element, text in jsonld_blocks(page):
            if not text.strip():
                fails.append(Failure(page.rel, element.line, "empty JSON-LD block"))
                continue
            try:
                json.loads(text)
            except ValueError as exc:
                fails.append(Failure(page.rel, element.line, f"JSON-LD does not parse: {exc}"))
    return fails


def check_metrics(landing, strict):
    """Replay the deploy-time metric substitutions; any helper warning fails."""
    fails = []
    if not UPDATE_METRICS_PATH.exists():
        return [Failure(landing.rel, 1, "update-metrics.py not found next to check-site.py")]
    spec = importlib.util.spec_from_file_location("site_update_metrics", UPDATE_METRICS_PATH)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        return [Failure(landing.rel, 1, f"cannot load update-metrics.py: {exc}")]
    captured = io.StringIO()
    try:
        with redirect_stdout(captured):
            updated = module._replace_releases(landing.text, 1)
            updated = module._replace_version(updated, "0.0.0")
            module._replace_span(updated, "updated", "x")
    except Exception as exc:
        fails.append(Failure(landing.rel, 1, f"metric helpers crashed: {exc}"))
    for line in captured.getvalue().splitlines():
        if "WARNING" in line:
            fails.append(Failure(landing.rel, 1, f"deploy metric helper: {line.strip()}"))
    if strict:
        for name in ("releases", "updated"):
            matches = list(re.finditer(DATA_METRIC_RE.format(name=name), landing.text))
            if len(matches) == 1:
                continue
            if not matches:
                fails.append(Failure(
                    landing.rel, 1,
                    f'no data-metric="{name}" element for the deploy to fill',
                ))
            else:
                for match in matches[1:]:
                    fails.append(Failure(
                        landing.rel, landing.text.count("\n", 0, match.start()) + 1,
                        f'expected exactly one data-metric="{name}" element',
                    ))
    return fails


def check_faq_sync(pages):
    """FAQPage JSON-LD question names must equal the visible summaries, in order."""
    fails = []
    for page in pages:
        faq = None
        for _, text in jsonld_blocks(page):
            try:
                data = json.loads(text)
            except ValueError:
                continue
            if isinstance(data, dict) and data.get("@type") == "FAQPage":
                faq = data
        summaries = [
            element for element in walk(page.tree)
            if element.tag == "details" and "q" in class_list(element)
        ]
        if faq is None and not summaries:
            continue
        if faq is None:
            fails.append(Failure(
                page.rel, summaries[0].line,
                "visible FAQ items have no FAQPage JSON-LD to stay in sync with",
            ))
            continue
        if not summaries:
            fails.append(Failure(page.rel, 1, "FAQPage JSON-LD has no visible FAQ items"))
            continue
        json_names = [
            normalize_text(str(question.get("name") or ""))
            for question in (faq.get("mainEntity") or [])
            if isinstance(question, dict)
        ]
        visible = []
        for details in summaries:
            summary = next(
                (value for kind, value in details.parts if kind == "el" and value.tag == "summary"),
                None,
            )
            visible.append(normalize_text(text_content(summary, skip_class="pm") if summary else ""))
        if len(visible) != len(json_names):
            fails.append(Failure(
                page.rel, summaries[0].line,
                f"FAQ count differs: page has {len(visible)} items, JSON-LD has {len(json_names)}",
            ))
            continue
        for index, (page_text, json_text) in enumerate(zip(visible, json_names)):
            if page_text != json_text:
                fails.append(Failure(
                    page.rel, summaries[index].line,
                    f'FAQ item {index + 1} differs from JSON-LD: page "{page_text}"'
                    f' vs JSON-LD "{json_text}"',
                ))
    return fails


def check_anchors(pages, strict):
    """Every in-page fragment resolves; docs/# fragments resolve in the docs page."""
    fails = []
    docs_rel = "docs/index.html"
    id_sets = {
        page.rel: {element.attrs["id"] for element in walk(page.tree) if element.attrs.get("id")}
        for page in pages
    }
    for page in pages:
        for element in walk(page.tree):
            if element.tag != "a":
                continue
            href = (element.attrs.get("href") or "").strip()
            if href.startswith("#"):
                fragment = href[1:]
                if fragment and fragment not in id_sets[page.rel]:
                    fails.append(Failure(
                        page.rel, element.line,
                        f'anchor "{href}" has no target on this page',
                    ))
                continue
            match = re.match(r"^docs/#(.+)$", href)
            if match:
                if docs_rel not in id_sets:
                    fails.append(Failure(
                        page.rel, element.line,
                        f'anchor "{href}" cannot resolve: {docs_rel} does not exist',
                    ))
                elif match.group(1) not in id_sets[docs_rel]:
                    fails.append(Failure(
                        page.rel, element.line,
                        f'anchor "{href}" has no target in {docs_rel}',
                    ))
    required = list(REQUIRED_IDS) + (list(STRICT_REQUIRED_IDS) if strict else [])
    landing_ids = id_sets.get("index.html", set())
    for anchor_id in required:
        if anchor_id not in landing_ids:
            fails.append(Failure(
                "index.html", 1,
                f'required anchor id="{anchor_id}" is missing from the landing page',
            ))
    return fails


def check_names(pages):
    """Titles and title meta tags must use the CLI name."""
    fails = []
    for page in pages:
        title = next((element for element in walk(page.tree) if element.tag == "title"), None)
        if title is None:
            fails.append(Failure(page.rel, 1, "page has no <title>"))
        else:
            title_text = text_content(title).strip()
            if "tailroute-cli" not in title_text:
                fails.append(Failure(
                    page.rel, title.line,
                    f'<title> must use the CLI name: "{title_text}"',
                ))
        saw_og_title = False
        for element in walk(page.tree):
            if element.tag != "meta":
                continue
            key = element.attrs.get("property") or element.attrs.get("name") or ""
            if key not in ("og:title", "twitter:title"):
                continue
            content = element.attrs.get("content") or ""
            if key == "og:title":
                saw_og_title = True
            if "tailroute-cli" not in content:
                fails.append(Failure(
                    page.rel, element.line,
                    f'<meta {key}> must use the CLI name: "{content}"',
                ))
        if not saw_og_title:
            fails.append(Failure(page.rel, 1, "page has no og:title meta"))
    return fails


def check_banned(root, pages, strict):
    """Retired claims must not appear in any page or in llms.txt."""
    phrases = list(BANNED_PHRASES) + (list(STRICT_BANNED_PHRASES) if strict else [])
    targets = [(page.rel, page.text) for page in pages]
    llms = root / "llms.txt"
    if llms.is_file():
        targets.append(("llms.txt", llms.read_text(encoding="utf-8")))
    fails = []
    for rel, text in targets:
        for line_number, line in enumerate(text.splitlines(), 1):
            lowered = line.lower()
            for phrase in phrases:
                if phrase.lower() in lowered:
                    fails.append(Failure(rel, line_number, f'banned phrase: "{phrase}"'))
    return fails


def check_regions(landing):
    """Region markers must balance, nest one level at most, and match the order."""
    _, errors, top_level = scan_regions(landing.text)
    fails = [Failure(landing.rel, line, message) for line, message in errors]
    expected = list(EXPECTED_REGIONS)
    if top_level != expected:
        fails.append(Failure(
            landing.rel, 1,
            f"top-level region order is {top_level}, expected {expected}",
        ))
    return fails


def check_reveal(page):
    fails = []
    for element in walk(page.tree):
        hits = [name for name in REVEAL_CLASSES if name in class_list(element)]
        if hits:
            fails.append(Failure(
                page.rel, element.line,
                "entrance-animation class (" + " ".join(hits) + ")"
                " — content must be visible without animation",
            ))
    return fails


def check_heading_accent(page):
    fails = []
    for element in walk(page.tree):
        if element.tag not in ("h1", "h2", "h3"):
            continue
        for descendant in walk(element):
            if descendant.tag == "em":
                fails.append(Failure(
                    page.rel, descendant.line,
                    "<em> inside a heading — headings carry no accented phrase",
                ))
    return fails


def check_raw_colour(page, css_sources):
    fails = []
    for source in css_sources:
        for match in RAW_COLOUR_RE.finditer(source.text):
            fails.append(Failure(
                source.rel, source.line_at(match.start()),
                f"raw colour literal {match.group(0)!r} in CSS"
                " — colours come from the shared token file",
            ))
    for element in walk(page.tree):
        for attr in ("style", "fill", "stroke"):
            value = element.attrs.get(attr)
            if not value:
                continue
            for match in RAW_COLOUR_RE.finditer(value):
                fails.append(Failure(
                    page.rel, element.line,
                    f"raw colour literal {match.group(0)!r} in {attr} attribute"
                    " — colours come from the shared token file",
                ))
    return fails


def check_font_size(page, css_sources):
    fails = []
    px_or_rem = re.compile(r"[0-9.]+\s*(?:px|rem)\b", re.I)
    for source in css_sources:
        for match in FONT_SIZE_RE.finditer(source.text):
            if px_or_rem.search(match.group("value")):
                fails.append(Failure(
                    source.rel, source.line_at(match.start()),
                    f'font-size "{match.group("value").strip()}" uses px or rem'
                    " — use the type-scale tokens or em",
                ))
    for element in walk(page.tree):
        style = element.attrs.get("style")
        if not style:
            continue
        for match in FONT_SIZE_RE.finditer(style):
            if px_or_rem.search(match.group("value")):
                fails.append(Failure(
                    page.rel, element.line,
                    f'font-size "{match.group("value").strip()}" uses px or rem'
                    " — use the type-scale tokens or em",
                ))
    return fails


def check_uppercase(page, css_sources):
    fails = []
    for source in css_sources:
        for match in UPPERCASE_RE.finditer(source.text):
            fails.append(Failure(
                source.rel, source.line_at(match.start()),
                "text-transform: uppercase — labels stay in sentence case",
            ))
    for element in walk(page.tree):
        style = element.attrs.get("style")
        if style:
            for match in UPPERCASE_RE.finditer(style):
                fails.append(Failure(
                    page.rel, element.line,
                    "text-transform: uppercase — labels stay in sentence case",
                ))
    return fails


def check_img(page):
    fails = []
    for element in walk(page.tree):
        if element.tag != "img":
            continue
        missing = [
            attr for attr in ("alt", "width", "height")
            if not (element.attrs.get(attr) or "").strip()
        ]
        if missing:
            fails.append(Failure(page.rel, element.line, "<img> missing " + ", ".join(missing)))
    return fails


def check_activation(page):
    """Every install component ends in the verify command and agrees on its default tab."""
    fails = []
    selected_targets = set()
    for element in walk(page.tree):
        if "data-install" not in element.attrs:
            continue
        if ACTIVATION_TEXT not in text_content(element):
            fails.append(Failure(
                page.rel, element.line,
                f'install component does not mention "{ACTIVATION_TEXT}"',
            ))
        target = None
        for descendant in walk(element):
            if (
                descendant.attrs.get("role") == "tab"
                and descendant.attrs.get("aria-selected") == "true"
            ):
                target = descendant.attrs.get("aria-controls")
        if target is None:
            fails.append(Failure(
                page.rel, element.line,
                'install component has no tab marked aria-selected="true"',
            ))
        else:
            selected_targets.add(target)
    if len(selected_targets) > 1:
        fails.append(Failure(
            page.rel, 1,
            "install components default to different tabs: "
            + ", ".join(sorted(selected_targets)),
        ))
    return fails


def check_gk_note(page):
    fails = []
    expected = normalize_text(GATEKEEPER_NOTE)
    for element in walk(page.tree):
        if "gk-note" not in class_list(element):
            continue
        if expected not in normalize_text(text_content(element)):
            fails.append(Failure(
                page.rel, element.line,
                "gk-note must carry the standard Gatekeeper disclosure sentence",
            ))
    return fails


def check_legacy_tokens(page, css_sources):
    fails = []

    def scan(rel, text, base_line):
        for token in LEGACY_TOKENS:
            pattern = re.compile(re.escape(token) + r"(?![A-Za-z0-9-])")
            for match in pattern.finditer(text):
                fails.append(Failure(
                    rel, base_line + text.count("\n", 0, match.start()),
                    f"legacy design token {token} — use the current token names",
                ))

    scan(page.rel, page.text, 1)
    for source in css_sources:
        scan(source.rel, source.text, source.base_line)
    return fails


def parse_custom_properties(text):
    """Map each custom property name in a CSS file to its (value, line)."""
    props = {}
    for match in CUSTOM_PROPERTY_RE.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        props[match.group(1)] = (match.group(2).strip(), line)
    return props


def resolve_token(props, name, _seen=()):
    """Value of a custom property, following var() aliases; None if unknown."""
    if name in _seen or name not in props:
        return None
    value = props[name][0]
    alias = VAR_REFERENCE_RE.fullmatch(value)
    if alias:
        return resolve_token(props, alias.group(1), _seen + (name,))
    return value


def hex_rgb(value):
    """(r, g, b) tuple of 0–255 values for a #rgb or #rrggbb literal, else None."""
    match = HEX_COLOUR_RE.fullmatch(value or "")
    if not match:
        return None
    digits = match.group(1)
    if len(digits) == 3:
        digits = "".join(char + char for char in digits)
    return tuple(int(digits[i:i + 2], 16) for i in (0, 2, 4))


def relative_luminance(rgb):
    """WCAG 2.x relative luminance of an (r, g, b) tuple of 0–255 values."""
    def channel(byte):
        srgb = byte / 255
        return srgb / 12.92 if srgb <= 0.04045 else ((srgb + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(byte) for byte in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(fg_rgb, bg_rgb):
    """WCAG 2.x contrast ratio between two (r, g, b) tuples."""
    luminances = (relative_luminance(fg_rgb), relative_luminance(bg_rgb))
    return (max(luminances) + 0.05) / (min(luminances) + 0.05)


def check_contrast(css_sources):
    """Every pair in CONTRAST_PAIRS must reach the AA minimum (4.5:1)."""
    tokens = next(
        (source for source in css_sources if source.rel == "assets/css/tokens.css"),
        None,
    )
    if tokens is None:
        return [Failure(
            "assets/css/tokens.css", 1,
            "tokens.css not found — the contrast check reads its custom properties",
        )]
    props = parse_custom_properties(tokens.text)
    fails = []

    def rgb_of(name, line):
        rgb = hex_rgb(resolve_token(props, name))
        if rgb is None:
            fails.append(Failure(
                tokens.rel, line,
                f"{name} is missing or not a #rgb/#rrggbb colour"
                " — the contrast check needs it",
            ))
        return rgb

    for fg_name, bg_names in CONTRAST_PAIRS:
        fg_line = props.get(fg_name, ("", 1))[1]
        fg_rgb = rgb_of(fg_name, fg_line)
        if fg_rgb is None:
            continue
        for bg_name in bg_names:
            bg_rgb = rgb_of(bg_name, fg_line)
            if bg_rgb is None:
                continue
            ratio = contrast_ratio(fg_rgb, bg_rgb)
            if ratio < AA_MIN_CONTRAST:
                fails.append(Failure(
                    tokens.rel, fg_line,
                    f"{fg_name} on {bg_name} is {ratio:.2f}:1"
                    f" — below the {AA_MIN_CONTRAST}:1 AA minimum",
                ))
    return fails


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Static checks for the landing site (site/index.html and site/docs/index.html).",
    )
    parser.add_argument(
        "--root", metavar="DIR",
        help=f"site root directory (default: {DEFAULT_ROOT})",
    )
    parser.add_argument(
        "--strict", action="store_true",
        help="also run the design-system checks used on the site integration branch",
    )
    parser.add_argument(
        "--region", metavar="NAME",
        help="with --strict: limit the design-system checks to one page region"
             " and site/assets/css/NAME.css",
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    if not root.is_dir():
        print(f"check-site: site root not found: {root}", file=sys.stderr)
        return 2
    if args.region and not REQUIRE_REGIONS:
        print(
            "check-site: --region needs region markers, which are not required yet",
            file=sys.stderr,
        )
        return 2

    pages = []
    for path in sorted(root.rglob("*.html")):
        text = path.read_text(encoding="utf-8")
        pages.append(Page(path.relative_to(root).as_posix(), text, parse_html(text)))
    landing = next((page for page in pages if page.rel == "index.html"), None)
    if landing is None:
        print("check-site: no index.html found under the site root", file=sys.stderr)
        return 2

    css_dir = root / "assets" / "css"
    css_files = [
        CssSource(path.relative_to(root).as_posix(), path.read_text(encoding="utf-8"))
        for path in sorted(css_dir.glob("*.css"))
    ] if css_dir.is_dir() else []

    # Strict checks run against the landing page, or just one region of it.
    scope = landing
    if args.region:
        scoped_text = blank_outside_region(landing.text, args.region)
        if scoped_text is None:
            print(f"check-site: no region named {args.region!r} in index.html", file=sys.stderr)
            return 2
        scope = Page(landing.rel, scoped_text, parse_html(scoped_text))
        strict_css = [
            source for source in css_files
            if Path(source.rel).name == f"{args.region}.css"
        ] + inline_styles(scope)
    else:
        strict_css = [
            source for source in css_files
            if Path(source.rel).name != "tokens.css"
        ] + inline_styles(scope)
    all_css = css_files + [source for page in pages for source in inline_styles(page)]

    checks = [
        ("third-party", lambda: check_third_party(pages, all_css)),
        ("metrics", lambda: check_metrics(landing, strict=args.strict)),
        ("jsonld", lambda: check_jsonld(pages)),
        ("faq-sync", lambda: check_faq_sync(pages)),
        ("anchors", lambda: check_anchors(pages, strict=args.strict)),
        ("names", lambda: check_names(pages)),
        ("banned", lambda: check_banned(root, pages, strict=args.strict)),
        ("contrast", lambda: check_contrast(css_files)),
    ]
    if REQUIRE_REGIONS:
        checks.append(("regions", lambda: check_regions(landing)))
    if args.strict:
        checks += [
            ("reveal", lambda: check_reveal(scope)),
            ("heading-accent", lambda: check_heading_accent(scope)),
            ("raw-colour", lambda: check_raw_colour(scope, strict_css)),
            ("font-size", lambda: check_font_size(scope, strict_css)),
            ("uppercase", lambda: check_uppercase(scope, strict_css)),
            ("img", lambda: check_img(scope)),
            ("activation", lambda: check_activation(scope)),
            ("gk-note", lambda: check_gk_note(scope)),
        ]
        if not args.region:
            # Page-level contract; a region slice cannot vouch for it.
            checks.append(("legacy-tokens", lambda: check_legacy_tokens(scope, css_files)))

    failed_checks = 0
    for check_id, run in checks:
        failures = run()
        if failures:
            failed_checks += 1
        for failure in failures:
            print(f"FAIL {check_id} {failure.file}:{failure.line} {failure.detail}")

    if failed_checks:
        print(f"FAILED {failed_checks} of {len(checks)} checks")
        return 1
    print(f"OK {len(checks)} checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
