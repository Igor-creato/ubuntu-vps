verify_final() {
  valid_final_config || return 1
  listening "$PORT" || { warn "SSH port $PORT is not listening."; return 1; }
  if listening 22; then warn 'Old SSH port 22 is still listening.'; return 1; fi
  check_ufw_policy || return 1
  check_allowed_rules no || return 1
  local rules
  rules="$(ufw status)"
  grep -Eq "^${PORT}/tcp[[:space:]]+ALLOW[[:space:]]+IN" <<< "$rules" || return 1
  grep -Eq '^80/tcp[[:space:]]+ALLOW[[:space:]]+IN' <<< "$rules" || return 1
  grep -Eq '^443/tcp[[:space:]]+ALLOW[[:space:]]+IN' <<< "$rules" || return 1
  fail2ban-client status sshd >/dev/null 2>&1 || return 1
}
rollback() {
  require_ubuntu
  lock_setup
  read_saved
  if [[ "$MODE" != pending-confirm ]]; then msg "Rollback not needed (mode=$MODE)."; return 0; fi
  msg 'Rollback: restoring original SSH port 22 and both-port staging.'
  if restore_recovery_ssh; then
    # SSH recovery takes priority over Fail2ban recovery.
    write_jail "22,$PORT" || warn 'Fail2ban jail could not be updated during rollback.'
    set_mode rolled-back
    msg 'Old port 22 recovered. Re-run prepare or finalize when ready.'
  else
    return 1
  fi
}
finalize_error() {
  local rc="$1" line="$2"
  trap - ERR EXIT INT TERM HUP
  warn "Finalization failed at line $line (exit $rc). Attempting to restore SSH port 22."
  # Avoid deadlock: rollback() locks setup, but finalize() already holds the lock.
  if restore_recovery_ssh; then
    write_jail "22,$PORT" || true
    set_mode rolled-back
  fi
  exit "$rc"
}
finalize() {
  require_ubuntu
  lock_setup
  read_saved
  [[ "$MODE" == prepared || "$MODE" == rolled-back ]] || die "Expected prepared/rolled-back, got $MODE."
  require_admin_session
  valid_stage_ports || die 'Staging SSH ports are not as expected.'
  listening 22 && listening "$PORT" || die 'Both staging listeners are not active.'
  check_ufw_policy && check_allowed_rules yes || die 'UFW rules changed unexpectedly.'
  msg "Scheduling a ${ROLLBACK_SECONDS}s automatic recovery if a THIRD SSH session is not confirmed."
  local unit
  unit="vpn-vps-hardening-rollback-$(date +%s)-$$"
  # A unique transient timer works even when a previous rollback timer has fired.
  systemd-run --quiet --unit="$unit" --on-active="${ROLLBACK_SECONDS}s" "$SELF" rollback || die 'Failed to arm automatic rollback: nothing was changed.'
  printf '%s.timer\n' "$unit" > "$STATE/rollback_timer"
  printf '%s\n' "${SSH_CONNECTION:-}" > "$STATE/finalize_session"
  set_mode pending-confirm
  trap 'finalize_error "$?" "$LINENO"' ERR EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  write_ssh_final
  valid_final_config
  apply_ssh
  listening "$PORT" && ! listening 22 || { warn 'Unexpected SSH listeners after finalization.'; false; }
  ufw --force delete allow 22/tcp
  write_jail "$PORT"
  verify_final || { warn 'Final verification failed.'; false; }
  trap - ERR EXIT INT TERM HUP
  printf '\nFINALIZATION ACTIVE (NOT YET CONFIRMED).\n'
  printf 'Open a THIRD, fresh SSH connection by private key on port %s as %s.\n' "$PORT" "$ADMIN"
  printf 'In that THIRD SSH session run:\n'
  printf '  sudo --preserve-env=SSH_CONNECTION %s confirm\n' "$SELF"
  printf 'DO NOT reboot or close your current sessions until confirmed.\n'
  printf 'If unconfirmed, SSH port 22 will reopen automatically in %s minutes.\n' "$((ROLLBACK_SECONDS/60))"
}
confirm() {
  require_ubuntu
  lock_setup
  read_saved
  [[ "$MODE" == pending-confirm ]] || die "Nothing to confirm (mode=$MODE)."
  require_admin_session
  [[ -s "$STATE/finalize_session" ]] || die 'Missing finalization session marker.'
  [[ "${SSH_CONNECTION:-}" != "$(cat "$STATE/finalize_session")" ]] || die 'This is the finalization SSH session. Open a THIRD, new SSH connection for confirmation.'
  verify_final || die 'SSH/UFW/Fail2ban verification failed; rollback is still scheduled.'
  # Commit state FIRST: even if systemd stop fails, a late timer will see 'complete' and do nothing.
  set_mode complete
  if [[ -s "$STATE/rollback_timer" ]]; then
    systemctl stop "$(cat "$STATE/rollback_timer")" || warn 'Timer stop failed, but commit state prevents rollback.'
  fi
  msg "SUCCESS. SSH: $ADMIN via key at TCP/$PORT. UFW: only TCP/80, TCP/443 and TCP/$PORT."
  msg 'Fail2ban is active. Docker, 3x-ui and the panel port were not installed/opened.'
  show_reboot_notice
}
status() {
  require_ubuntu
  read_saved
  printf 'Version: %s\nState: %s\nAdmin: %s\nSSH port: %s\n' "$VERSION" "$MODE" "$ADMIN" "$PORT"
  "$SSHD" -T | awk '$1=="port" || $1=="passwordauthentication" || $1=="permitrootlogin"'
  systemctl is-active ssh.socket || true
  ss -lntp | grep -E 'ssh|:22 |:80 |:443 ' || true
  ufw status verbose
  fail2ban-client status sshd || true
  if [[ -s "$STATE/rollback_timer" ]]; then
    systemctl is-active "$(cat "$STATE/rollback_timer")" || true
  fi
}
usage() {
  cat <<EOF_USAGE
vpn-vps-hardening.sh v$VERSION (Ubuntu 24.04 LTS)
  sudo bash vpn-vps-hardening.sh prepare        # New server OR resume interrupted initial install
  sudo --preserve-env=SSH_CONNECTION $SELF finalize  # Via NEW SSH session
  sudo --preserve-env=SSH_CONNECTION $SELF confirm   # Via THIRD SSH session
  sudo $SELF status

Only on a dedicated fresh Ubuntu VPS (also supports legacy 'setup-failed' state).
Upgrades installed packages first; does not reboot automatically or install Docker / 3x-ui.
Obtain VPS provider console access and a snapshot before starting.
EOF_USAGE
}
main() {
  require_root
  case "${1:-}" in
    prepare|resume) prepare ;;
    finalize) finalize ;;
    confirm) confirm ;;
    rollback) rollback ;;
    status) status ;;
    --version|-v) printf '%s\n' "$VERSION" ;;
    --help|-h|'') usage ;;
    *) usage; die "Unknown operation: $1" ;;
  esac
}
main "$@"
