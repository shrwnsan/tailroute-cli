#!/usr/bin/env bash
# test-check-site.sh — Tests for scripts/check-site.py
#
# Each test writes a small fixture site into a temp dir and runs the checker
# against it with --root, asserting one pass and one fail per check id.
# Run via tests/run-tests.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-site.py"

FIXTURES=()

cleanup() {
    if [[ ${#FIXTURES[@]} -gt 0 ]]; then
        rm -rf "${FIXTURES[@]}"
    fi
}
trap cleanup EXIT

make_fixture() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/check-site-test.XXXXXX")
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

# Output and exit code of the most recent checker run
CHECK_OUT=""
CHECK_RC=0

run_checker() {
    local dir="$1"
    shift
    local rc=0
    CHECK_OUT=$(python3 "$CHECK" --root "$dir" "$@" 2>&1) || rc=$?
    CHECK_RC=$rc
}

# Same as run_checker, but with the regions check switched on. The checker
# enforces regions now, so the patch is a no-op; the helper stays so the
# region cases keep working either way.
run_checker_regions_on() {
    local dir="$1"
    shift
    local rc=0
    CHECK_OUT=$(python3 - "$CHECK" "$dir" "$@" 2>&1 <<'PY'
import importlib.util
import sys

checker, root, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
spec = importlib.util.spec_from_file_location("check_site_under_test", checker)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.REQUIRE_REGIONS = True
sys.exit(module.main(["--root", root] + extra))
PY
) || rc=$?
    CHECK_RC=$rc
}

assert_not_contains() {
    local substring="$1"
    local output="$2"
    if [[ "$output" == *"$substring"* ]]; then
        _assert_fail "Output unexpectedly contains '$substring'"
    fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# The text and stroke palette the contrast check vouches for. --text-faint
# resolves through an alias, so the check's var() handling is exercised on
# every default run.
write_tokens_css() {
    local dir="$1"
    mkdir -p "$dir/assets/css"
    cat > "$dir/assets/css/tokens.css" <<'CSS'
:root {
  --ground: #0d0d0b;
  --surface: #161613;
  --surface-2: #1b1b17;
  --text: #f0efe8;
  --text-dim: #a3a196;
  --faint-ink: #8a887d;
  --text-faint: var(--faint-ink);
  --mesh: #c6f24e;
  --mesh-ink: #161a05;
  --mesh-mark: #74a41a;
  --vpn: #e8a33d;
}
CSS
}

# A minimal page that passes every default check: local resources only,
# metric markers present, JSON-LD that parses, FAQ in sync, anchors intact,
# the CLI name in every title.
write_good_page() {
    local dir="$1"
    cat > "$dir/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>tailroute-cli—Tailscale + VPN coexistence for macOS</title>
<meta property="og:title" content="tailroute-cli—Tailscale + VPN coexistence for macOS">
<meta name="twitter:title" content="tailroute-cli—Tailscale + VPN coexistence for macOS">
<link rel="icon" href="favicon.svg">
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"SoftwareApplication","name":"tailroute-cli","softwareVersion":"0.8.17"}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[
{"@type":"Question","name":"Does it phone home?","acceptedAnswer":{"@type":"Answer","text":"No."}},
{"@type":"Question","name":"What about the “curly” dash — question?","acceptedAnswer":{"@type":"Answer","text":"Yes."}}
]}
</script>
</head>
<body>
<nav><a href="#faq">FAQ</a></nav>
<main id="top">
<section id="features"><h2>How it works</h2></section>
<section id="proof"></section>
<section id="core"></section>
<section id="limits"></section>
<section id="faq">
<details class="q"><summary>Does it phone home? <span class="pm">+</span></summary><div>No.</div></details>
<details class="q"><summary>What about the &ldquo;curly&rdquo; dash &mdash; question? <span class="pm">+</span></summary><div>Yes.</div></details>
</section>
<section id="support"></section>
</main>
<footer><p><span data-metric="updated"></span></p><dl><dd data-metric="releases"><i>7</i></dd></dl></footer>
</body>
</html>
HTML
    add_region_markers "$dir"
    write_tokens_css "$dir"
}

# The good page plus everything --strict wants: the install anchor, a clean
# style block, an install component with its activation line, and the
# Gatekeeper disclosure.
write_strict_clean_page() {
    local dir="$1"
    write_good_page "$dir"
    insert_before_body_end "$dir" '<section id="install"></section>
<style>
.pi { font-size: 1em; color: currentColor; border: 1px solid var(--line); }
</style>
<div data-install>
  <button type="button" role="tab" aria-selected="true" aria-controls="panel-cli">CLI daemon</button>
  <div role="tabpanel" id="panel-cli"><code>brew install shrwnsan/tap/tailroute-cli</code><p>Then verify with <code>tailroute status</code>.</p></div>
</div>
<p class="gk-note">The app isn&#39;t notarized yet. The first time you open it, macOS asks you to approve it in System Settings &rarr; Privacy &amp; Security &rarr; Open Anyway.</p>'
}

insert_before_body_end() {
    local dir="$1"
    local snippet="$2"
    python3 - "$dir/index.html" "$snippet" <<'PY'
import sys

path, snippet = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
assert "</body>" in text
open(path, "w", encoding="utf-8").write(text.replace("</body>", snippet + "\n</body>"))
PY
}

replace_once() {
    local dir="$1"
    local old="$2"
    local new="$3"
    python3 - "$dir/index.html" "$old" "$new" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
assert old in text, "replace_once: needle not found"
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

REGION_NAMES=(assets meta nav hero features proof core limits faq support finale footer)

region_marker_lines() {
    local name
    for name in "${REGION_NAMES[@]}"; do
        printf '<!-- region:%s owner:lead --><!-- /region:%s -->\n' "$name" "$name"
    done
}

# Insert a balanced set of region markers in the expected order after <body>.
# The checker enforces regions, so every fixture page carries the full set.
add_region_markers() {
    local dir="$1"
    local markers
    markers=$(region_marker_lines)
    python3 - "$dir/index.html" "$markers" <<'PY'
import sys

path, markers = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
assert "<body>" in text
open(path, "w", encoding="utf-8").write(text.replace("<body>", "<body>\n" + markers, 1))
PY
}

# The good page plus a balanced set of region markers in the expected order.
# (The base fixture carries the markers since the regions check turned on.)
write_region_page() {
    local dir="$1"
    write_good_page "$dir"
}

# ---------------------------------------------------------------------------
# Whole-run behaviour
# ---------------------------------------------------------------------------

test_clean_page_passes_default_checks() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC" "expected the clean fixture to pass: $CHECK_OUT"
    assert_contains "OK 9 checks" "$CHECK_OUT"
}

test_clean_page_passes_strict_checks() {
    local dir
    dir=$(make_fixture)
    write_strict_clean_page "$dir"
    run_checker "$dir" --strict
    assert_eq "0" "$CHECK_RC" "expected the strict-clean fixture to pass: $CHECK_OUT"
    assert_contains "OK 18 checks" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# third-party
# ---------------------------------------------------------------------------

test_third_party_flags_google_fonts_link() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    python3 - "$dir/index.html" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
link = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=X&display=swap">'
open(path, "w", encoding="utf-8").write(text.replace("</head>", link + "\n</head>"))
PY
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL third-party" "$CHECK_OUT"
}

test_third_party_passes_on_local_resources() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL third-party" "$CHECK_OUT"
}

test_third_party_allows_first_party_analytics_ingest() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    python3 - "$dir/index.html" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
script = '<script defer data-domain="tailroute.app" src="https://pulse.tailroute.app/js/script.js"></script>'
open(path, "w", encoding="utf-8").write(text.replace("</head>", script + "\n</head>"))
PY
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC" "the first-party Plausible ingest must pass: $CHECK_OUT"
    assert_not_contains "FAIL third-party" "$CHECK_OUT"
}

test_third_party_still_flags_third_party_analytics() {
    # Only the self-hosted first-party ingest (pulse.tailroute.app, same
    # registrable domain) is allowed; the SaaS host is third-party. The
    # ingest must never be CDN-proxied instead: a proxy challenges
    # cross-origin event POSTs and pageviews drop silently.
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    python3 - "$dir/index.html" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
script = '<script defer data-domain="tailroute.app" src="https://plausible.io/js/script.js"></script>'
open(path, "w", encoding="utf-8").write(text.replace("</head>", script + "\n</head>"))
PY
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL third-party" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------

test_metrics_flags_missing_marker() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<dd data-metric="releases"><i>7</i></dd>' "<dd></dd>"
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL metrics" "$CHECK_OUT"
}

test_metrics_passes_when_markers_present() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL metrics" "$CHECK_OUT"
}

test_metrics_strict_flags_duplicate_marker() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</body>' '<span data-metric="updated"></span></body>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL metrics" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# jsonld
# ---------------------------------------------------------------------------

test_jsonld_flags_malformed_block() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</head>' '<script type="application/ld+json">{"@type":</script></head>'
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL jsonld" "$CHECK_OUT"
}

test_jsonld_passes_when_blocks_parse() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL jsonld" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# faq-sync
# ---------------------------------------------------------------------------

test_faq_sync_flags_mismatch() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<summary>Does it phone home?' '<summary>Does it call home at night?'
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL faq-sync" "$CHECK_OUT"
}

test_faq_sync_passes_on_match() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL faq-sync" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# anchors
# ---------------------------------------------------------------------------

test_anchors_flags_broken_hash() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</body>' '<a href="#nope">broken</a></body>'
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL anchors" "$CHECK_OUT"
}

test_anchors_flags_missing_required_id() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<section id="limits"></section>' "<section></section>"
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL anchors" "$CHECK_OUT"
}

test_anchors_resolves_docs_fragment() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    mkdir -p "$dir/docs"
    cat > "$dir/docs/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><title>tailroute-cli manual</title>
<meta property="og:title" content="tailroute-cli manual"></head>
<body><main><h2 id="diagnostics">Diagnostics</h2></main></body>
</html>
HTML
    replace_once "$dir" '</body>' '<a href="docs/#diagnostics">Diagnostics</a></body>'
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL anchors" "$CHECK_OUT"
}

test_anchors_flags_unresolvable_docs_fragment() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    mkdir -p "$dir/docs"
    cat > "$dir/docs/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><title>tailroute-cli manual</title>
<meta property="og:title" content="tailroute-cli manual"></head>
<body><main></main></body>
</html>
HTML
    replace_once "$dir" '</body>' '<a href="docs/#diagnostics">Diagnostics</a></body>'
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL anchors" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# names
# ---------------------------------------------------------------------------

test_names_flags_generic_twitter_title() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<meta name="twitter:title" content="tailroute-cli—' '<meta name="twitter:title" content="tailroute —'
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL names" "$CHECK_OUT"
}

test_names_passes_when_cli_named() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL names" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# banned
# ---------------------------------------------------------------------------

test_banned_flags_retired_claim() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    insert_before_body_end "$dir" "<p>The usual escape is a \$100 travel router.</p>"
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL banned" "$CHECK_OUT"
}

test_banned_passes_when_absent() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL banned" "$CHECK_OUT"
}

test_banned_strict_flags_retired_hook() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</body>' '<p>Get started in two minutes.</p></body>'
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC" "the hook must pass in default mode: $CHECK_OUT"
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL banned" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# strict-only design-system checks
# ---------------------------------------------------------------------------

test_reveal_flags_entrance_class() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<section id="features">' '<section id="features" class="reveal d1">'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL reveal" "$CHECK_OUT"
}

test_heading_accent_flags_em_in_heading() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '<h2>How it works</h2>' '<h2>How it <em>works.</em></h2>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL heading-accent" "$CHECK_OUT"
}

test_raw_colour_flags_hex_in_style() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</head>' '<style>.a { color: #c6f24e; }</style></head>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL raw-colour" "$CHECK_OUT"
}

test_font_size_flags_px_in_style() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</head>' '<style>.a { font-size: 13px; }</style></head>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL font-size" "$CHECK_OUT"
}

test_uppercase_flags_text_transform() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</head>' '<style>.a { text-transform: uppercase; }</style></head>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL uppercase" "$CHECK_OUT"
}

test_img_flags_missing_attributes() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</body>' '<img src="shot.png"></body>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL img" "$CHECK_OUT"
}

test_img_passes_with_attributes() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</body>' '<img src="shot.png" alt="App menu" width="320" height="200"></body>'
    run_checker "$dir" --strict
    assert_not_contains "FAIL img" "$CHECK_OUT"
}

test_activation_flags_missing_status_line() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    insert_before_body_end "$dir" '<div data-install><button role="tab" aria-selected="true" aria-controls="panel">CLI</button><div id="panel">brew install</div></div>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL activation" "$CHECK_OUT"
}

test_gk_note_flags_missing_sentence() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    insert_before_body_end "$dir" '<p class="gk-note">Coming soon.</p>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL gk-note" "$CHECK_OUT"
}

test_legacy_tokens_flags_old_token_names() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    replace_once "$dir" '</head>' '<style>.a { color: var(--lime); }</style></head>'
    run_checker "$dir" --strict
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL legacy-tokens" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# contrast
# ---------------------------------------------------------------------------

test_contrast_passes_on_token_palette() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    run_checker "$dir"
    assert_eq "0" "$CHECK_RC"
    assert_not_contains "FAIL contrast" "$CHECK_OUT"
}

test_contrast_flags_low_ratio_behind_alias() {
    local dir
    dir=$(make_fixture)
    write_good_page "$dir"
    python3 - "$dir/assets/css/tokens.css" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "--faint-ink: #8a887d;"
new = "--faint-ink: #747267;"
assert old in text, "contrast fixture: --faint-ink line not found"
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
    run_checker "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL contrast" "$CHECK_OUT"
}

# ---------------------------------------------------------------------------
# regions (enforced; --region scopes the strict checks)
# ---------------------------------------------------------------------------

test_region_flag_scopes_strict_checks() {
    local dir
    dir=$(make_fixture)
    write_strict_clean_page "$dir"
    run_checker "$dir" --strict --region hero
    assert_eq "0" "$CHECK_RC" "--region scopes the strict checks to one region: $CHECK_OUT"
    assert_contains "OK 17 checks" "$CHECK_OUT"
}

test_regions_pass_when_enabled() {
    local dir
    dir=$(make_fixture)
    write_region_page "$dir"
    run_checker_regions_on "$dir"
    assert_eq "0" "$CHECK_RC" "expected balanced markers in order to pass: $CHECK_OUT"
    assert_contains "OK 9 checks" "$CHECK_OUT"
    assert_not_contains "FAIL regions" "$CHECK_OUT"
}

test_regions_flags_unbalanced_markers() {
    local dir
    dir=$(make_fixture)
    write_region_page "$dir"
    python3 - "$dir/index.html" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace("<body>", "<body>\n<!-- /region:ghost -->", 1))
PY
    run_checker_regions_on "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL regions" "$CHECK_OUT"
}

test_regions_flags_wrong_order() {
    local dir
    dir=$(make_fixture)
    write_region_page "$dir"
    replace_once "$dir" '<!-- region:proof owner:lead --><!-- /region:proof -->
<!-- region:core owner:lead --><!-- /region:core -->' '<!-- region:core owner:lead --><!-- /region:core -->
<!-- region:proof owner:lead --><!-- /region:proof -->'
    run_checker_regions_on "$dir"
    assert_eq "1" "$CHECK_RC"
    assert_contains "FAIL regions" "$CHECK_OUT"
}

test_regions_allow_one_level_of_nesting() {
    local dir
    dir=$(make_fixture)
    write_region_page "$dir"
    replace_once "$dir" '<!-- region:hero owner:lead --><!-- /region:hero -->' '<!-- region:hero owner:lead --><!-- region:diagram owner:lead --><!-- /region:diagram --><!-- /region:hero -->'
    run_checker_regions_on "$dir"
    assert_eq "0" "$CHECK_RC" "expected one nested region to pass: $CHECK_OUT"
    assert_not_contains "FAIL regions" "$CHECK_OUT"
}
