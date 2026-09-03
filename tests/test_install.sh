#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR

# shellcheck source=tests/lib/assert.sh
source "$TEST_DIR/lib/assert.sh"

export VPS_INSTALL_LIBRARY=1
# shellcheck source=install.sh
source "$REPO_DIR/install.sh"

test_parent_arguments() {
    local rendered
    USERNAME=igor
    SSH_PORT=2222
    rendered="$(build_ssh_child_args)"
    assert_contains "$rendered" '--user' "parent sends --user"
    assert_contains "$rendered" 'igor' "parent sends username value"
    assert_contains "$rendered" '--port' "parent sends --port"
    assert_contains "$rendered" '2222' "parent sends port value"
}

test_parent_collects_ssh_values_for_post_update_verification() {
    local status=0
    USERNAME=''
    SSH_PORT=''
    prompt_ssh_inputs <<< $'igor\n2222\n' || status=$?
    assert_status 0 "$status" "interactive parent input collection succeeds"
    assert_eq igor "$USERNAME" "parent retains prompted username"
    assert_eq 2222 "$SSH_PORT" "parent retains prompted port for the later verify-only pass"
}

test_parent_rejects_root_target() {
    local status=0
    (USERNAME=root; SSH_PORT=2222; validate_inputs) >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "parent rejects root before invoking the SSH child"
}

test_parent_rejects_missing_option_values() {
    local status=0
    (local ssh=false chat=false update=false docker=false; : "$ssh" "$chat" "$update" "$docker"; parse_args ssh chat update docker --username) >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "parent rejects --username without a value"
    status=0
    (local ssh=false chat=false update=false docker=false; : "$ssh" "$chat" "$update" "$docker"; parse_args ssh chat update docker --ssh-port) >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "parent rejects --ssh-port without a value"
}

test_parent_validates_port_as_decimal() {
    local status=0
    (USERNAME=igor; SSH_PORT=08; validate_inputs) >/dev/null 2>&1 || status=$?
    assert_status 0 "$status" "parent accepts a decimal port with a leading zero"
    status=0
    (USERNAME=igor; SSH_PORT=99999999999999999999; validate_inputs) >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "parent rejects oversized port values without arithmetic overflow"
}

test_digest_verification() {
    local temp digest status
    temp="$(mktemp)"
    trap 'rm -f "$temp"' RETURN
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$temp"
    digest="$(sha256sum "$temp" | awk '{print $1}')"
    status=0
    verify_script_digest "$temp" "$digest" || status=$?
    assert_status 0 "$status" "expected digest is accepted"
    status=0
    verify_script_digest "$temp" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || status=$?
    assert_status 1 "$status" "digest mismatch fails closed"
}

test_pinned_child_digests_match_repository() {
    assert_eq "$SSH_SCRIPT_SHA256" "$(sha256sum "$REPO_DIR/scripts/ssh-setup.sh" | awk '{print $1}')" "pinned SSH child digest matches repository bytes"
    assert_eq "$CHAT_ID_SHA256" "$(sha256sum "$REPO_DIR/scripts/chat-id.sh" | awk '{print $1}')" "pinned chat child digest matches repository bytes"
    assert_eq "$AUTO_UPDATE_SHA256" "$(sha256sum "$REPO_DIR/scripts/auto_update_ubuntu.sh" | awk '{print $1}')" "pinned update child digest matches repository bytes"
    assert_eq "$DOCKER_SCRIPT_SHA256" "$(sha256sum "$REPO_DIR/scripts/install-docker.sh" | awk '{print $1}')" "pinned Docker child digest matches repository bytes"
}

test_error_counter_survives_strict_mode() {
    local value
    errors=0
    increment_errors
    increment_errors
    value="$errors"
    assert_eq 2 "$value" "strict-mode-safe error counter increments"
}

test_final_status_reports_child_failures() {
    local status=0
    errors=2
    final_result_status || status=$?
    assert_status 1 "$status" "parent exits nonzero when any optional child failed"
    errors=0
    status=0
    final_result_status || status=$?
    assert_status 0 "$status" "parent exits zero only when every selected child succeeded"
}

test_help_does_not_require_root_or_network() {
    local output status
    status=0
    output="$(env -u VPS_INSTALL_LIBRARY bash "$REPO_DIR/install.sh" --help 2>&1)" || status=$?
    assert_status 0 "$status" "--help succeeds as an unprivileged user"
    assert_contains "$output" 'ИСПОЛЬЗОВАНИЕ' "--help prints usage"
}

test_safe_execution_order() {
    local plan
    plan="$(build_execution_plan true true true true)"
    assert_eq $'ssh\nsystem-update\nssh-verify\nchat\nauto-update\ndocker' "$plan" "SSH migration precedes package mutation and gets post-update verification"
}

test_safe_update_arguments() {
    local args
    args="$(build_update_arguments)"
    assert_contains "$args" 'upgrade' "system update retains normal package upgrades"
    assert_contains "$args" '--with-new-pkgs' "system update allows required dependencies without dist-upgrade"
    assert_not_contains "$args" 'dist-upgrade' "system update avoids distribution-level mutation"
    assert_not_contains "$args" 'autoremove' "system update never autoremove-purges access packages"
}

test_automation_confirmation_gate() {
    local status=0
    VPS_AUTO_CONFIRM=true confirm_execution </dev/null || status=$?
    assert_status 0 "$status" "automation mode skips only the parent confirmation prompt"
}

test_parent_arguments
test_parent_collects_ssh_values_for_post_update_verification
test_parent_rejects_root_target
test_parent_rejects_missing_option_values
test_parent_validates_port_as_decimal
test_digest_verification
test_pinned_child_digests_match_repository
test_error_counter_survives_strict_mode
test_final_status_reports_child_failures
test_help_does_not_require_root_or_network
test_safe_execution_order
test_safe_update_arguments
test_automation_confirmation_gate
finish_tests
