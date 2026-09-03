#!/usr/bin/env bash

set -Eeuo pipefail

TESTS_RUN=0
TESTS_FAILED=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

pass() {
    printf 'PASS: %s\n' "$*"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" == "$expected" ]]; then
        pass "$message"
    else
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$message"
    else
        fail "$message (expected status $expected, got $actual)"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (unexpected '$needle')"
    fi
}

assert_not_line() {
    local text="$1"
    local unexpected="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -Fqx -- "$unexpected" <<<"$text"; then
        fail "$message (unexpected line '$unexpected')"
    else
        pass "$message"
    fi
}

finish_tests() {
    printf '\nTests: %d, failures: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
