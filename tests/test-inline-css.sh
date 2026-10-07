#!/usr/bin/env bash
# test-inline-css.sh — Tests for scripts/inline-css.py
#
# Each test writes a small fixture site into a temp dir and runs the inliner
# against it with --root, then asserts on the output file. Run via
# tests/run-tests.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INLINE="$SCRIPT_DIR/../scripts/inline-css.py"

FIXTURES=()

cleanup() {
    if [[ ${#FIXTURES[@]} -gt 0 ]]; then
        rm -rf "${FIXTURES[@]}"
    fi
}
trap cleanup EXIT

make_fixture() {
    local dir
    dir="$(mktemp -d)"
    FIXTURES+=("$dir")
    mkdir -p "$dir/site/assets/css" "$dir/site/assets/js" "$dir/site/assets/fonts"
    cat > "$dir/site/assets/css/a.css" <<'EOF'
body { color: #f0efe8; background: url("../fonts/display.woff2") no-repeat; }
EOF
    printf 'p { color: var(--text-dim); font-size: 16.5px; }\n' > "$dir/site/assets/css/b.css"
    printf 'dummy-woff2\n' > "$dir/site/assets/fonts/display.woff2"
    printf '<!doctype html>\n<html lang="en">\n<head>\n' > "$dir/site/index.html"
    cat >> "$dir/site/index.html" <<'EOF'
    <script>document.documentElement.classList.add("js")</script>
    <link rel="preload" href="assets/fonts/display.woff2" as="font" type="font/woff2" crossorigin>
    <!-- region:assets owner:lead -->
    <link rel="stylesheet" href="assets/css/a.css">
    <link rel="stylesheet" href="assets/css/b.css">
    <!-- /region:assets -->
</head>
<body>
<!-- region:hero owner:T-720 -->
  <main id="top"></main>
<!-- /region:hero -->
</body>
</html>
EOF
    printf '%s' "$dir"
}

test_inlines_links_into_single_style() {
    local dir
    dir="$(make_fixture)"
    assert_ok python3 "$INLINE" --root "$dir/site"
    local out
    out="$(cat "$dir/site/index.html")"
    if grep -q 'rel="stylesheet"' "$dir/site/index.html"; then
        return 1
    fi
    assert_contains "<style>" "$out"
    assert_contains "url(\"assets/fonts/display.woff2\")" "$out"
}

test_css_text_equals_concatenated_files() {
    local dir
    dir="$(make_fixture)"
    assert_ok python3 "$INLINE" --root "$dir/site"
    # extract the <style> block and compare with the concatenated sources
    python3 - "$dir" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
html = (d / "site/index.html").read_text()
style = html.split("<style>")[1].split("</style>")[0].strip()
a = (d / "site/assets/css/a.css").read_text()
b = (d / "site/assets/css/b.css").read_text()
expected = (a.replace('url("../fonts/display.woff2")', 'url("assets/fonts/display.woff2")') + b).strip()
raise SystemExit(0 if style == expected else 1)
PY
}

test_preserves_cascade_order() {
    local dir
    dir="$(make_fixture)"
    assert_ok python3 "$INLINE" --root "$dir/site"
    local a_pos b_pos
    a_pos=$(grep -bo 'body {' "$dir/site/index.html" | head -1 | cut -d: -f1)
    b_pos=$(grep -bo 'p { color: var' "$dir/site/index.html" | head -1 | cut -d: -f1)
    if [[ -z "$a_pos" || -z "$b_pos" ]]; then
        return 1
    fi
    if (( a_pos >= b_pos )); then
        return 1
    fi
}

test_idempotent_second_run_no_change() {
    local dir
    dir="$(make_fixture)"
    assert_ok python3 "$INLINE" --root "$dir/site"
    cp "$dir/site/index.html" "$dir/first.html"
    assert_ok python3 "$INLINE" --root "$dir/site"
    assert_ok cmp "$dir/first.html" "$dir/site/index.html"
}

test_noop_when_no_stylesheets() {
    local dir
    dir="$(make_fixture)"
    python3 - "$dir" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / "site/index.html"
html = p.read_text()
p.write_text(re.sub(r' {2}<link rel="stylesheet"[^\n]*\n', "", html))
PY
    cp "$dir/site/index.html" "$dir/before.html"
    assert_ok python3 "$INLINE" --root "$dir/site"
    assert_ok cmp "$dir/before.html" "$dir/site/index.html"
}

test_keeps_preload_js_and_region_markers() {
    local dir
    dir="$(make_fixture)"
    assert_ok python3 "$INLINE" --root "$dir/site"
    local out
    out="$(cat "$dir/site/index.html")"
    assert_contains 'rel="preload"' "$out"
    assert_contains 'classList.add("js")' "$out"
    assert_contains "<!-- region:assets" "$out"
    assert_contains "<!-- /region:assets -->" "$out"
    assert_contains "<!-- region:hero" "$out"
}

test_fails_on_missing_css_file() {
    local dir
    dir="$(make_fixture)"
    rm "$dir/site/assets/css/b.css"
    assert_fail python3 "$INLINE" --root "$dir/site"
}

test_fails_on_missing_page() {
    local dir
    dir="$(mktemp -d)"
    FIXTURES+=("$dir")
    assert_fail python3 "$INLINE" --root "$dir/site"
}
