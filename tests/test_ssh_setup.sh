#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR

# shellcheck source=tests/lib/assert.sh
source "$TEST_DIR/lib/assert.sh"

export VPS_SSH_SETUP_LIBRARY=1
# shellcheck source=scripts/ssh-setup.sh
source "$REPO_DIR/scripts/ssh-setup.sh"

test_username_validation() {
    local value status
    for value in igor admin_1 service-user _backup; do
        status=0
        validate_username "$value" || status=$?
        assert_status 0 "$status" "accept valid username $value"
    done
    for value in '' root Root 'bad user' '../root' 'user;id' '-admin'; do
        status=0
        validate_username "$value" || status=$?
        assert_status 1 "$status" "reject invalid username '$value'"
    done
}

test_port_validation() {
    local value status
    for value in 1 22 1024 65535; do
        status=0
        validate_port "$value" || status=$?
        assert_status 0 "$status" "accept valid port $value"
    done
    for value in 0 65536 99999999999999999999 -1 abc '22 '; do
        status=0
        validate_port "$value" || status=$?
        assert_status 1 "$status" "reject invalid port '$value'"
    done
}

test_argument_parsing() {
    reset_cli_state
    parse_args --user igor --port 2222 --public-key-file /tmp/key.pub --enable-ufw --verification-timeout 45
    assert_eq igor "$USERNAME" "parse --user"
    assert_eq 2222 "$SSHD_PORT" "parse --port"
    assert_eq /tmp/key.pub "$PUBLIC_KEY_FILE" "parse --public-key-file"
    assert_eq true "$ENABLE_UFW" "parse --enable-ufw"
    assert_eq 45 "$VERIFICATION_TIMEOUT" "parse verification timeout"
}

test_config_rendering() {
    local stage final
    stage="$(render_stage_config 22 2222 igor)"
    assert_contains "$stage" 'Port 22' "stage keeps old port"
    assert_contains "$stage" 'Port 2222' "stage adds new port"
    assert_contains "$stage" 'Match User igor LocalPort 2222' "stage scopes key-only policy to new endpoint"
    assert_contains "$stage" 'AuthenticationMethods publickey' "stage proves public-key authentication"
    assert_not_contains "$stage" 'PermitRootLogin no' "stage does not disable root recovery"

    final="$(render_final_config 2222)"
    assert_contains "$final" 'Port 2222' "final keeps only new managed port"
    assert_not_line "$final" 'Port 22' "final drops old managed listener"
    assert_contains "$final" 'PasswordAuthentication no' "final disables passwords"
    assert_contains "$final" 'KbdInteractiveAuthentication no' "final disables keyboard interactive"
    assert_contains "$final" 'PermitRootLogin no' "final disables root SSH"
    assert_contains "$final" 'PubkeyAuthentication yes' "final enables public keys"
    assert_contains "$final" 'AuthenticationMethods publickey' "final requires the same key-only method proven during staging"
}

test_uid_zero_alias_validation() {
    local status=0
    target_passwd_record_is_non_root 'toor:x:0:0:root alias:/root:/bin/bash' || status=$?
    assert_status 1 "$status" "an existing UID 0 alias cannot be selected as the hardened user"
    status=0
    target_passwd_record_is_non_root 'igor:x:1001:1001::/home/igor:/bin/bash' || status=$?
    assert_status 0 "$status" "a normal administrative user is accepted"
}

test_key_merge_is_valid_and_idempotent() {
    local temp key_file public_key status lines
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    ssh-keygen -q -t ed25519 -N '' -f "$temp/test-key"
    public_key="$temp/test-key.pub"
    key_file="$temp/authorized_keys"
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusExistingKeyForPreservation existing' > "$key_file"

    status=0
    merge_authorized_keys "$key_file" "$public_key" || status=$?
    assert_status 0 "$status" "merge accepts ssh-keygen-validated public key"
    merge_authorized_keys "$key_file" "$public_key"
    lines="$(grep -Fc "$(cat "$public_key")" "$key_file")"
    assert_eq 1 "$lines" "rerun does not duplicate public key"
    assert_contains "$(cat "$key_file")" 'BogusExistingKeyForPreservation' "existing target keys remain"

    printf '%s\n' 'not-a-public-key' > "$temp/invalid.pub"
    status=0
    merge_authorized_keys "$key_file" "$temp/invalid.pub" || status=$?
    assert_status 1 "$status" "invalid public key is rejected"

    status=0
    merge_authorized_keys "$key_file" "$temp/test-key" || status=$?
    assert_status 1 "$status" "a private SSH key is never copied into authorized_keys"
}

test_runtime_application_modes() {
    local temp output
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    cat > "$temp/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == "is-active" && "$3" == "ssh.socket" ]]; then
    [[ "${FAKE_SOCKET_ACTIVE:-0}" == "1" ]]
    exit
fi
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
EOF
    chmod +x "$temp/systemctl"
    export SYSTEMCTL_BIN="$temp/systemctl"
    export FAKE_SYSTEMCTL_LOG="$temp/systemctl.log"

    export FAKE_SOCKET_ACTIVE=1
    : > "$FAKE_SYSTEMCTL_LOG"
    apply_ssh_runtime
    output="$(cat "$FAKE_SYSTEMCTL_LOG")"
    assert_contains "$output" 'daemon-reload' "socket mode reloads systemd generator"
    assert_contains "$output" 'restart ssh.socket' "socket mode restarts ssh.socket"
    assert_not_contains "$output" 'ssh.service' "socket mode does not rely on service restart"

    export FAKE_SOCKET_ACTIVE=0
    : > "$FAKE_SYSTEMCTL_LOG"
    apply_ssh_runtime
    output="$(cat "$FAKE_SYSTEMCTL_LOG")"
    assert_contains "$output" 'reload-or-restart ssh.service' "service mode reloads or restarts ssh.service"
}

test_listener_detection() {
    local temp status
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    cat > "$temp/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*' \
  'LISTEN 0 4096 [::]:2222 [::]:*'
EOF
    chmod +x "$temp/ss"
    export SS_BIN="$temp/ss"
    status=0
    port_is_listening 2222 || status=$?
    assert_status 0 "$status" "detect IPv6 listener on exact port"
    status=0
    port_is_listening 222 || status=$?
    assert_status 1 "$status" "do not substring-match another port"
}

test_ssh_connection_parsing_with_strict_ifs() {
    local parsed status=0
    IFS=$'\n\t'
    parsed="$(ssh_connection_local_port '198.51.100.5 54321 192.0.2.10 2222')" || status=$?
    assert_status 0 "$status" "SSH_CONNECTION parses under strict global IFS"
    assert_eq 2222 "$parsed" "SSH_CONNECTION local port is the fourth field"
}

test_unmanaged_port_conflict() {
    local temp output status
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    mkdir -p "$temp/sshd_config.d"
    printf '%s\n' 'Include sshd_config.d/*.conf' '#Port 22' > "$temp/sshd_config"
    printf '%s\n' 'PasswordAuthentication yes' > "$temp/sshd_config.d/50-cloud-init.conf"
    output="$(find_unmanaged_port_directives "$temp/sshd_config" "$temp/sshd_config.d" "$temp/sshd_config.d/00-vps-hardening.conf")"
    assert_eq '' "$output" "cloud-init authentication setting is not a port conflict"
    printf '%s\n' 'Port 2200' > "$temp/sshd_config.d/40-custom-port.conf"
    output="$(find_unmanaged_port_directives "$temp/sshd_config" "$temp/sshd_config.d" "$temp/sshd_config.d/00-vps-hardening.conf")"
    assert_contains "$output" "40-custom-port.conf"$'\t'"1"$'\t'"2200"$'\t'"Port 2200" "active unmanaged Port is reported"

    printf '%s\n' 'Port 22' > "$temp/sshd_config.d/40-custom-port.conf"
    output="$(find_unmanaged_port_directives "$temp/sshd_config" "$temp/sshd_config.d" "$temp/sshd_config.d/00-vps-hardening.conf")"
    status=0
    unmanaged_port_records_are_adoptable 22 "$output" || status=$?
    assert_status 0 "$status" "an explicit directive for the currently listening port can be adopted safely"

    printf '%s\n' 'Port=22' > "$temp/sshd_config.d/40-custom-port.conf"
    output="$(find_unmanaged_port_directives "$temp/sshd_config" "$temp/sshd_config.d" "$temp/sshd_config.d/00-vps-hardening.conf")"
    assert_contains "$output" "40-custom-port.conf"$'\t'"1"$'\t'"22"$'\t'"Port=22" "OpenSSH keyword=value syntax is detected"

    printf '%s\n' 'Port 2200' > "$temp/sshd_config.d/40-custom-port.conf"
    output="$(find_unmanaged_port_directives "$temp/sshd_config" "$temp/sshd_config.d" "$temp/sshd_config.d/00-vps-hardening.conf")"
    status=0
    unmanaged_port_records_are_adoptable 22 "$output" || status=$?
    assert_status 1 "$status" "a directive for another port remains an ambiguous conflict"
}

test_adopted_port_directive_transaction() {
    local temp records output status original_main original_dropin
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    mkdir -p "$temp/sshd_config.d" "$temp/transaction"
    SSHD_CONFIG="$temp/sshd_config"
    SSH_CONFIG_DIR="$temp/sshd_config.d"
    MANAGED_CONFIG="$temp/sshd_config.d/00-vps-hardening.conf"
    TRANSACTION_DIR="$temp/transaction"
    printf '%s\n' \
        'Include sshd_config.d/*.conf' \
        '# operator comment' \
        'Port 22' \
        'PasswordAuthentication yes' > "$SSHD_CONFIG"
    printf '%s\n' \
        '  Port 22 # provider default' \
        'PubkeyAuthentication yes' > "$SSH_CONFIG_DIR/40-provider.conf"
    original_main="$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')"
    original_dropin="$(sha256sum "$SSH_CONFIG_DIR/40-provider.conf" | awk '{print $1}')"

    records="$(find_unmanaged_port_directives "$SSHD_CONFIG" "$SSH_CONFIG_DIR" "$MANAGED_CONFIG")"
    mapfile -t ADOPTED_PORT_RECORDS <<< "$records"
    status=0
    backup_adopted_port_configs || status=$?
    assert_status 0 "$status" "adopted Port files are backed up before mutation"

    status=0
    neutralize_adopted_port_configs 22 || status=$?
    assert_status 0 "$status" "only snapshotted current-port directives are neutralized"
    output="$(find_unmanaged_port_directives "$SSHD_CONFIG" "$SSH_CONFIG_DIR" "$MANAGED_CONFIG")"
    assert_eq '' "$output" "neutralized current Port directives are no longer active"
    assert_contains "$(cat "$SSHD_CONFIG")" '# ubuntu-vps-disabled-port: Port 22' "main config retains an annotated copy of the adopted directive"
    assert_contains "$(cat "$SSH_CONFIG_DIR/40-provider.conf")" '# ubuntu-vps-disabled-port: Port 22 # provider default' "drop-in retains the original directive text"

    status=0
    restore_adopted_port_configs || status=$?
    assert_status 0 "$status" "rollback restores all adopted Port files"
    assert_eq "$original_main" "$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')" "rollback restores the main config byte-for-byte"
    assert_eq "$original_dropin" "$(sha256sum "$SSH_CONFIG_DIR/40-provider.conf" | awk '{print $1}')" "rollback restores the drop-in byte-for-byte"
    ADOPTED_PORT_RECORDS=()
}

test_managed_config_rollback() {
    local temp
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    MANAGED_CONFIG="$temp/00-vps-hardening.conf"
    TRANSACTION_DIR="$temp/transaction"
    mkdir -p "$TRANSACTION_DIR"
    printf '%s\n' 'Port 22' > "$MANAGED_CONFIG"
    backup_managed_config
    printf '%s\n' 'Port 2222' > "$MANAGED_CONFIG"
    restore_managed_config
    assert_eq 'Port 22' "$(cat "$MANAGED_CONFIG")" "rollback restores previous managed configuration"

    rm -f "$MANAGED_CONFIG"
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR"
    backup_managed_config
    printf '%s\n' 'Port 2222' > "$MANAGED_CONFIG"
    restore_managed_config
    assert_eq false "$([[ -e "$MANAGED_CONFIG" ]] && echo true || echo false)" "rollback removes newly-created managed configuration"
}

test_invalid_rollback_config_does_not_restart_or_close_firewall() {
    local temp status=0 runtime_log ufw_log
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    runtime_log="$temp/systemctl.log"
    ufw_log="$temp/ufw.log"
    : > "$runtime_log"
    : > "$ufw_log"
    cat > "$temp/sshd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    cat > "$temp/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
EOF
    cat > "$temp/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$temp/ufw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_UFW_LOG"
exit 0
EOF
    chmod +x "$temp/sshd" "$temp/systemctl" "$temp/fail2ban-client" "$temp/ufw"

    MANAGED_CONFIG="$temp/00-vps-hardening.conf"
    FAIL2BAN_CONFIG="$temp/90-ubuntu-vps-ssh.conf"
    TRANSACTION_DIR="$temp/transaction"
    mkdir -p "$TRANSACTION_DIR"
    printf '%s\n' 'Port 2222' > "$MANAGED_CONFIG"
    printf '%s\n' '[sshd]' > "$FAIL2BAN_CONFIG"
    backup_managed_config
    backup_fail2ban_config
    TRANSACTION_ID=test-invalid-rollback
    TRANSACTION_ACTIVE=true
    ROLLBACK_RUNNING=false
    OLD_PORT=2222
    SSHD_PORT=3333
    ENABLE_UFW=true
    SSHD_BIN="$temp/sshd"
    SYSTEMCTL_BIN="$temp/systemctl"
    FAIL2BAN_BIN="$temp/fail2ban-client"
    UFW_BIN="$temp/ufw"
    export FAKE_SYSTEMCTL_LOG="$runtime_log" FAKE_UFW_LOG="$ufw_log"
    LOG_FILE="$temp/rollback.log"
    BACKUP_ROOT="$temp/backups"

    rollback_transaction || status=$?
    assert_status 1 "$status" "rollback reports that restored SSH configuration is invalid"
    assert_not_contains "$(cat "$runtime_log")" 'ssh.socket' "invalid rollback config never restarts ssh.socket"
    assert_not_contains "$(cat "$runtime_log")" 'ssh.service' "invalid rollback config never reloads ssh.service"
    assert_eq '' "$(cat "$ufw_log")" "invalid rollback config leaves staged recovery firewall rules untouched"
}

test_effective_config_assertions() {
    local effective status
    effective=$'port 2222\npasswordauthentication no\npubkeyauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin no\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2'
    status=0
    assert_effective_value "$effective" port 2222 || status=$?
    assert_status 0 "$status" "effective port assertion accepts expected value"
    status=0
    assert_effective_value "$effective" passwordauthentication yes || status=$?
    assert_status 1 "$status" "effective value mismatch fails"
    status=0
    authorized_keys_path_supported "$effective" || status=$?
    assert_status 0 "$status" "standard AuthorizedKeysFile is accepted"
}

make_fake_ufw() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_UFW_LOG"
case "$*" in
    "status")
        if [[ "$(cat "$FAKE_UFW_ACTIVE")" == "yes" ]]; then
            printf 'Status: active\n'
        else
            printf 'Status: inactive\n'
        fi
        ;;
    "show added")
        cat "$FAKE_UFW_RULES"
        ;;
    "--force enable")
        printf 'yes\n' > "$FAKE_UFW_ACTIVE"
        ;;
    "disable")
        printf 'no\n' > "$FAKE_UFW_ACTIVE"
        ;;
    allow\ *\/tcp\ comment\ *)
        rule="ufw allow $2 comment '$4'"
        grep -Fqx -- "$rule" "$FAKE_UFW_RULES" || printf '%s\n' "$rule" >> "$FAKE_UFW_RULES"
        ;;
    "--force delete allow "*"/tcp comment "*)
        rule="ufw allow $4 comment '$6'"
        grep -Fvx -- "$rule" "$FAKE_UFW_RULES" > "$FAKE_UFW_RULES.tmp" || true
        mv "$FAKE_UFW_RULES.tmp" "$FAKE_UFW_RULES"
        ;;
    *)
        printf 'Unsupported fake ufw command: %s\n' "$*" >&2
        exit 64
        ;;
esac
EOF
    chmod +x "$path"
}

test_ufw_transaction_ownership() {
    local temp rules
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    make_fake_ufw "$temp/ufw"
    export UFW_BIN="$temp/ufw"
    export FAKE_UFW_LOG="$temp/ufw.log"
    export FAKE_UFW_RULES="$temp/ufw.rules"
    export FAKE_UFW_ACTIVE="$temp/ufw.active"
    : > "$FAKE_UFW_LOG"
    : > "$FAKE_UFW_RULES"
    printf 'no\n' > "$FAKE_UFW_ACTIVE"
    TRANSACTION_DIR="$temp/transaction"
    TRANSACTION_ID=test-ufw-ownership
    mkdir -p "$TRANSACTION_DIR"

    stage_ufw 22 2222
    stage_ufw 22 2222
    rules="$(cat "$FAKE_UFW_RULES")"
    assert_eq 1 "$(grep -Fc 'ufw allow 22/tcp' <<<"$rules")" "old recovery rule is not duplicated"
    assert_eq 1 "$(grep -Fc 'ufw allow 2222/tcp' <<<"$rules")" "new rule is not duplicated"
    assert_eq yes "$(cat "$FAKE_UFW_ACTIVE")" "inactive UFW is enabled only after staging rules"

    rollback_ufw 22 2222
    assert_eq '' "$(cat "$FAKE_UFW_RULES")" "rollback removes only transaction-created rules"
    assert_eq no "$(cat "$FAKE_UFW_ACTIVE")" "rollback restores initially inactive UFW"

    printf '%s\n' 'ufw allow 22/tcp' 'ufw allow 2222/tcp' > "$FAKE_UFW_RULES"
    printf 'yes\n' > "$FAKE_UFW_ACTIVE"
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR"
    stage_ufw 22 2222
    rollback_ufw 22 2222
    rules="$(cat "$FAKE_UFW_RULES")"
    assert_contains "$rules" 'ufw allow 22/tcp' "rollback preserves pre-existing old-port rule"
    assert_contains "$rules" 'ufw allow 2222/tcp' "rollback preserves pre-existing new-port rule"
    assert_eq yes "$(cat "$FAKE_UFW_ACTIVE")" "rollback preserves initially active UFW"

    printf '%s\n' "ufw allow 22/tcp comment 'operator SSH'" > "$FAKE_UFW_RULES"
    printf 'yes\n' > "$FAKE_UFW_ACTIVE"
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR"
    stage_ufw 22 2222
    rollback_ufw 22 2222
    rules="$(cat "$FAKE_UFW_RULES")"
    assert_contains "$rules" "ufw allow 22/tcp comment 'operator SSH'" "rollback preserves a pre-existing commented operator rule"
    assert_eq false "$([[ -e "$TRANSACTION_DIR/ufw-created-22" ]] && echo true || echo false)" "commented operator rule is never marked as transaction-owned"

    : > "$FAKE_UFW_RULES"
    printf 'yes\n' > "$FAKE_UFW_ACTIVE"
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR"
    stage_ufw 22 2222
    rules="$(cat "$FAKE_UFW_RULES")"
    assert_contains "$rules" 'ufw allow 22/tcp' "active UFW also receives an explicit old-port recovery rule"
    assert_contains "$rules" 'ufw allow 2222/tcp' "active UFW receives the new-port rule"
}

test_ufw_same_port_rerun_keeps_rule() {
    local temp rules
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    make_fake_ufw "$temp/ufw"
    export UFW_BIN="$temp/ufw"
    export FAKE_UFW_LOG="$temp/ufw.log"
    export FAKE_UFW_RULES="$temp/ufw.rules"
    export FAKE_UFW_ACTIVE="$temp/ufw.active"
    : > "$FAKE_UFW_LOG"
    : > "$FAKE_UFW_RULES"
    printf 'no\n' > "$FAKE_UFW_ACTIVE"
    TRANSACTION_DIR="$temp/transaction"
    TRANSACTION_ID=test-ufw-same-port
    mkdir -p "$TRANSACTION_DIR"

    stage_ufw 2222 2222
    finalize_ufw 2222 2222
    rules="$(cat "$FAKE_UFW_RULES")"
    assert_eq 1 "$(grep -Fc 'ufw allow 2222/tcp' <<<"$rules")" "same-port rerun keeps its SSH firewall rule"
    assert_eq yes "$(cat "$FAKE_UFW_ACTIVE")" "same-port rerun leaves UFW active"
}

test_fail2ban_config_rollback() {
    local temp
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    TRANSACTION_DIR="$temp/transaction"
    FAIL2BAN_CONFIG="$temp/jail.d/90-ubuntu-vps-ssh.conf"
    mkdir -p "$TRANSACTION_DIR" "$(dirname "$FAIL2BAN_CONFIG")"
    printf '%s\n' 'port = 22' > "$FAIL2BAN_CONFIG"
    backup_fail2ban_config
    printf '%s\n' 'port = 2222' > "$FAIL2BAN_CONFIG"
    restore_fail2ban_config
    assert_eq 'port = 22' "$(cat "$FAIL2BAN_CONFIG")" "rollback restores prior managed Fail2ban jail"

    rm -f "$FAIL2BAN_CONFIG"
    rm -rf "$TRANSACTION_DIR"
    mkdir -p "$TRANSACTION_DIR"
    backup_fail2ban_config
    printf '%s\n' 'port = 2222' > "$FAIL2BAN_CONFIG"
    restore_fail2ban_config
    assert_eq false "$([[ -e "$FAIL2BAN_CONFIG" ]] && echo true || echo false)" "rollback removes newly-created Fail2ban jail"
}

test_session_verifier() {
    local temp verifier status
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    TRANSACTION_DIR="$temp/transaction"
    mkdir -p "$TRANSACTION_DIR"
    verifier="$temp/verify-session"
    create_session_verifier "$verifier" tx-123 igor 2222 "$TRANSACTION_DIR/verified"

    status=0
    SUDO_USER=mallory SSH_CONNECTION='198.51.100.5 54321 192.0.2.10 2222' "$verifier" tx-123 || status=$?
    assert_status 1 "$status" "verifier rejects the wrong SSH user"
    assert_eq false "$([[ -e "$TRANSACTION_DIR/verified" ]] && echo true || echo false)" "rejected verifier does not create marker"

    status=0
    SUDO_USER=igor SSH_CONNECTION='198.51.100.5 54321 192.0.2.10 22' "$verifier" tx-123 || status=$?
    assert_status 1 "$status" "verifier rejects the old SSH port"

    status=0
    SUDO_USER=igor SSH_CONNECTION='198.51.100.5 54321 192.0.2.10 2222' "$verifier" wrong || status=$?
    assert_status 1 "$status" "verifier rejects the wrong nonce"

    status=0
    SUDO_USER=igor SSH_CONNECTION='198.51.100.5 54321 192.0.2.10 2222' "$verifier" tx-123 || status=$?
    if [[ "$EUID" -eq 0 ]]; then
        assert_status 0 "$status" "root verifier accepts correct user, port, and nonce"
        assert_eq 'igor:2222' "$(cat "$TRANSACTION_DIR/verified")" "verification marker binds user and port"
    else
        assert_status 1 "$status" "non-root process cannot forge verification marker"
    fi
}

test_missing_key_source_stops() {
    local temp status
    temp="$(mktemp -d)"
    trap 'rm -rf "$temp"' RETURN
    status=0
    require_public_key_source '' "$temp/missing-root-authorized-keys" || status=$?
    assert_status 1 "$status" "missing supplied and root keys stops before hardening"
}

test_dependency_install_never_upgrades_active_sshd() {
    local body
    body="$(declare -f install_dependencies)"
    assert_not_contains "$body" 'openssh-server' "dependency setup never upgrades/restarts the active OpenSSH server before key preparation"
    assert_contains "$body" 'missing_packages' "dependency setup installs only tools that are actually absent"
}

test_username_validation
test_uid_zero_alias_validation
test_port_validation
test_argument_parsing
test_config_rendering
test_key_merge_is_valid_and_idempotent
test_runtime_application_modes
test_listener_detection
test_ssh_connection_parsing_with_strict_ifs
test_unmanaged_port_conflict
test_adopted_port_directive_transaction
test_managed_config_rollback
test_invalid_rollback_config_does_not_restart_or_close_firewall
test_effective_config_assertions
test_ufw_transaction_ownership
test_ufw_same_port_rerun_keeps_rule
test_fail2ban_config_rollback
test_session_verifier
test_missing_key_source_stops
test_dependency_install_never_upgrades_active_sshd
finish_tests
