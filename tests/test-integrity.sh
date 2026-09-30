#!/usr/bin/env bash
# test-integrity.sh — Tests for install-time integrity verification (tailroute.sh)
#
# Covers generate_checksum_manifest / verify_checksum_manifest /
# verify_code_signature, which gate the root daemon before lib files are
# sourced (see SECURITY.md — Installed File Integrity).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tailroute.sh bakes lib state (e.g. LOCK_FILE) at source time. The harness
# runs each test in its own subshell, so loading inside the test confines
# that state and cannot leak into other test files, whatever the run order.
_load_tailroute() {
    # shellcheck source=../bin/tailroute.sh
    source "$TEST_DIR/../bin/tailroute.sh"
}

# =============================================================================
# generate_checksum_manifest tests
# =============================================================================

test_generate_manifest_creates_expected_format() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "wrapper-content" > "$dir/tailroute"
    echo "lib-content" > "$dir/lib-log.sh"

    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/lib-log.sh"

    [[ -f "$dir/installed.checksums" ]] || { echo "manifest not created"; return 1; }
    assert_eq 2 "$(wc -l < "$dir/installed.checksums" | tr -d ' ')" "manifest line count"

    # Each line must be "<64 hex chars>  <path>" (shasum output format)
    assert_match '^[a-f0-9]{64}  .*/tailroute$' "$(sed -n 1p "$dir/installed.checksums")"
    assert_match '^[a-f0-9]{64}  .*/lib-log\.sh$' "$(sed -n 2p "$dir/installed.checksums")"
    rm -rf "$dir"
}

test_generate_manifest_overwrites_previous() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "old" > "$dir/file.sh"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/file.sh"

    # New version install: content changes, manifest must be rewritten
    echo "new version content" > "$dir/file.sh"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/file.sh"

    # New manifest must verify cleanly against the new file
    verify_checksum_manifest "$dir/installed.checksums"
    rm -rf "$dir"
}

# =============================================================================
# verify_checksum_manifest tests
# =============================================================================

test_verify_manifest_passes_when_unchanged() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "wrapper" > "$dir/tailroute"
    echo "lib" > "$dir/lib-x.sh"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/lib-x.sh"

    verify_checksum_manifest "$dir/installed.checksums"
    rm -rf "$dir"
}

test_verify_manifest_fails_on_modified_file() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "original" > "$dir/lib-x.sh"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/lib-x.sh"
    echo "tampered payload" > "$dir/lib-x.sh"

    local output
    if output=$(verify_checksum_manifest "$dir/installed.checksums" 2>&1); then
        _assert_fail "verification passed despite modified file"
    fi
    assert_contains "CRITICAL" "$output"
    assert_contains "checksum mismatch" "$output"
    rm -rf "$dir"
}

test_verify_manifest_skips_missing_entries() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "wrapper" > "$dir/tailroute"
    echo "ghost" > "$dir/ghost"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/ghost"

    # A foreign/vestigial-layout entry whose file is gone after install
    # (issue #47: the standalone install recorded /usr/local/bin/tailroute;
    # after that layout was retired the BREW daemon crash-looped on the
    # now-unreadable entry). A missing foreign-layout file is not evidence
    # of tampering with this install — it is never executed by this
    # invocation.
    rm "$dir/ghost"

    # assert_ok, not a bare call: the harness runs test subshells inside an
    # if-condition where set -e death does not fail a test — only assertions do.
    assert_ok verify_checksum_manifest "$dir/installed.checksums"
    rm -rf "$dir"
}

test_verify_manifest_missing_active_layout_entry_fails_closed() {
    # SCRIPT_DIR/LIB_DIR come from the sourced script's own location, so pin
    # the guard on the real resolution path: stage a standalone-style layout
    # (script + libs beside it) in a scratch dir, source THAT copy, and
    # record its manifest — then delete the listed wrapper. The entry sits
    # inside this invocation's layout, so the missing-entry skip must not
    # apply: the SCRIPT_DIR→LIB_DIR fallback would otherwise silently source
    # a planted stand-in from the fallback dir as root (#47 review).
    local dir
    dir="$(mktemp -d)"
    cp "$TEST_DIR/../bin/tailroute.sh" "$dir/"
    cp "$TEST_DIR/../bin/"lib-*.sh "$dir/"
    # shellcheck source=/dev/null
    source "$dir/tailroute.sh"

    echo "wrapper" > "$dir/tailroute"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/lib-log.sh"
    rm "$dir/tailroute"

    local output
    if output=$(verify_checksum_manifest "$dir/installed.checksums" 2>&1); then
        _assert_fail "verification passed despite deleted active-layout entry"
    fi
    assert_contains "CRITICAL" "$output"
    assert_contains "missing from this install's layout" "$output"
    rm -rf "$dir"
}

test_verify_manifest_all_entries_missing_skips() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "wrapper" > "$dir/tailroute"
    echo "lib" > "$dir/lib-x.sh"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/lib-x.sh"

    # The whole recorded layout retired: no entries remain, so there is
    # nothing verifiable — the same semantics as an absent manifest (#47).
    rm "$dir/tailroute" "$dir/lib-x.sh"

    assert_ok verify_checksum_manifest "$dir/installed.checksums"
    rm -rf "$dir"
}

test_verify_manifest_missing_entry_does_not_mask_tampering() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "original" > "$dir/lib-x.sh"
    echo "wrapper" > "$dir/tailroute"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute" "$dir/lib-x.sh"
    rm "$dir/tailroute"
    echo "tampered payload" > "$dir/lib-x.sh"

    # The missing-entry skip must not swallow a real mismatch: a manifest
    # mixing one gone file with one tampered file still refuses to run.
    local output
    if output=$(verify_checksum_manifest "$dir/installed.checksums" 2>&1); then
        _assert_fail "verification passed despite tampered file alongside missing entry"
    fi
    assert_contains "CRITICAL" "$output"
    assert_contains "checksum mismatch" "$output"
    rm -rf "$dir"
}

test_verify_manifest_fails_on_malformed_line() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    echo "wrapper" > "$dir/tailroute"
    generate_checksum_manifest "$dir/installed.checksums" "$dir/tailroute"

    # A torn write or hand edit: a line without the "<64 hex>  <path>" shape.
    # macOS shasum exits 0 on MIXED valid+malformed input ("1 line is
    # improperly formatted"), so the pre-filter must refuse outright —
    # passing malformed lines through to shasum would silently accept them.
    printf 'not-a-checksum-line\n' >> "$dir/installed.checksums"

    local output
    if output=$(verify_checksum_manifest "$dir/installed.checksums" 2>&1); then
        _assert_fail "verification passed despite malformed manifest line"
    fi
    assert_contains "CRITICAL" "$output"
    assert_contains "Malformed line" "$output"
    rm -rf "$dir"
}

test_verify_manifest_absent_manifest_skips() {
    _load_tailroute
    # Dev checkout / pre-install: no manifest, nothing to verify
    local dir
    dir="$(mktemp -d)"
    verify_checksum_manifest "$dir/no-such-manifest"
    rm -rf "$dir"
}

# =============================================================================
# verify_code_signature tests
# =============================================================================

test_verify_signature_absent_binary_skips() {
    _load_tailroute
    # The proxy is optional; missing binary is not an integrity failure
    local dir
    dir="$(mktemp -d)"
    verify_code_signature "$dir/no-such-binary"
    rm -rf "$dir"
}

test_verify_signature_valid_apple_binary_passes() {
    _load_tailroute
    verify_code_signature /usr/bin/codesign
}

test_verify_signature_valid_adhoc_binary_passes() {
    _load_tailroute
    # Go builds are adhoc/linker-signed; a copy keeps a valid signature
    local dir
    dir="$(mktemp -d)"
    cp /usr/bin/true "$dir/signed-copy"
    verify_code_signature "$dir/signed-copy"
    rm -rf "$dir"
}

test_verify_signature_tampered_binary_fails() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    cp /usr/bin/true "$dir/tampered"
    printf 'X' >> "$dir/tampered"

    local output
    if output=$(verify_code_signature "$dir/tampered" 2>&1); then
        _assert_fail "signature verification passed despite tampered binary"
    fi
    assert_contains "CRITICAL" "$output"
    rm -rf "$dir"
}

test_verify_signature_unsigned_file_fails() {
    _load_tailroute
    local dir
    dir="$(mktemp -d)"
    printf '#!/bin/sh\necho hi\n' > "$dir/unsigned.sh"
    chmod +x "$dir/unsigned.sh"

    if verify_code_signature "$dir/unsigned.sh"; then
        _assert_fail "signature verification passed for unsigned file"
    fi
    rm -rf "$dir"
}
