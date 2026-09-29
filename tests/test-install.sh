#!/usr/bin/env bash
# test-install.sh — Tests for daemon install file staging (do_install helpers)
# and the daemon's startup staging of the newsyslog rotation config
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

# =============================================================================
# ensure_log_rotation tests
# =============================================================================
# The brew-installed daemon never runs do_install, so it must stage the
# newsyslog config itself at startup — otherwise its log sink grows without
# bound (152MB legacy sink observed; the brew layout silently skipped the
# copy-the-conf install step on 2026-09-24).

test_ensure_log_rotation_stages_conf_when_missing() {
    _load_tailroute
    local src_dir dest_dir
    src_dir="$(mktemp -d)"
    dest_dir="$(mktemp -d)"
    printf 'staged-conf-line\n' > "$src_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_SRC="$src_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_DIR="$dest_dir"
    chown() { :; }  # staging normally runs as root; tests are non-root

    ensure_log_rotation

    assert_eq "staged-conf-line" "$(cat "$dest_dir/tailroute.conf")" "conf staged into empty destination dir"
    rm -rf "$src_dir" "$dest_dir"
}

test_ensure_log_rotation_replaces_stale_conf() {
    _load_tailroute
    local src_dir dest_dir
    src_dir="$(mktemp -d)"
    dest_dir="$(mktemp -d)"
    printf 'staged-conf-line\n' > "$src_dir/tailroute.conf"
    printf 'stale-conf-line\n' > "$dest_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_SRC="$src_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_DIR="$dest_dir"
    chown() { :; }

    ensure_log_rotation

    assert_eq "staged-conf-line" "$(cat "$dest_dir/tailroute.conf")" "stale conf must be replaced by the shipped one"
    rm -rf "$src_dir" "$dest_dir"
}

test_ensure_log_rotation_noop_when_identical() {
    _load_tailroute
    local src_dir dest_dir before after
    src_dir="$(mktemp -d)"
    dest_dir="$(mktemp -d)"
    printf 'identical-conf-line\n' > "$src_dir/tailroute.conf"
    cp "$src_dir/tailroute.conf" "$dest_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_SRC="$src_dir/tailroute.conf"
    TAILROUTE_NEWSYSLOG_DIR="$dest_dir"
    chown() { :; }
    before=$(stat -f %m "$dest_dir/tailroute.conf")
    /bin/sleep 1

    assert_ok ensure_log_rotation

    after=$(stat -f %m "$dest_dir/tailroute.conf")
    assert_eq "$before" "$after" "identical conf must not be rewritten (mtime stable)"
    assert_eq "identical-conf-line" "$(cat "$dest_dir/tailroute.conf")" "content unchanged when identical"
    rm -rf "$src_dir" "$dest_dir"
}

# The shipped rotation config must cover every daemon log sink: the brew-prefix
# daemon log under both Homebrew prefixes (newsyslog skips absent files) and
# the legacy launchd sink. A missing line means unbounded growth on that layout.
test_newsyslog_conf_covers_daemon_log_paths() {
    local conf="$TEST_DIR/../etc/newsyslog.d/tailroute.conf"
    assert_ok grep -q "/opt/homebrew/var/log/tailroute-daemon.log" "$conf" "brew-prefix (Apple Silicon) daemon log missing"
    assert_ok grep -q "/usr/local/var/log/tailroute-daemon.log" "$conf" "brew-prefix (Intel) daemon log missing"
    assert_ok grep -q "/var/log/tailroute.log" "$conf" "legacy launchd sink missing"
}

# Regression guard: the legacy v0.8.16 line used @midnight as its when-field,
# which newsyslog rejects at parse time ("malformed 'at' value") and drops —
# the whole entry silently never rotated. Apple's own convention for midnight
# is $D0 (rotation fires on size OR daily at midnight).
test_newsyslog_conf_uses_valid_when_fields() {
    local conf="$TEST_DIR/../etc/newsyslog.d/tailroute.conf"
    local path line
    # Data lines only: the header comment cites the rejected token by name.
    if grep -v '^#' "$conf" | grep -q '@midnight'; then
        _assert_fail "@midnight in a data line — not valid newsyslog syntax, entry gets dropped"
    fi
    for path in \
        "/opt/homebrew/var/log/tailroute-daemon.log" \
        "/usr/local/var/log/tailroute-daemon.log" \
        "/var/log/tailroute.log"; do
        line=$(grep -F "$path" "$conf" | head -n 1)
        assert_contains ' $D0 ' "$line" "when-field for $path must be \$D0"
    done
}
