#!/usr/bin/env bash
# test-install.sh — Tests for daemon install file staging (do_install helpers)
#
# The CLI is supported from two layouts (see tailroute.sh LIB_DIR resolution):
#   - source checkout: libs beside bin/tailroute.sh
#   - Homebrew prefix: libs in ../lib
# Install must stage libraries from $LIB_DIR so both layouts work.

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
# install_lib_files tests
# =============================================================================

# Regression: `sudo tailroute install` from a Homebrew install copied zero
# libraries (they live in ../lib, not beside the script), then failed the
# integrity manifest with "shasum: /usr/local/bin/lib-*.sh: No such file".
test_install_lib_files_stages_from_lib_dir() {
    _load_tailroute
    local dest lib_src
    dest="$(mktemp -d)"
    lib_src="$(mktemp -d)"
    echo "lib-log-stub" > "$lib_src/lib-log.sh"
    LIB_DIR="$lib_src"
    chown() { :; }  # do_install runs as root; tests are non-root

    install_lib_files "$dest"

    assert_eq "lib-log-stub" "$(cat "$dest/lib-log.sh")" "lib staged from LIB_DIR"
    rm -rf "$dest" "$lib_src"
}

test_install_lib_files_keeps_newer_destination_file() {
    _load_tailroute
    local dest lib_src
    dest="$(mktemp -d)"
    lib_src="$(mktemp -d)"
    echo "dest-version" > "$dest/lib-log.sh"
    touch -t 202001010000 "$dest/lib-log.sh"
    echo "src-version" > "$lib_src/lib-log.sh"
    touch -t 199901010000 "$lib_src/lib-log.sh"
    LIB_DIR="$lib_src"
    chown() { :; }

    install_lib_files "$dest"

    assert_eq "dest-version" "$(cat "$dest/lib-log.sh")" "older source must not overwrite newer dest"
    rm -rf "$dest" "$lib_src"
}

test_install_lib_files_fails_when_no_libs_found() {
    _load_tailroute
    local dest lib_src output
    dest="$(mktemp -d)"
    lib_src="$(mktemp -d)"
    LIB_DIR="$lib_src"
    chown() { :; }

    if output=$(install_lib_files "$dest" 2>&1); then
        _assert_fail "install_lib_files succeeded with no lib-*.sh in LIB_DIR"
    fi
    assert_contains "no lib-*.sh files found" "$output"
    rm -rf "$dest" "$lib_src"
}

# do_install must delegate lib staging to install_lib_files ($LIB_DIR glob);
# a regression to the script_dir glob would rebreak Homebrew installs.
test_do_install_stages_libs_via_install_lib_files() {
    local script="$TEST_DIR/../bin/tailroute.sh"
    assert_ok grep -q "install_lib_files /usr/local/bin" "$script" "do_install must call install_lib_files"
    assert_fail grep -q 'for lib in "$script_dir"/lib-.*sh' "$script" "script_dir lib glob must not return"
}
