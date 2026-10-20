#!/usr/bin/env bash
# Ubuntu 24.04 LTS: minimal SSH/UFW/Fail2ban hardening for a bare-metal/VM 3x-ui host.
# No Docker, 3x-ui, VPN software or web server is installed by this script.
# Two-step migration + systemd rollback timer. Review before running on a FRESH VPS.
set -Eeuo pipefail
umask 077
export LC_ALL=C

SELF='/usr/local/sbin/vpn-vps-hardening'
STATE='/var/lib/vpn-vps-hardening'
SSH_CONFIG='/etc/ssh/sshd_config.d/00-vpn-vps-hardening.conf'
JAIL_CONFIG='/etc/fail2ban/jail.d/98-vpn-vps-sshd.local'
TIMER='vpn-vps-hardening-rollback.timer'
SSHD='/usr/sbin/sshd'

msg() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { (( EUID == 0 )) || die 'Run with sudo/root.'; }
require_ubuntu() {
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' && "${VERSION_ID:-}" == '24.04' ]] || die 'Only Ubuntu 24.04 LTS is supported.'
}
require_tty() { [[ -t 0 ]] || die 'Run interactively, not through curl | bash.'; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$1" != root ]]; }
read_saved() {
  [[ -r "$STATE/port" && -r "$STATE/admin" && -r "$STATE/mode" ]] || die 'No saved setup state.'
  PORT="$(cat "$STATE/port")"
  ADMIN="$(cat "$STATE/admin")"
  MODE="$(cat "$STATE/mode")"
  [[ "$PORT" =~ ^[0-9]{5}$ ]] && (( PORT >= 20000 && PORT <= 29999 )) || die 'Invalid saved SSH port.'
  valid_user "$ADMIN" || die 'Invalid saved admin account.'
}
set_mode() { printf '%s\n' "$1" > "$STATE/mode"; }
listening() {
  ss -H -lnt | awk -v port="$1" '{split($4,a,":"); if (a[length(a)] == port) found=1} END {exit !found}'
}
apply_ssh() {
  "$SSHD" -t
  if systemctl is-active --quiet ssh.socket; then
    systemctl daemon-reload
    systemctl restart ssh.socket
    # ssh.service can stay running after socket reconfiguration on Ubuntu 24.04.
    if systemctl is-active --quiet ssh.service; then systemctl restart ssh.service; fi
  else
    systemctl reload-or-restart ssh.service
  fi
}
write_ssh_stage() {
  local tmp
  tmp="$(mktemp /etc/ssh/sshd_config.d/.vpn-hardening.XXXXXX)"
  printf 'Port 22\nPort %s\n' "$PORT" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SSH_CONFIG"
}
write_ssh_final() {
  local tmp
  tmp="$(mktemp /etc/ssh/sshd_config.d/.vpn-hardening.XXXXXX)"
  cat > "$tmp" <<EOF
# Managed by vpn-vps-hardening. Only key-based non-root SSH access.
Port $PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $ADMIN
EOF
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SSH_CONFIG"
}
write_jail() {
  local ports="$1" tmp
  tmp="$(mktemp /etc/fail2ban/jail.d/.vpn-hardening.XXXXXX)"
  cat > "$tmp" <<EOF
[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 4
findtime = 10m
bantime = 1h
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$JAIL_CONFIG"
  fail2ban-client -t >/dev/null
  systemctl enable --now fail2ban.service >/dev/null
  systemctl restart fail2ban.service
  fail2ban-client status sshd >/dev/null
}
require_admin_ssh_session() {
  [[ "${SUDO_USER:-}" == "$ADMIN" ]] || die "Run with sudo from user $ADMIN (not root SSH)."
  [[ -n "${SSH_CONNECTION:-}" ]] || die 'SSH_CONNECTION is missing; use sudo --preserve-env=SSH_CONNECTION.'
  local _src _src_port _dst local_port
  read -r _src _src_port _dst local_port <<< "$SSH_CONNECTION"
  [[ "$local_port" == "$PORT" ]] || die "SSH session must enter using the new port $PORT."
}
verify_effective() {
  local output ports
  "$SSHD" -t
  output="$("$SSHD" -T -C "user=$ADMIN,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$PORT")"
  ports="$("$SSHD" -T | awk '$1=="port" {print $2}')"
  [[ "$ports" == "$PORT" ]] || { msg "Actual SSH ports: $ports (expected $PORT only)"; return 1; }
  for expected in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey' 'permitrootlogin no'; do
    grep -Fqx -- "$expected" <<< "$output" || { msg "Missing effective sshd setting: $expected"; return 1; }
  done
  grep -Fqx -- "allowusers $ADMIN" <<< "$output" || { msg 'Unexpected AllowUsers setting'; return 1; }
  listening "$PORT" || { msg "Nothing is listening on $PORT"; return 1; }
  if listening 22; then msg 'SSH port 22 is still listening'; return 1; fi
  ufw status | grep -Fqx 'Status: active' || return 1
  ufw status verbose | grep -F 'Default: deny (incoming)' >/dev/null || return 1
  ufw status | grep -Eq "^${PORT}/tcp[[:space:]]+ALLOW" || { msg "No UFW allow rule for SSH $PORT"; return 1; }
  if ufw status | grep -Eq '^22/tcp[[:space:]]+ALLOW'; then msg 'Port 22 is still allowed by UFW'; return 1; fi
  # Enforce exactly the three requested public TCP ports (both IPv4 and IPv6).
  if ! ufw status | awk -v ssh_port="${PORT}/tcp" '
    /[[:space:]]ALLOW[[:space:]]/ {
      if ($1 != ssh_port && $1 != "80/tcp" && $1 != "443/tcp") bad=1
    }
    END {exit bad}
  '; then msg 'Unexpected additional UFW allow rules exist'; return 1; fi
  fail2ban-client status sshd >/dev/null || return 1
}
prepare_failure() {
  local status="$1"
  trap - ERR
  msg 'Setup failed. Attempting to keep/reopen the original SSH port 22.'
  ufw allow 22/tcp >/dev/null 2>&1 || true
  if [[ -e "$SSH_CONFIG" && -r "$STATE/mode" ]]; then
    rm -f "$SSH_CONFIG"
    apply_ssh || true
  fi
  if [[ -d "$STATE" ]]; then set_mode 'setup-failed' || true; fi
  msg 'Do not disconnect the current session until SSH port 22 is checked.'
  exit "$status"
}
prepare() {
  require_ubuntu
  require_tty
  [[ ! -e "$SSH_CONFIG" && ! -e "$STATE/mode" ]] || die 'Existing setup found; refusing to overwrite.'
  [[ -x "$SSHD" ]] || die 'OpenSSH server is not installed.'
  "$SSHD" -t
  [[ "$("$SSHD" -T | awk '$1=="port"{print $2}')" == '22' ]] || die 'SSH already has a non-standard or multiple ports. Fresh VPS expected.'
  listening 22 || die 'The original SSH listener on port 22 is not detected.'
  command -v x-ui >/dev/null 2>&1 && die '3x-ui is already installed: refusing fresh-server firewall reset.'
  command -v docker >/dev/null 2>&1 && die 'Docker is installed: this script is for a clean host only.'
  systemctl is-active --quiet firewalld && die 'firewalld is active; refusing conflicting firewall setup.'
  msg 'Installing UFW, Fail2ban and python3-systemd (no other apps).'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ufw fail2ban python3-systemd
  ufw status | grep -Fqx 'Status: inactive' || die 'UFW is already active. Stop and review its rules manually.'
  if ufw show added | grep -qE '^ufw '; then die 'Existing UFW user rules detected. Not wiping your firewall.'; fi
  # Enforce IPv6 filtering too; otherwise IPv6 services can remain exposed.
  if [[ -r /etc/default/ufw ]] && grep -q '^IPV6=' /etc/default/ufw; then
    sed -i -E 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    die '/etc/default/ufw is missing IPV6 configuration.'
  fi
  [[ ! -e "$JAIL_CONFIG" ]] || die "Existing $JAIL_CONFIG; refusing overwrite."

  local new_user pubkey keyfile home group attempt=0
  printf 'Admin username [vpnadmin]: '
  read -r new_user
  new_user="${new_user:-vpnadmin}"
  valid_user "$new_user" || die 'Invalid admin username.'
  if id "$new_user" >/dev/null 2>&1; then
    [[ "$(id -u "$new_user")" -ne 0 ]] || die 'Admin account cannot be UID 0.'
    msg "Using existing account $new_user."
  else
    msg "Will create non-root sudo account $new_user."
  fi
  printf '\nPaste ONE line of your public ED25519 key (ssh-ed25519 AAAA...):\n> '
  IFS= read -r pubkey
  [[ "$pubkey" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || die 'Only a public ssh-ed25519 key is accepted.'
  keyfile="$(mktemp)"
  printf '%s\n' "$pubkey" > "$keyfile"
  if ! ssh-keygen -lf "$keyfile" >/dev/null 2>&1; then rm -f "$keyfile"; die 'Invalid public key.'; fi
  rm -f "$keyfile"

  local chosen=''
  while (( attempt < 40 )); do
    chosen="$(shuf -i 20000-29999 -n 1)"
    if [[ "$chosen" != '21086' ]] && ! listening "$chosen"; then break; fi
    attempt=$((attempt + 1))
  done
  (( attempt < 40 )) || die 'Unable to find an unused SSH port.'
  PORT="$chosen"
  ADMIN="$new_user"
  printf '\nSelected SSH port: %s\n' "$PORT"
  printf 'Provider firewall, if present, must permit TCP/%s before testing.\n' "$PORT"
  printf 'This procedure is intended ONLY for a fresh VPS. Continue [type YES]? '
  local yes
  read -r yes
  [[ "$yes" == 'YES' ]] || die 'Cancelled without changes to SSH/UFW.'

  if ! id "$ADMIN" >/dev/null 2>&1; then adduser --disabled-password --gecos '' "$ADMIN"; fi
  usermod -aG sudo "$ADMIN"
  msg "Set a LOCAL password for sudo user $ADMIN (SSH password login will be disabled after confirmation)."
  passwd "$ADMIN"
  home="$(getent passwd "$ADMIN" | cut -d: -f6)"
  group="$(id -gn "$ADMIN")"
  [[ -n "$home" && "$home" == /* && -d "$home" ]] || die 'Admin home directory invalid.'
  install -d -m 0700 -o "$ADMIN" -g "$group" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  if ! grep -Fqx -- "$pubkey" "$home/.ssh/authorized_keys"; then printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"; fi
  chown "$ADMIN:$group" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
  chmod go-w "$home"

  mkdir -p "$STATE"
  chmod 0700 "$STATE"
  printf '%s\n' "$PORT" > "$STATE/port"
  printf '%s\n' "$ADMIN" > "$STATE/admin"
  set_mode 'preparing'
  install -m 0700 -o root -g root "$(readlink -f "$0")" "$SELF"
  trap 'prepare_failure "$?"' ERR
  write_ssh_stage
  apply_ssh
  listening 22 && listening "$PORT" || { msg 'Both SSH ports are not listening.'; return 1; }
  msg 'Configuring deny-by-default UFW: allow only 22 (temporary), new SSH, TCP 80 and 443.'
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow "$PORT/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  write_jail "22,$PORT"
  set_mode 'prepared'
  trap - ERR
  printf '\nPREPARED. Old SSH port 22 remains available for recovery.\n'
  printf 'NEW SSH PORT: %s\nADMIN USER: %s\n' "$PORT" "$ADMIN"
  printf 'From a SECOND terminal connect with your private key, using publickey-only auth.\n'
  printf 'After that, run: sudo --preserve-env=SSH_CONNECTION %s finalize\n' "$SELF"
  printf 'Do NOT close the original SSH terminal until the final confirmation.\n'
}
rollback() {
  require_ubuntu
  read_saved
  if [[ "$MODE" != 'pending-confirm' ]]; then msg "Rollback skipped (mode=$MODE)."; return 0; fi
  msg 'ROLLBACK: restoring port 22 while keeping new port available.'
  ufw allow 22/tcp >/dev/null || true
  write_ssh_stage
  apply_ssh
  write_jail "22,$PORT"
  if listening 22; then
    set_mode 'rolled-back'
    msg 'Rollback completed. Port 22 is open again. Fix the problem before retrying.'
  else
    msg 'Rollback incomplete: use the VPS provider console and inspect SSH/UFW.'
    return 1
  fi
}
finalize_failure() {
  local status="$1"
  trap - ERR
  msg 'Finalization failed; attempting rollback immediately.'
  rollback || true
  exit "$status"
}
finalize() {
  require_ubuntu
  read_saved
  [[ "$MODE" == 'prepared' || "$MODE" == 'rolled-back' ]] || die "Cannot finalize in mode: $MODE."
  require_admin_ssh_session
  listening "$PORT" || die "New SSH listener $PORT is not running."
  msg 'Scheduling automatic rollback (4 minutes) if you do not confirm a fresh SSH session.'
  set_mode 'pending-confirm'
  if ! systemd-run --quiet --unit=vpn-vps-hardening-rollback --on-active=240s "$SELF" rollback; then
    set_mode 'prepared'
    die 'Could not schedule rollback; no SSH changes were made.'
  fi
  trap 'finalize_failure "$?"' ERR
  write_ssh_final
  "$SSHD" -t
  apply_ssh
  ufw --force delete allow 22/tcp
  write_jail "$PORT"
  verify_effective
  trap - ERR
  printf '\nHARDENING ACTIVE; NOT YET CONFIRMED.\n'
  printf 'Close neither the original session nor this one.\n'
  printf 'Open a THIRD, entirely new SSH connection by KEY at port %s as %s.\n' "$PORT" "$ADMIN"
  printf 'In that third session execute: sudo --preserve-env=SSH_CONNECTION %s confirm\n' "$SELF"
  printf 'If unconfirmed, the server will automatically restore port 22 in ~4 minutes.\n'
}
confirm() {
  require_ubuntu
  read_saved
  [[ "$MODE" == 'pending-confirm' ]] || die "Nothing to confirm (mode=$MODE)."
  require_admin_ssh_session
  verify_effective || die 'Effective SSH/UFW/Fail2ban verification failed; rollback timer remains active.'
  systemctl stop "$TIMER" || die 'Could not stop rollback timer.'
  set_mode 'complete'
  msg "COMPLETED: only TCP 80, TCP 443 and TCP $PORT accepted by UFW; SSH key-only."
  msg "3x-ui is NOT installed. Panel port is intentionally NOT exposed."
}
status() {
  require_ubuntu
  read_saved
  printf 'State: %s\nAdmin: %s\nSSH port: %s\n' "$MODE" "$ADMIN" "$PORT"
  "$SSHD" -T | awk '$1=="port"||$1=="passwordauthentication"||$1=="permitrootlogin"'
  ufw status verbose
  fail2ban-client status sshd || true
  systemctl is-active "$TIMER" || true
}
usage() {
  cat <<'EOF'
Usage: sudo bash vpn-vps-hardening.sh prepare
       sudo --preserve-env=SSH_CONNECTION /usr/local/sbin/vpn-vps-hardening finalize
       sudo --preserve-env=SSH_CONNECTION /usr/local/sbin/vpn-vps-hardening confirm
       sudo /usr/local/sbin/vpn-vps-hardening status

Only on a clean Ubuntu 24.04 VPS; review before use and have provider console access.
The script NEVER installs 3x-ui, Docker, certificates, or a web server.
EOF
}
main() {
  require_root
  case "${1:-}" in
    prepare) prepare ;;
    finalize) finalize ;;
    confirm) confirm ;;
    rollback) rollback ;;
    status) status ;;
    *) usage; [[ $# -gt 0 ]] || return 0 ;;
  esac
}
main "$@"
