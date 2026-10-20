#!/usr/bin/env bash
# Ubuntu 24.04 LTS: SSH keys + UFW + Fail2ban for a clean VPS running 3x-ui later.
# No Docker, VPN panel or web server is installed. First-run and interrupted-run support.
# IMPORTANT: Obtain VPS provider console access and create a snapshot before use.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION='2.0.0'
SELF='/usr/local/sbin/vpn-vps-hardening'
STATE='/var/lib/vpn-vps-hardening'
SSH_CONFIG='/etc/ssh/sshd_config.d/00-vpn-vps-hardening.conf'
JAIL_CONFIG='/etc/fail2ban/jail.d/98-vpn-vps-sshd.local'
SSHD='/usr/sbin/sshd'
LOCK='/run/lock/vpn-vps-hardening.lock'
ROLLBACK_SECONDS=600
PORT=''
ADMIN=''
MODE=''
PUBLIC_KEY=''

msg() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
require_root() { (( EUID == 0 )) || die 'Run with sudo/root.'; }
require_tty() { [[ -t 0 ]] || die 'An interactive terminal is required. Never pipe this script to bash.'; }
require_ubuntu() {
  [[ -r /etc/os-release ]] || die '/etc/os-release not found.'
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die 'Only Ubuntu 24.04 LTS is supported.'
}
lock_setup() {
  mkdir -p "$(dirname "$LOCK")"
  exec 9>"$LOCK"
  flock -w 40 9 || die 'Another hardening operation is in progress.'
}
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$1" != root ]]; }
valid_port() { [[ "$1" =~ ^2[0-9]{4}$ ]] && (( 10#$1 >= 20000 && 10#$1 <= 29999 )) && [[ "$1" != 21086 ]]; }
set_mode() { printf '%s\n' "$1" > "$STATE/mode"; MODE="$1"; }
read_saved() {
  [[ -s "$STATE/port" && -s "$STATE/admin" && -s "$STATE/mode" ]] || die 'Incomplete saved state; inspect /var/lib/vpn-vps-hardening before retrying.'
  PORT="$(cat "$STATE/port")"
  ADMIN="$(cat "$STATE/admin")"
  MODE="$(cat "$STATE/mode")"
  valid_port "$PORT" || die 'Invalid saved SSH port.'
  valid_user "$ADMIN" || die 'Invalid saved administrator.'
  [[ "$MODE" =~ ^(preparing|prepared|setup-failed|pending-confirm|rolled-back|complete)$ ]] || die "Unknown saved mode: $MODE"
}
listening() {
  ss -H -lnt | awk -v wanted="$1" '{p=$4; sub(/^.*:/,"",p); if (p==wanted) ok=1} END {exit !ok}'
}
ports_effective() { "$SSHD" -T | awk '$1 == "port" {print $2}'; }
valid_stage_ports() {
  local actual
  actual="$(ports_effective)"
  [[ "$actual" == "$(printf '22\n%s' "$PORT")" ]] || {
    warn "Unexpected sshd Port directives: $(printf %q "$actual") (wanted 22 and $PORT)."
    return 1
  }
}
valid_final_config() {
  local output actual
  "$SSHD" -t || return 1
  actual="$(ports_effective)"
  [[ "$actual" == "$PORT" ]] || { warn "Unexpected sshd ports: $actual"; return 1; }
  output="$("$SSHD" -T -C "user=$ADMIN,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$PORT")" || return 1
  local expected
  for expected in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
                  'pubkeyauthentication yes' 'authenticationmethods publickey' \
                  'permitrootlogin no' "allowusers $ADMIN"; do
    grep -Fqx -- "$expected" <<< "$output" || { warn "sshd effective setting missing: $expected"; return 1; }
  done
}
apply_ssh() {
  "$SSHD" -t
  # Ubuntu 24.04 normally generates ssh.socket ListenStream from sshd_config at daemon-reload.
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
    if systemctl is-active --quiet ssh.service; then systemctl restart ssh.service; fi
  else
    systemctl reload-or-restart ssh.service
  fi
}
write_ssh_stage() {
  local tmp
  tmp="$(mktemp /etc/ssh/sshd_config.d/.vpn-hardening.XXXXXX)"
  cat > "$tmp" <<EOF_STAGE
# Managed by vpn-vps-hardening: temporary recovery access.
Port 22
Port $PORT
EOF_STAGE
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SSH_CONFIG"
}
write_ssh_final() {
  local tmp
  tmp="$(mktemp /etc/ssh/sshd_config.d/.vpn-hardening.XXXXXX)"
  cat > "$tmp" <<EOF_FINAL
# Managed by vpn-vps-hardening: key-only admin access.
Port $PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $ADMIN
EOF_FINAL
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SSH_CONFIG"
}
managed_ssh_file_is_ours() {
  [[ ! -e "$SSH_CONFIG" ]] && return 0
  # Also recognize the file from the older script (Port 22 / Port <high port> only).
  grep -Eq '^# Managed by vpn-vps-hardening|^# Managed by vpn-vps-hardening\.' "$SSH_CONFIG" && return 0
  local contents
  contents="$(cat "$SSH_CONFIG")"
  [[ "$contents" == "$(printf 'Port 22\nPort %s' "$PORT")" ]]
}
check_pubkey() {
  local key="$1" file
  [[ "$key" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
  file="$(mktemp)"
  printf '%s\n' "$key" > "$file"
  if ! ssh-keygen -lf "$file" >/dev/null 2>&1; then rm -f "$file"; return 1; fi
  rm -f "$file"
