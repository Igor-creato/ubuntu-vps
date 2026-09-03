#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR

# shellcheck source=tests/lib/assert.sh
source "$TEST_DIR/lib/assert.sh"

test_web_installers_do_not_activate_firewall() {
    local script body
    for script in scripts/apache-wordpress.sh scripts/lamp-wp.sh; do
        body="$(<"$REPO_DIR/$script")"
        assert_not_contains "$body" 'ufw --force enable' "$script does not unexpectedly enable UFW"
        assert_not_contains "$body" 'ufw allow ssh' "$script does not assume SSH still uses port 22"
        assert_contains "$body" 'effective_ssh_ports' "$script discovers effective SSH ports before firewall changes"
    done
}

test_docker_user_selection_is_explicit() {
    export VPS_DOCKER_INSTALL_LIBRARY=1
    # shellcheck source=scripts/install-docker.sh
    source "$REPO_DIR/scripts/install-docker.sh"

    local status=0 selected
    TARGET_USER=igor
    selected="$(get_target_user)" || status=$?
    assert_status 0 "$status" "explicit Docker target user is accepted"
    assert_eq igor "$selected" "Docker grants are bound to the selected SSH user"

    assert_contains "$(declare -f get_target_user)" 'EUID -ne 0' "automatic current-user selection is restricted to non-root execution"
    TARGET_USER=''
    SUDO_USER=''
    status=0
    if [[ $EUID -eq 0 ]]; then
        get_target_user >/dev/null || status=$?
        assert_status 1 "$status" "root execution never guesses a Docker user by UID"
    else
        selected="$(get_target_user)" || status=$?
        assert_status 0 "$status" "non-root execution may select its own account"
        assert_eq "$(id -un)" "$selected" "non-root fallback selects only the invoking account"
    fi
}

test_web_installers_do_not_activate_firewall
test_docker_user_selection_is_explicit
finish_tests
