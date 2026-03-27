#!/usr/bin/env bash
# run-tests.sh — Test harness for tailroute
#
# Usage: ./run-tests.sh [test-file...]
#
# If no test files are specified, runs all tests/test-*.sh files.
# Each test file sources the library under test and defines test_* functions.
#
# Exit codes:
#   0 - all tests passed
#   1 - one or more tests failed
#
# Test file convention:
#   - Named test-<library>.sh (e.g., test-lib-validate.sh)
#   - Each test is a function named test_<description>
#   - Use assert_* helpers for assertions

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Current test context
CURRENT_TEST_FILE=""
CURRENT_TEST_NAME=""

# -----------------------------------------------------------------------------
# Assert helpers (sourced by test files)
# -----------------------------------------------------------------------------

# Assert two values are equal
# Usage: assert_eq "expected" "actual" ["message"]
assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"

    if [[ "$expected" != "$actual" ]]; then
        _assert_fail "Expected '$expected' but got '$actual'. $message"
    fi
}

# Assert command succeeds (exit code 0)
# Usage: assert_ok command [args...]
assert_ok() {
    if ! "$@" >/dev/null 2>&1; then
        _assert_fail "Command failed: $*"
    fi
}

# Assert command fails (non-zero exit code)
# Usage: assert_fail command [args...]
assert_fail() {
    if "$@" >/dev/null 2>&1; then
        _assert_fail "Command succeeded but expected failure: $*"
    fi
}

# Assert output matches regex
# Usage: assert_match "pattern" "output"
assert_match() {
    local pattern="$1"
    local output="$2"

    if [[ ! "$output" =~ $pattern ]]; then
        _assert_fail "Output does not match pattern '$pattern': $output"
    fi
}

# Assert output contains substring
# Usage: assert_contains "substring" "output"
assert_contains() {
    local substring="$1"
    local output="$2"

    if [[ "$output" != *"$substring"* ]]; then
        _assert_fail "Output does not contain '$substring': $output"
    fi
}

# Internal: record assertion failure
_assert_fail() {
    local message="$1"
    echo -e "${RED}FAIL${NC}: $CURRENT_TEST_NAME"
    echo "  $message"
    echo ""
    # Use a subshell to exit just the test function
    kill -s SIGUSR1 $$
}

# Trap SIGUSR1 to catch assertion failures
trap '_test_failed=1' SIGUSR1

# -----------------------------------------------------------------------------
# Run a single test file
# -----------------------------------------------------------------------------
run_test_file() {
    local test_file="$1"
    CURRENT_TEST_FILE="$test_file"

    echo -e "\n${YELLOW}Running: $test_file${NC}"

    # Get functions before sourcing
    local funcs_before
    funcs_before=$(declare -F | awk '{print $3}')

    # Source the test file to get test functions
    # shellcheck source=/dev/null
    source "$test_file"

    # Get functions after sourcing and find the difference
    local funcs_after
    funcs_after=$(declare -F | awk '{print $3}')
    
    # Find new test functions (only those defined in this test file)
    local test_functions
    test_functions=$(comm -23 <(echo "$funcs_after" | sort) <(echo "$funcs_before" | sort) | grep -E '^test_' || true)

    if [[ -z "$test_functions" ]]; then
        echo "  No test functions found in $test_file"
        return
    fi

    for test_func in $test_functions; do
        CURRENT_TEST_NAME="$test_func"
        ((TESTS_RUN++)) || true

        # Run test in subshell with trap for assertions
        _test_failed=0
        if ( trap '_test_failed=1' SIGUSR1; "$test_func" ) 2>&1; then
            if [[ $_test_failed -eq 0 ]]; then
                ((TESTS_PASSED++)) || true
                echo -e "  ${GREEN}PASS${NC}: $test_func"
            else
                ((TESTS_FAILED++)) || true
            fi
        else
            ((TESTS_FAILED++)) || true
            echo -e "${RED}FAIL${NC}: $test_func (exit code non-zero)"
        fi
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local test_files=("$@")

    # Default to all test files
    if [[ ${#test_files[@]} -eq 0 ]]; then
        mapfile -t test_files < <(find "$SCRIPT_DIR" -name 'test-*.sh' -type f | sort)
    fi

    echo "======================================"
    echo " tailroute test harness"
    echo "======================================"

    # Export assert functions for subshells
    export -f assert_eq assert_ok assert_fail assert_match assert_contains _assert_fail

    # Run each test file
    for test_file in "${test_files[@]}"; do
        if [[ -f "$test_file" ]]; then
            run_test_file "$test_file"
        else
            echo -e "${RED}ERROR${NC}: Test file not found: $test_file"
            ((TESTS_FAILED++)) || true
        fi
    done

    # Summary
    echo ""
    echo "======================================"
    echo " Results"
    echo "======================================"
    echo -e "  Tests run:    $TESTS_RUN"
    echo -e "  ${GREEN}Passed:       $TESTS_PASSED${NC}"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "  ${RED}Failed:       $TESTS_FAILED${NC}"
    else
        echo -e "  Failed:       $TESTS_FAILED"
    fi
    echo ""

    # Exit code
    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
