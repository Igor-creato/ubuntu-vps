#!/usr/bin/env bash
# Ubuntu 24.04 LTS: SSH keys + UFW + Fail2ban for a clean VPS running 3x-ui later.
# Optional official 3x-ui setup AFTER SSH hardening is confirmed. No Docker.
# IMPORTANT: Obtain VPS provider console access and create a snapshot before use.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION='2.4.0'
SELF='/usr/local/sbin/vpn-vps-hardening'
STATE='/var/lib/vpn-vps-hardening'
SSHD_CONFIG_ROOT='/etc/ssh'
SSH_CONFIG="${SSHD_CONFIG_ROOT}/sshd_config.d/00-vpn-vps-hardening.conf"
JAIL_CONFIG='/etc/fail2ban/jail.d/98-vpn-vps-sshd.local'
SSHD='/usr/sbin/sshd'
LOCK='/run/lock/vpn-vps-hardening.lock'
XUI_INSTALLER_URL='https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh'
XUI_INSTALL_RESULT='/etc/x-ui/install-result.env'
PANEL_DOMAIN_FILE="${STATE}/3x-ui-domain"
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
  local actual distinct expected
  actual="$(ports_effective)" || return 1
  # OpenSSH accumulates multiple Port directives across Include files. A pre-existing
  # Port 22 must not cause a false failure during staging; compare actual *sets*.
  distinct="$(printf '%s\n' "$actual" | LC_ALL=C sort -nu)"
  expected="$(printf '22\n%s\n' "$PORT" | LC_ALL=C sort -nu)"
  [[ "$distinct" == "$expected" ]] || {
    warn "Unexpected sshd Port directives: $(printf %q "$actual") (wanted only 22 and $PORT)."
    return 1
  }
}

# SSH Port is an additive directive: the main config or a provider drop-in may
# contain its own active `Port 22`. An additional drop-in with Port $PORT does
# NOT override that old port. To close 22 safely in the final configuration,
# back up and comment only literal active `Port 22` directives outside our file.
# Other ports, directives, and unknown Include paths are never modified; the
# final `sshd -T` and runtime checks fail closed if a conflict remains.
neutralize_external_port22() {
  local file backup tmp changed=0
  local -a candidates=("$SSHD_CONFIG_ROOT/sshd_config")
  local candidate
  for candidate in "$SSHD_CONFIG_ROOT"/sshd_config.d/*.conf; do
    [[ -f "$candidate" ]] && candidates+=("$candidate")
  done
  for file in "${candidates[@]}"; do
    [[ -f "$file" && "$file" != "$SSH_CONFIG" ]] || continue
    # Do not follow configuration symlinks and accidentally replace provider files.
    [[ ! -L "$file" ]] || die "Refusing to edit symlinked SSH config: $file"
    if ! grep -Eiq '^[[:space:]]*port[[:space:]]+22([[:space:]]*(#.*)?)?$' "$file"; then
      continue
    fi
    backup="$STATE/ssh-port-backups/${file#"$SSHD_CONFIG_ROOT"/}"
    mkdir -p -m 0700 "$(dirname "$backup")"
    if [[ -e "$backup" ]]; then
      # A user edit since a previous run is not safe to overwrite automatically.
      cmp -s -- "$file" "$backup" || die "SSH config $file changed after backup; inspect manually."
    else
      cp -a -- "$file" "$backup"
    fi
    tmp="$(mktemp "$(dirname "$file")/.vpn-port.XXXXXXXX")"
    # Preserve the original owner, mode, and file metadata in the replacement.
    cp -a -- "$file" "$tmp"
    awk '{
      lc=tolower($0)
      if (lc ~ /^[[:space:]]*port[[:space:]]+22([[:space:]]*(#.*)?)?$/) {
        print "# vpn-vps-hardening: disabled redundant " $0
      } else print
    }' "$file" > "$tmp"
    mv -f -- "$tmp" "$file"
    msg "Backed up and disabled an existing Port 22 directive in $file."
    changed=1
  done
  if (( changed )); then
    "$SSHD" -t || die 'SSH config invalid after disabling redundant ports; recovery will preserve port 22.'
  fi
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
  tmp="$(mktemp "$(dirname "$SSH_CONFIG")/.vpn-hardening.XXXXXX")"
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
  tmp="$(mktemp "$(dirname "$SSH_CONFIG")/.vpn-hardening.XXXXXX")"
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
}
set_admin_key() {
  local home group keyfile
  home="$(getent passwd "$ADMIN" | cut -d: -f6)"
  group="$(id -gn "$ADMIN")"
  [[ -n "$home" && "$home" == /* && -d "$home" ]] || die 'Administrator home directory is invalid.'
  [[ ! -L "$home/.ssh" && ! -L "$home/.ssh/authorized_keys" ]] || die 'Refusing symlinked .ssh/authorized_keys.'
  install -d -m 0700 -o "$ADMIN" -g "$group" "$home/.ssh"
  keyfile="$home/.ssh/authorized_keys"
  touch "$keyfile"
  chown "$ADMIN:$group" "$keyfile"
  chmod 0600 "$keyfile"
  if [[ -n "$PUBLIC_KEY" ]] && ! grep -Fqx -- "$PUBLIC_KEY" "$keyfile"; then
    printf '%s\n' "$PUBLIC_KEY" >> "$keyfile"
  fi
  chmod go-w "$home"
  [[ -s "$keyfile" ]] && ssh-keygen -lf "$keyfile" >/dev/null 2>&1 || die 'No usable public key for administrator.'
}
ufw_active() { ufw status | grep -Fx 'Status: active' >/dev/null; }
# UFW stores user rules even when the firewall is inactive. When resuming a failed
# hardening run, validate those SAVED rules rather than treating their mere
# existence as an error. Never silently enable unexpected existing rules.
check_saved_ufw_rules() {
  local keep22="$1"
  ufw show added | awk -v ssh="${PORT}/tcp" -v keep22="$keep22" '
    $1 == "ufw" {
      p=$3
      allowed=(($2=="allow") && (p==ssh || p=="80/tcp" || p=="443/tcp" || (keep22=="yes" && p=="22/tcp")))
      simple=(NF==3 || (NF>=5 && $4=="comment"))
      if (!allowed || !simple) {
        bad=1
        print "Unexpected saved UFW rule: " $0 > "/dev/stderr"
      }
    }
    END {exit bad}
  '
}

# A previous interrupted installation can leave a stale high SSH-port UFW rule.
# On this explicitly dedicated VPS, the operator may opt to reset INACTIVE UFW
# rules after they have been displayed and a backup has been made. Never reset
# an active firewall or touch UFW without deliberate approval.
review_inactive_ufw_rules() {
  if check_saved_ufw_rules yes; then return 0; fi
  printf '\nExisting INACTIVE UFW user rules differ from the requested 22/%s/80/443 allowlist:\n' "$PORT"
  ufw show added || return 1
  printf '\nThis VPS is reserved for 3x-ui. Reset ONLY INACTIVE UFW user rules?\n'
  printf 'The script will back up /etc/ufw and /etc/default/ufw, then recreate\n'
  printf 'rules for TCP 22 (temporary recovery), %s, 80 and 443.\n' "$PORT"
  printf 'Type RESET-UFW to approve, or press Enter to abort: '
  local answer backup
  IFS= read -r answer
  [[ "$answer" == 'RESET-UFW' ]] || die 'UFW rules were not changed. Review the saved rules before retrying.'
  [[ -d "$STATE" ]] || die 'No saved installation state; refusing UFW reset.'
  backup="$STATE/ufw-before-reset-$(date -u +%Y%m%dT%H%M%SZ)-$$.tar.gz"
  tar -czf "$backup" -C /etc ufw default/ufw || die 'Could not back up UFW configuration; refusing reset.'
  chmod 0600 "$backup"
  msg "Original UFW files backed up: $backup"
  ufw_active && die 'UFW unexpectedly became active; aborting reset.'
  ufw --force reset || die 'UFW reset failed; review the console output.'
  check_saved_ufw_rules yes || die 'UFW rules still unexpected after reset.'
}
check_ufw_policy() {
  ufw_active || return 1
  ufw status verbose | grep -F 'Default: deny (incoming)' >/dev/null || return 1
}
check_allowed_rules() {
  local allow_22="$1"
  # No additional inbound ALLOW rules, including IPv6 or UDP, are permitted on this dedicated host.
  ufw status | awk -v ssh="${PORT}/tcp" -v keep22="$allow_22" '
    $0 ~ /[[:space:]]ALLOW[[:space:]]+IN[[:space:]]/ {
      p=$1
      if (p==ssh || p=="80/tcp" || p=="443/tcp") next
      if (keep22=="yes" && p=="22/tcp") next
      bad=1; print "Unexpected UFW ALLOW: " $0 > "/dev/stderr"
    }
    END {exit bad}
  '
}
ensure_ufw_stage() {
  local is_active=false
  ufw_active && is_active=true
  if [[ "$is_active" == true ]]; then
    check_ufw_policy || die 'Active UFW has unexpected default policy; do not overwrite automatically.'
    check_allowed_rules yes || die 'Existing UFW allows additional ports; review before retrying.'
  else
    # A resumable interrupted run may have already saved the correct rules.
    # Only allow the expected TCP ports to be enabled; no broad firewall reset.
    check_saved_ufw_rules yes || die 'Inactive UFW still has unexpected saved rules. Stop and inspect with: sudo ufw show added'
  fi
  ufw allow 22/tcp
  ufw allow "$PORT/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  if [[ "$is_active" == false ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
  fi
  check_ufw_policy && check_allowed_rules yes || return 1
}
ensure_ipv6_ufw() {
  [[ -r /etc/default/ufw ]] || die '/etc/default/ufw not found.'
  if ! grep -Fqx 'IPV6=yes' /etc/default/ufw; then
    if ufw_active; then die 'Active UFW has IPv6 disabled or misconfigured; manual review required.'; fi
    if grep -q '^IPV6=' /etc/default/ufw; then
      sed -i -E 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
      die '/etc/default/ufw missing IPV6 setting.'
    fi
  fi
}
start_and_wait_fail2ban() {
  # systemctl restart returns before fail2ban.sock exists. A 45s readiness probe avoids that race.
  local i
  if ! fail2ban-client -t >/dev/null 2>&1; then
    fail2ban-client -t >&2 || true
    return 1
  fi
  systemctl enable fail2ban.service >/dev/null
  systemctl restart fail2ban.service
  for ((i=1; i<=45; i++)); do
    if fail2ban-client ping 2>/dev/null | grep 'pong' >/dev/null && \
       fail2ban-client status sshd >/dev/null 2>&1; then
      msg "Fail2ban ready (after ${i}s or less)."
      return 0
    fi
    if ! systemctl is-active --quiet fail2ban.service; then break; fi
    sleep 1
  done
  warn 'Fail2ban did not become ready. Recent service logs:'
  journalctl -u fail2ban.service -n 40 --no-pager >&2 || true
  return 1
}
write_jail() {
  local ports="$1" tmp
  tmp="$(mktemp /etc/fail2ban/jail.d/.vpn-hardening.XXXXXX)"
  cat > "$tmp" <<EOF_JAIL
# Managed by vpn-vps-hardening.
[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 4
findtime = 10m
bantime = 1h
EOF_JAIL
  chmod 0644 "$tmp"
  mv -f "$tmp" "$JAIL_CONFIG"
  start_and_wait_fail2ban
}
ssh_server_ip() {
  local ip=''
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS4 --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^[0-9.]+$ ]] && printf '%s' "$ip" || printf 'SERVER_IP'
}
# Human-readable instructions after every phase. There is deliberately NO
# automatic finalization: the operator must actually open a NEW SSH session.
print_step_title() {
  printf '\n%s\n' '=================================================================='
  printf ' %s\n' "$1"
  printf '%s\n' '=================================================================='
}
print_windows_ssh_command() {
  local public_ip="$1"
  printf '  ssh -i "$env:USERPROFILE\\.ssh\\vpn_vps" -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -p %s %s@%s\n' "$PORT" "$ADMIN" "$public_ip"
}
print_install_plan() {
  print_step_title 'ПЛАН НАСТРОЙКИ: 3 ЭТАПА'
  printf '%s\n' '  1/3 prepare  — обновить Ubuntu и настроить SSH, UFW, Fail2ban.'
  printf '%s\n' '  2/3 finalize — после входа ПО КЛЮЧУ с Windows на новый SSH-порт'
  printf '%s\n' '                 отключить порт 22 и парольную SSH-авторизацию.'
  printf '%s\n' '  3/3 confirm  — из ЕЩЁ ОДНОЙ НОВОЙ SSH-сессии подтвердить вход.'
  printf '\n%s\n' '  ВАЖНО: не закрывайте исходную SSH-сессию до шага 3/3.'
  printf '%s\n' '  Каждый этап выводит отдельные команды для следующего шага.'
  printf '%s\n' '  После confirm появится вопрос об установке 3x-ui с доменом и TLS.'
}
print_access_instructions() {
  local server_ip
  server_ip="$(ssh_server_ip)"
  print_step_title 'ЭТАП 1/3 ГОТОВ: НУЖНО ВРУЧНУЮ ПРОВЕРИТЬ НОВЫЙ SSH-ВХОД'
  printf 'Пользователь: %s | Новый SSH-порт: %s | Публичный IP: %s\n' "$ADMIN" "$PORT" "$server_ip"
  printf '%s\n' 'UFW и Fail2ban настроены. Порт 22 ПОКА оставлен для восстановления.'
  printf 'Если у провайдера включён внешний firewall, разрешите TCP/%s.\n' "$PORT"
  printf '%s\n' 'Если указанный IP недоступен, используйте IP из панели провайдера.'
  printf '\n%s\n' 'ДЕЙСТВИЕ 1. Откройте ВТОРОЕ окно PowerShell на вашем компьютере Windows.'
  printf '%s\n' 'Выполните (путь vpn_vps замените на путь к вашему приватному ключу):'
  print_windows_ssh_command "$server_ip"
  printf '\n%s\n' 'ДЕЙСТВИЕ 2. Убедитесь, что вход выполнен именно ПО КЛЮЧУ под указанным пользователем.'
  printf '%s\n' 'В ЭТОЙ НОВОЙ SSH-сессии на сервере выполните:'
  printf '  sudo --preserve-env=SSH_CONNECTION %s finalize\n' "$SELF"
  printf '\n%s\n' 'НЕ выполняйте confirm до успешного finalize.'
  printf '%s\n' 'После finalize скрипт сам выведет команды для третьей SSH-сессии.'
  printf '%s\n' 'НЕ закрывайте первоначальный терминал и НЕ перезагружайте VPS.'
  printf '\nЧтобы повторно посмотреть подсказку: sudo %s next\n' "$SELF"
  printf '%s\n\n' '=================================================================='
}
print_finalize_instructions() {
  local server_ip
  server_ip="$(ssh_server_ip)"
  print_step_title 'ЭТАП 2/3 ГОТОВ: НУЖНО ПОДТВЕРДИТЬ ВХОД ИЗ ТРЕТЬЕЙ SSH-СЕССИИ'
  printf 'SSH-порт: %s | Пользователь: %s | IP: %s\n' "$PORT" "$ADMIN" "$server_ip"
  printf '%s\n' 'Порт 22 закрыт, парольный вход в SSH отключён.'
  printf '\n%s\n' 'ДЕЙСТВИЕ 1. Откройте ТРЕТЬЕ, совершенно новое окно PowerShell в Windows.'
  printf '%s\n' 'Подключитесь по ключу ещё раз:'
  print_windows_ssh_command "$server_ip"
  printf '\n%s\n' 'ДЕЙСТВИЕ 2. В ТРЕТЬЕЙ SSH-сессии на сервере выполните:'
  printf '  sudo --preserve-env=SSH_CONNECTION %s confirm\n' "$SELF"
  printf '\n%s\n' 'ВАЖНО: confirm нельзя выполнять в той же сессии, где запускался finalize.'
  printf 'Отсчёт автоматического возврата порта 22: %s минут с запуска finalize.\n' "$((ROLLBACK_SECONDS/60))"
  printf '%s\n' 'НЕ закрывайте прежние сессии и НЕ перезагружайте сервер до SUCCESS.'
  printf '\nЧтобы повторно посмотреть подсказку: sudo %s next\n' "$SELF"
  printf '%s\n\n' '=================================================================='
}
print_complete_instructions() {
  print_step_title 'ЭТАП 3/3 ГОТОВ: НАСТРОЙКА БЕЗОПАСНОСТИ ПОДТВЕРЖДЕНА'
  printf 'SSH: порт %s, только ключ, пользователь %s; root-вход запрещён.\n' "$PORT" "$ADMIN"
  printf '%s\n' 'UFW: разрешены TCP 80, TCP 443 и выбранный SSH-порт; остальные входящие запрещены.'
  printf '%s\n' 'Fail2ban: включена защита SSH.'
  printf '\n%s\n' 'Проверьте итоговое состояние:'
  printf '  sudo %s status\n' "$SELF"
  printf '%s\n' 'Проверьте отдельное новое SSH-подключение, прежде чем закрывать старые окна.'
  printf '%s\n' 'Если Ubuntu требует перезагрузки, делайте её только ПОСЛЕ этой проверки.'
  if [[ -s "$PANEL_DOMAIN_FILE" ]]; then
    printf '%s\n' '3x-ui уже установлена. Посмотреть параметры:'
    printf '  sudo %s panel-info\n' "$SELF"
  else
    printf '%s\n' 'Опционально установить 3x-ui позже:'
    printf '  sudo %s install-3x-ui\n' "$SELF"
  fi
  printf '%s\n\n' '=================================================================='
}
print_next_steps() {
  # Caller already loaded PORT/ADMIN/MODE via read_saved.
  case "$MODE" in
    prepared) print_access_instructions ;;
    pending-confirm) print_finalize_instructions ;;
    complete) print_complete_instructions ;;
    preparing|setup-failed|rolled-back)
      print_step_title 'УСТАНОВКА НЕ ЗАВЕРШЕНА: ТРЕБУЕТСЯ ПОВТОРНАЯ ПОДГОТОВКА'
      printf 'Текущее состояние: %s; пользователь: %s; порт: %s.\n' "$MODE" "$ADMIN" "$PORT"
      printf '%s\n' 'Сначала проверьте доступ по старому SSH-порту 22 и наличие консоли провайдера.'
      printf '%s\n' 'В рабочей первоначальной SSH-сессии запустите:'
      printf '  sudo bash vpn-vps-hardening.sh prepare\n'
      printf '%s\n' 'Не запускайте finalize или confirm, пока prepare не покажет «ЭТАП 1/3 ГОТОВ».'
      ;;
    *) die "Неизвестное состояние: $MODE" ;;
  esac
}
next_steps() {
  require_ubuntu
  read_saved
  print_next_steps
}
restore_recovery_ssh() {
  # Called on errors and by a transient systemd rollback timer. Keep original SSH open.
  local ok=true
  ufw allow 22/tcp >/dev/null 2>&1 || ok=false
  write_ssh_stage || ok=false
  if ! "$SSHD" -t >/dev/null 2>&1; then
    # If an unexpected third-party SSH config conflicts with staging, remove
    # ONLY our managed file, falling back to the server's original config.
    warn 'Staging SSH config is invalid; trying the original SSH config.'
    rm -f "$SSH_CONFIG" || true
  fi
  if "$SSHD" -t >/dev/null 2>&1; then
    apply_ssh || ok=false
  else
    ok=false
    warn 'Original SSH config is also invalid; use provider console.'
  fi
  if ! listening 22; then ok=false; fi
  if [[ "$ok" == true ]]; then
    msg 'Recovery SSH listener confirmed on port 22.'
    return 0
  fi
  warn 'Recovery was incomplete: use provider rescue console. Do not close this SSH session.'
  return 1
}
prepare_error() {
  local rc="$1" line="$2"
  trap - ERR EXIT INT TERM HUP
  warn "Preparation failed near line $line (exit $rc). Keeping/reopening SSH port 22."
  restore_recovery_ssh || true
  [[ -d "$STATE" ]] && set_mode setup-failed || true
  warn 'Do not disconnect. Re-download the fixed script and run prepare to resume.'
  exit "$rc"
}
show_reboot_notice() {
  if [[ -e /run/reboot-required ]]; then
    warn 'Ubuntu reports that a reboot is needed. DO NOT reboot until SSH is confirmed and status is checked.'
  fi
}
update_packages_first() {
  msg 'STEP 1: Updating package indexes and installed Ubuntu packages (no release upgrade, no reboot).'
  # Preserve existing configuration during unattended dpkg upgrades.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -y -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    upgrade --with-new-pkgs
  msg 'STEP 2: Installing required packages (no Docker and no 3x-ui).'
  apt-get -y -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --no-install-recommends ufw fail2ban python3-systemd
  show_reboot_notice
}
prepare() {
  require_ubuntu
  require_tty
  lock_setup
  print_install_plan
  [[ -x "$SSHD" ]] || die 'OpenSSH server must already be installed.'
  "$SSHD" -t
  listening 22 || die 'Port 22 not listening. This script expects a working original SSH connection.'
  if command -v x-ui >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    die 'Existing 3x-ui or Docker detected. This script is for an unconfigured VPN server.'
  fi
  if systemctl is-active --quiet firewalld.service; then
    die 'firewalld is active; refusing to change its firewall.'
  fi
  local fresh=true reply passwd_state
  if [[ -e "$STATE/mode" ]]; then
    read_saved
    fresh=false
    case "$MODE" in
      prepared)
        if ufw_active && check_ufw_policy && check_allowed_rules yes && \
           valid_stage_ports && listening 22 && listening "$PORT" && \
           fail2ban-client status sshd >/dev/null 2>&1; then
          msg "Сервер уже подготовлен (порт $PORT). Обновляю установленный helper этой версией."
          local current_script
          current_script="$(readlink -f "$0")"
          [[ -f "$current_script" ]] || die 'Запускайте из сохранённого файла, а не из curl | bash.'
          install -m 0700 -o root -g root "$current_script" "$SELF"
          print_access_instructions
          return 0
        fi
        msg 'Saved mode is prepared but runtime is incomplete; repairing via prepare.' ;;
      complete) print_complete_instructions; die 'Установка уже завершена. Повторный prepare не нужен.' ;;
      pending-confirm) print_finalize_instructions; die 'Этап 2 уже выполняется: используйте confirm из третьей SSH-сессии.' ;;
      setup-failed|rolled-back|preparing) msg "RESUMING interrupted setup: admin=$ADMIN port=$PORT mode=$MODE" ;;
    esac
    local existing_home existing_keys
    existing_keys=''
    if id "$ADMIN" >/dev/null 2>&1; then
      [[ "$(id -u "$ADMIN")" -ge 1000 ]] || die 'Saved administrator is a system account.'
      existing_home="$(getent passwd "$ADMIN" | cut -d: -f6)"
      existing_keys="$existing_home/.ssh/authorized_keys"
    else
      msg "The saved administrator $ADMIN has not been created yet; will create it."
    fi
    managed_ssh_file_is_ours || die 'SSH managed file changed unexpectedly; do not overwrite it.'
    if [[ -z "$existing_keys" || ! -s "$existing_keys" ]]; then
      printf 'No saved SSH key for %s. Paste your public ssh-ed25519 key:\n> ' "$ADMIN"
    else
      printf 'Optional: paste a public ssh-ed25519 key to ADD, or press Enter to retain existing keys:\n> '
    fi
    IFS= read -r PUBLIC_KEY
    if [[ -z "$PUBLIC_KEY" && ( -z "$existing_keys" || ! -s "$existing_keys" ) ]]; then
      die 'A public SSH key is required when no usable key is installed.'
    fi
    if [[ -n "$PUBLIC_KEY" ]]; then check_pubkey "$PUBLIC_KEY" || die 'Invalid ED25519 public key.'; fi
  else
    [[ ! -e "$STATE" ]] || die 'Partial state directory without mode; manual review required.'
    [[ ! -e "$SSH_CONFIG" ]] || die "Existing $SSH_CONFIG; manual review required."
    [[ "$(ports_effective)" == '22' ]] || die 'SSH uses non-default/multiple ports; clean VPS expected.'
    printf 'Admin username [vpnadmin]: '
    read -r ADMIN
    ADMIN="${ADMIN:-vpnadmin}"
    valid_user "$ADMIN" || die 'Invalid administrator username.'
    if id "$ADMIN" >/dev/null 2>&1; then
      [[ "$(id -u "$ADMIN")" -ge 1000 ]] || die 'Existing account has a system UID.'
    fi
    printf '\nPaste ONE LINE of the ED25519 PUBLIC key (ssh-ed25519 AAAA...):\n> '
    IFS= read -r PUBLIC_KEY
    check_pubkey "$PUBLIC_KEY" || die 'Invalid ED25519 public key.'
    local tries
    for ((tries=0; tries<40; tries++)); do
      PORT="$(shuf -i 20000-29999 -n 1)"
      [[ "$PORT" == 21086 ]] && continue
      if ! listening "$PORT"; then break; fi
    done
    (( tries < 40 )) || die 'Unable to find unused high SSH port.'
  fi
  printf '\nSelected admin: %s; SSH port: %s\n' "$ADMIN" "$PORT"
  printf 'This operation updates Ubuntu and changes SSH + UFW.\n'
  printf 'Ensure VPS provider console/snapshot available. Continue [type YES]? '
  read -r reply
  [[ "$reply" == YES ]] || die 'Cancelled.'

  # Upgrade only AFTER checking current port 22 is live, BEFORE any SSH/firewall changes.
  update_packages_first
  "$SSHD" -t
  listening 22 || die 'Original SSH port 22 stopped after upgrades. Restore access before proceeding.'
  [[ -r /etc/default/ufw ]] || die '/etc/default/ufw is missing.'
  if [[ "$fresh" == true ]]; then
    if ufw_active || ufw show added | grep '^ufw ' >/dev/null; then
      die 'UFW already has active/custom rules on this ostensibly fresh host; review manually.'
    fi
    [[ ! -e "$JAIL_CONFIG" ]] || die 'Our Fail2ban jail config already exists without saved setup state.'
  else
    if ufw_active; then
      check_ufw_policy && check_allowed_rules yes || die 'Unexpected current UFW rules/policy; review manually.'
    else
      # The previous script can leave a correct saved allowlist when UFW is
      # inactive. Reuse it, or offer an explicit backed-up reset of stale rules.
      review_inactive_ufw_rules
    fi
  fi
  ensure_ipv6_ufw

  if [[ "$fresh" == true ]]; then
    mkdir -m 0700 -p "$STATE"
    printf '%s\n' "$PORT" > "$STATE/port"
    printf '%s\n' "$ADMIN" > "$STATE/admin"
  fi
  set_mode preparing
  # ERR alone does not catch explicit `exit` or all interrupted operations.
  trap 'prepare_error "$?" "$LINENO"' ERR EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  if ! id "$ADMIN" >/dev/null 2>&1; then
    adduser --disabled-password --gecos '' "$ADMIN"
  fi
  usermod -aG sudo "$ADMIN"
  passwd_state="$(passwd -S "$ADMIN" | awk '{print $2}')"
  if [[ "$fresh" == true || "$passwd_state" != P ]]; then
    msg "Set a LOCAL sudo password for $ADMIN (SSH password access will be disabled after confirmation)."
    passwd "$ADMIN"
  fi
  set_admin_key
  install -m 0700 -o root -g root "$(readlink -f "$0")" "$SELF"
  msg 'STEP 3: Opening the second SSH port while keeping port 22 as recovery.'
  neutralize_external_port22
  write_ssh_stage
  "$SSHD" -t
  valid_stage_ports
  apply_ssh
  listening 22 && listening "$PORT" || { warn 'Expected BOTH SSH ports to listen.'; false; }
  msg 'STEP 4: Enabling deny-by-default UFW with 22 (temporary), new SSH, 80/tcp, 443/tcp.'
  ensure_ufw_stage
  msg 'STEP 5: Configuring Fail2ban, waiting until its socket and sshd jail are ready.'
  write_jail "22,$PORT"
  listening 22 && listening "$PORT" && check_ufw_policy && check_allowed_rules yes || {
    warn 'Staged security verification failed.'; false;
  }
  set_mode prepared
  trap - ERR EXIT INT TERM HUP
  print_access_instructions
}
require_admin_session() {
  [[ "${SUDO_USER:-}" == "$ADMIN" ]] || die "Run via sudo as $ADMIN, not from a root SSH session."
  [[ -n "${SSH_CONNECTION:-}" ]] || die 'SSH_CONNECTION missing; pass sudo --preserve-env=SSH_CONNECTION.'
  local src srcport dst dstport
  read -r src srcport dst dstport <<< "$SSH_CONNECTION"
  [[ "$dstport" == "$PORT" ]] || die "Connect through new SSH port $PORT first."
}
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
  if [[ "$MODE" != prepared && "$MODE" != rolled-back ]]; then
    print_next_steps
    die "Сейчас состояние $MODE: finalize доступен только после prepare и проверки входа по ключу."
  fi
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
  print_finalize_instructions
}
confirm() {
  require_ubuntu
  lock_setup
  read_saved
  if [[ "$MODE" != pending-confirm ]]; then
    print_next_steps
    if [[ "$MODE" == prepared ]]; then
      die "Команда confirm запущена слишком рано: сначала выполните finalize в новой SSH-сессии на порту $PORT."
    fi
    die "Команда confirm сейчас недоступна (состояние: $MODE)."
  fi
  require_admin_session
  [[ -s "$STATE/finalize_session" ]] || die 'Missing finalization session marker.'
  if [[ "${SSH_CONNECTION:-}" == "$(cat "$STATE/finalize_session")" ]]; then
    print_finalize_instructions
    die 'Команда confirm должна выполняться из ТРЕТЬЕЙ, новой SSH-сессии.'
  fi
  verify_final || die 'SSH/UFW/Fail2ban verification failed; rollback is still scheduled.'
  # Commit state FIRST: even if systemd stop fails, a late timer will see 'complete' and do nothing.
  set_mode complete
  if [[ -s "$STATE/rollback_timer" ]]; then
    systemctl stop "$(cat "$STATE/rollback_timer")" || warn 'Timer stop failed, but commit state prevents rollback.'
  fi
  msg "SUCCESS. SSH: $ADMIN via key at TCP/$PORT. UFW: only TCP/80, TCP/443 and TCP/$PORT."
  msg 'Fail2ban активен. Docker не устанавливается. Порт панели пока закрыт.'
  print_complete_instructions
  show_reboot_notice
  maybe_offer_3x_ui
}
# 3x-ui is a separate, optional phase and must NEVER run while SSH rollback
# is pending. A failed panel/TLS installation does not undo confirmed SSH.
valid_domain() {
  local domain="$1" label
  [[ ${#domain} -ge 4 && ${#domain} -le 253 && "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
  [[ "$domain" != *..* && "$domain" != .* && "$domain" != *. ]] || return 1
  local -a labels
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  # Do not accept an IP address or a bare local name; require a nonnumeric TLD.
  [[ "${labels[${#labels[@]}-1]}" =~ ^[A-Za-z][A-Za-z0-9-]+$ ]]
}
valid_email() {
  [[ -z "$1" || ( "$1" =~ ^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ && ${#1} -le 254 ) ]]
}
# Read only plain generated alphanumeric fields from the root-only upstream
# installation summary; never `source` downloaded or mutable config as shell.
panel_result_value() {
  local field="$1"
  [[ "$field" =~ ^XUI_[A-Z_]+$ ]] || return 1
  [[ -s "$XUI_INSTALL_RESULT" ]] || return 1
  awk -F= -v key="$field" '$1==key && $2 ~ /^[a-zA-Z0-9_-]+$/ { print $2; exit }' "$XUI_INSTALL_RESULT"
}
print_panel_tunnel_instructions() {
  local panelport="$1" domain="$2" basepath="$3" public_ip
  public_ip="$(ssh_server_ip)"
  print_step_title 'ДОСТУП К ПАНЕЛИ 3x-ui: ТОЛЬКО ЧЕРЕЗ SSH-ТУННЕЛЬ'
  printf '%s\n' 'Порт панели закрыт снаружи. Настройка UFW НЕ изменялась.'
  printf '%s\n' 'ШАГ 1. Откройте PowerShell на Windows и оставьте команду работающей:'
  printf '  ssh -N -L 127.0.0.1:%s:127.0.0.1:%s -i "$env:USERPROFILE\\.ssh\\vpn_vps" -p %s %s@%s\n' \
    "$panelport" "$panelport" "$PORT" "$ADMIN" "$public_ip"
  printf '\n%s\n' 'ШАГ 2. Чтобы сертификат для домена проверялся БЕЗ предупреждения,'
  printf '%s\n' 'на своём ПК пропишите ЭТОТ ОТДЕЛЬНЫЙ ДОМЕН панели на 127.0.0.1'
  printf '%s\n' 'в Windows hosts (запуск Блокнота с правами администратора):'
  printf '  127.0.0.1 %s\n' "$domain"
  printf 'Файл: C:\\Windows\\System32\\drivers\\etc\\hosts\n'
  printf '%s\n' 'ВАЖНО: домен панели не должен одновременно использоваться для VPN-клиентов.'
  printf '\n%s\n' 'ШАГ 3. Откройте в браузере Windows через SSH-туннель:'
  printf '  https://%s:%s/%s\n' "$domain" "$panelport" "$basepath"
  printf '%s\n' 'Убрать перенаправление можно удалением этой строки из hosts.'
  printf '%s\n' 'Для управления панелью на сервере: sudo x-ui'
}
panel_info() {
  require_ubuntu
  read_saved
  [[ "$MODE" == complete ]] || die 'Сначала завершите SSH-настройку командами finalize и confirm.'
  if [[ ! -e "$PANEL_DOMAIN_FILE" || ! -s "$PANEL_DOMAIN_FILE" ]]; then
    msg 'Установленная этим скриптом 3x-ui пока не обнаружена.'
    printf 'Установить: sudo %s install-3x-ui\n' "$SELF"
    return 0
  fi
  local domain panel_port base_path user pass cert_status listen_ip
  domain="$(cat "$PANEL_DOMAIN_FILE")"
  valid_domain "$domain" || die 'Сохранён некорректный домен панели.'
  if [[ ! -x /usr/local/x-ui/x-ui ]]; then die '3x-ui executable not found; installation may be incomplete.'; fi
  panel_port="$(panel_result_value XUI_PANEL_PORT || true)"
  base_path="$(panel_result_value XUI_WEB_BASE_PATH || true)"
  user="$(panel_result_value XUI_USERNAME || true)"
  pass="$(panel_result_value XUI_PASSWORD || true)"
  listen_ip="$(/usr/local/x-ui/x-ui setting -getListenIP true 2>/dev/null || true)"
  cert_status='НЕ ПОДТВЕРЖДЁН'
  if [[ -s "/root/cert/${domain}/fullchain.pem" && -s "/root/cert/${domain}/privkey.pem" ]]; then
    cert_status='Файлы сертификата присутствуют'
  fi
  print_step_title 'НАСТРОЙКИ 3x-ui'
  printf 'Домен: %s\nПорт панели: %s\nПуть: /%s\nПользователь: %s\n' \
    "$domain" "${panel_port:-неизвестен}" "${base_path:-неизвестен}" "${user:-см. sudo x-ui}"
  printf 'Пароль (виден только root): %s\n' "${pass:-см. sudo x-ui для сброса}"
  printf 'SSL: %s\nПривязка панели: %s\n' "$cert_status" "${listen_ip:-не удалось проверить}"
  printf '%s\n' 'Учетные данные хранятся в /etc/x-ui/install-result.env (root, 0600).'
  if [[ "$panel_port" =~ ^[0-9]+$ && -n "$base_path" ]]; then
    print_panel_tunnel_instructions "$panel_port" "$domain" "$base_path"
  fi
}
preflight_panel_domain() {
  local domain="$1" server_ip addresses
  server_ip="$(ssh_server_ip)"
  addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | LC_ALL=C sort -u || true)"
  [[ -n "$addresses" ]] || die "DNS A для $domain не найден. Создайте A-запись на IP VPS и повторите установку."
  msg "DNS A для $domain: $(tr '\n' ' ' <<< "$addresses")"
  if [[ "$server_ip" != SERVER_IP ]]; then
    if ! grep -Fxq -- "$server_ip" <<< "$addresses"; then
      die "Домен $domain сейчас НЕ указывает на публичный IP VPS ($server_ip). Исправьте DNS; для Cloudflare отключите proxy (DNS only), затем повторите."
    fi
  else
    warn 'Публичный IP VPS не удалось автоматически определить. Сравните DNS вручную с IP провайдера.'
    printf '%s\n' 'Если A-запись действительно указывает на этот VPS, введите DNS-OK; иначе Enter:'
    local yes
    read -r yes
    [[ "$yes" == DNS-OK ]] || die 'DNS проверка не подтверждена.'
  fi
  if listening 80; then
    die 'Порт 80 уже занят локальным процессом. ACME HTTP-01 не сможет выдать сертификат, освободите порт 80.'
  fi
  check_ufw_policy && check_allowed_rules no || die 'Сначала устраните проблемы UFW (нужны только 80/443/SSH).'
}
check_panel_tls() {
  local domain="$1" panel_port="$2" web_path="$3" cert key result verifycode httpcode listener
  cert="/root/cert/$domain/fullchain.pem"
  key="/root/cert/$domain/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || { warn "Файлы SSL отсутствуют: $cert или $key"; return 1; }
  openssl x509 -in "$cert" -noout -checkhost "$domain" | grep -Fq 'does match' || {
    warn 'Выпущенный сертификат НЕ совпадает с указанным доменом.'; return 1;
  }
  openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null || {
    warn 'Сертификат истекает менее чем через 7 дней.'; return 1;
  }
  listener="$(/usr/local/x-ui/x-ui setting -getListenIP true 2>/dev/null || true)"
  grep -Eq '^listenIP:[[:space:]]+127\.0\.0\.1$' <<< "$listener" || {
    warn 'Панель не подтверждена как привязанная ТОЛЬКО к 127.0.0.1.'; return 1;
  }
  # Enforce the actual TCP bind address, not just the setting stored in SQLite.
  if ! ss -H -lnt | awk -v want="127.0.0.1:${panel_port}" -v port="$panel_port" '
    { local_addr=$4; p=local_addr; sub(/^.*:/, "", p);
      if (p==port) { if (local_addr==want) good=1; else bad=1 } }
    END {exit(!good || bad)}'; then
    warn 'Панель слушает не только 127.0.0.1 или ещё не запущена.'
    return 1
  fi
  # A TLS handshake to localhost while validating the actual domain; no -k.
  # A login page can return a redirect/4xx; HTTP 000 means no response.
  result="$(curl --noproxy '*' --silent --show-error --max-time 12 \
    --resolve "${domain}:${panel_port}:127.0.0.1" \
    -o /dev/null -w '%{ssl_verify_result} %{http_code}' \
    "https://${domain}:${panel_port}/${web_path}" 2>/dev/null || true)"
  verifycode="${result%% *}"
  httpcode="${result##* }"
  if [[ "$verifycode" != 0 || ! "$httpcode" =~ ^[1-5][0-9][0-9]$ ]]; then
    warn "HTTPS-проверка не пройдена (TLS-verify=${verifycode:-?}, HTTP=${httpcode:-?})."
    return 1
  fi
  return 0
}
check_acme_renewal() {
  local domain="$1" acme='/root/.acme.sh/acme.sh'
  [[ -x "$acme" ]] || { warn 'acme.sh не найден.'; return 1; }
  systemctl enable --now cron.service >/dev/null || { warn 'cron не запускается.'; return 1; }
  crontab -u root -l 2>/dev/null | grep -Fq '.acme.sh/acme.sh' || {
    warn 'Не найдена задача acme.sh в root crontab.'; return 1;
  }
  "$acme" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "$domain" || {
    warn "Не найден ACME-заказ для домена $domain."; return 1;
  }
  return 0
}
install_3x_ui() {
  require_ubuntu
  require_tty
  lock_setup
  read_saved
  [[ "$MODE" == complete ]] || {
    print_next_steps
    die '3x-ui можно устанавливать ТОЛЬКО после успешного confirm.'
  }
  verify_final || die 'Проверка SSH/UFW/Fail2ban не пройдена; установка 3x-ui отменена.'
  if [[ -x /usr/local/x-ui/x-ui || -e /etc/x-ui/x-ui.db ]] || command -v x-ui >/dev/null 2>&1; then
    warn '3x-ui уже существует: повторная установка может потерять настройки. Ничего не перезаписываем.'
    printf 'Для управления: sudo x-ui; для проверки: sudo %s panel-info\n' "$SELF"
    return 1
  fi
  local domain email yes new_port new_path new_username new_password public_ip temp_dir tmp_installer basepath persisted_ip
  print_step_title 'ОПЦИОНАЛЬНАЯ УСТАНОВКА 3x-ui (официальный репозиторий MHSanaei/3x-ui)'
  printf '%s\n' 'Панель будет слушать только 127.0.0.1 (доступ через SSH-туннель).'
  printf '%s\n' 'Извне останутся открыты ТОЛЬКО TCP 80, 443 и SSH-порт.'
  printf '%s\n' 'Укажите ОТДЕЛЬНЫЙ поддомен для панели, например panel.example.com.'
  printf '%s\n' 'Создайте DNS A-запись этого поддомена на публичный IP VPS.'
  printf 'Домен панели (Enter — отменить установку): '
  IFS= read -r domain
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg 'Установка 3x-ui отменена. Настройки SSH не изменены.'; return 0; }
  valid_domain "$domain" || die 'Некорректный домен: требуется FQDN вида panel.example.com (ASCII/Punycode).'
  printf 'Email для Lets Encrypt (необязательно, Enter — пропустить): '
  IFS= read -r email
  valid_email "$email" || die 'Некорректный email.'
  preflight_panel_domain "$domain"
  command -v curl >/dev/null && command -v openssl >/dev/null || die 'Нужны curl и openssl.'
  new_port=''
  local i
  for ((i=0; i<40; i++)); do
    new_port="$(shuf -i 30000-60999 -n 1)"
    if [[ "$new_port" != "$PORT" && "$new_port" != 21086 ]] && ! listening "$new_port"; then break; fi
  done
  (( i < 40 )) || die 'Не удалось подобрать свободный порт панели.'
  new_path="panel$(openssl rand -hex 12)"
  new_username="admin$(openssl rand -hex 5)"
  new_password="$(openssl rand -hex 18)"
  printf '\nДомен: %s | Порт панели: %s | путь: /%s\n' "$domain" "$new_port" "$new_path"
  printf '%s\n' 'Установка официального 3x-ui + сертификат Lets Encrypt + cron auto-renew.'
  printf 'Введите INSTALL-3XUI для подтверждения: '
  IFS= read -r yes
  [[ "$yes" == INSTALL-3XUI ]] || { msg 'Установка 3x-ui отменена. SSH-настройки не изменены.'; return 0; }
  # Bring the durable installed helper to the downloaded verified version.
  local self_source
  self_source="$(readlink -f "$0")"
  if [[ "$self_source" != "$SELF" && -f "$self_source" ]]; then
    install -m 0700 -o root -g root "$self_source" "$SELF"
  fi
  temp_dir="$(mktemp -d /root/.vpn-xui-installer.XXXXXXXX)"
  tmp_installer="$temp_dir/install.sh"
  msg 'Скачиваю установщик с официального GitHub MHSanaei/3x-ui (latest stable).'
  if ! curl --fail --location --show-error --silent --retry 2 --connect-timeout 15 --max-time 120 \
    "$XUI_INSTALLER_URL" -o "$tmp_installer"; then
    rm -rf "$temp_dir"
    die 'Не удалось скачать официальный скрипт.'
  fi
  if [[ ! -s "$tmp_installer" ]] || ! bash -n "$tmp_installer"; then
    rm -rf "$temp_dir"
    die 'Установщик не прошёл проверку bash -n.'
  fi
  printf '\nИсходный установщик: %s\nSHA-256: ' "$XUI_INSTALLER_URL"
  sha256sum "$tmp_installer" | awk '{print $1}'
  printf '%s\n' 'Если вам необходимо изучить код перед запуском, нажмите Ctrl+C сейчас.'
  msg 'Запуск официального установщика с автонастройкой SSL для домена.'
  # This is an upstream script, not our own; errors affect 3x-ui, never SSH.
  # The official installer writes credentials in /etc/x-ui/install-result.env mode 0600.
  local install_rc=0
  XUI_NONINTERACTIVE=1 XUI_SSL_MODE=domain XUI_DOMAIN="$domain" XUI_ACME_EMAIL="$email" \
  XUI_PANEL_PORT="$new_port" XUI_WEB_BASE_PATH="$new_path" \
  XUI_USERNAME="$new_username" XUI_PASSWORD="$new_password" \
  XUI_DB_TYPE=sqlite XUI_ENABLE_FAIL2BAN=false \
  bash "$tmp_installer" || install_rc=$?
  rm -rf "$temp_dir"
  if (( install_rc != 0 )); then
    warn "Установка 3x-ui завершилась ошибкой (код $install_rc). Защита SSH сохранена."
    printf '%s\n' 'Диагностика: sudo systemctl status x-ui --no-pager; sudo journalctl -u x-ui -n 60 --no-pager'
    return "$install_rc"
  fi
  [[ -x /usr/local/x-ui/x-ui ]] || die 'Установщик завершился, но бинарный файл /usr/local/x-ui/x-ui отсутствует.'
  systemctl is-active --quiet x-ui.service || die 'Служба x-ui не запущена.'
  # Allow local access only. No UFW rule for the web admin port.
  msg 'Ограничиваю интерфейс панели адресом 127.0.0.1; наружу порт не открываю.'
  /usr/local/x-ui/x-ui setting -listenIP '127.0.0.1' || die 'Не удалось настроить loopback.'
  systemctl restart x-ui.service || die 'Не удалось перезапустить x-ui после ограничения доступа.'
  sleep 2
  systemctl is-active --quiet x-ui.service || die 'x-ui остановился после настройки 127.0.0.1.'
  # Sensitive install result is stored upstream; don't create an extra secret store.
  local recorded_username recorded_password recorded_port recorded_path credentials_verified=true
  recorded_username="$(panel_result_value XUI_USERNAME || true)"
  recorded_password="$(panel_result_value XUI_PASSWORD || true)"
  recorded_port="$(panel_result_value XUI_PANEL_PORT || true)"
  recorded_path="$(panel_result_value XUI_WEB_BASE_PATH || true)"
  if [[ "$recorded_username" != "$new_username" || "$recorded_password" != "$new_password" ||
        "$recorded_port" != "$new_port" || "$recorded_path" != "$new_path" ]]; then
    credentials_verified=false
    warn 'Официальный установщик не подтвердил все созданные учетные данные в /etc/x-ui/install-result.env.'
    warn 'Проверьте вывод установщика и команду sudo x-ui для получения/сброса параметров.'
  fi
  printf '%s\n' "$domain" > "$PANEL_DOMAIN_FILE"
  chmod 0600 "$PANEL_DOMAIN_FILE"
  msg 'Проверяю сертификат, соединение HTTPS и автоматическое продление.'
  local tls_ok=true renewal_ok=true
  check_panel_tls "$domain" "$new_port" "$new_path" || tls_ok=false
  check_acme_renewal "$domain" || renewal_ok=false
  print_step_title 'РЕЗУЛЬТАТ УСТАНОВКИ 3x-ui'
  printf 'Домен: %s\nПорт панели (только localhost): %s\nПуть: /%s\n' "$domain" "$new_port" "$new_path"
  if [[ "$credentials_verified" == true ]]; then
    printf 'Логин: %s\nПароль: %s\n' "$recorded_username" "$recorded_password"
  else
    printf '%s\n' 'Логин/пароль: НЕ ПОДТВЕРЖДЕНЫ (используйте sudo x-ui).'
  fi
  printf 'Сертификат: /root/cert/%s/fullchain.pem\nКлюч: /root/cert/%s/privkey.pem\n' "$domain" "$domain"
  if [[ "$tls_ok" == true && "$renewal_ok" == true ]]; then
    msg 'SSL, HTTPS и плановое продление сертификата подтверждены.'
  else
    warn 'НЕ ВСЕ проверки SSL/автопродления прошли. Не объявляем панель полностью настроенной.'
    printf '%s\n' 'Проверьте DNS/порт 80 и выполните: sudo x-ui → SSL Certificate Management.'
    printf '%s\n' 'Продление: sudo crontab -l; sudo systemctl status cron'
  fi
  print_panel_tunnel_instructions "$new_port" "$domain" "$new_path"
  printf '\nПосмотреть настройки позже: sudo %s panel-info\n' "$SELF"
  # Warn callers with nonzero status if SSL or renewal isn't verified.
  [[ "$tls_ok" == true && "$renewal_ok" == true && "$credentials_verified" == true ]]
}
maybe_offer_3x_ui() {
  if [[ ! -t 0 ]]; then
    msg "3x-ui не установлен. Для установки позже: sudo $SELF install-3x-ui"
    return 0
  fi
  print_step_title 'ДОПОЛНИТЕЛЬНО: УСТАНОВИТЬ 3x-ui?'
  printf '%s\n' 'SSH/UFW/Fail2ban уже защищены, и порт 22 закрыт.'
  printf '%s\n' 'Хотите сразу установить 3x-ui, домен, SSL и автопродление? [y/N]: '
  local choice
  IFS= read -r choice
  case "$choice" in
    y|Y|yes|YES|да|ДА|Да)
      # confirm() holds a flock descriptor; release it before acquiring again.
      flock -u 9 >/dev/null 2>&1 || true
      install_3x_ui || warn 'Дополнительная установка 3x-ui не завершена; SSH/UFW/Fail2ban УЖЕ подтверждены.' ;;
    *)
      msg '3x-ui не установлен. Установить позже:'
      printf '  sudo %s install-3x-ui\n' "$SELF" ;;
  esac
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
  if [[ -s "$PANEL_DOMAIN_FILE" ]]; then
    msg 'Для просмотра параметров 3x-ui: sudo /usr/local/sbin/vpn-vps-hardening panel-info'
  fi
  print_next_steps
}
usage() {
  cat <<EOF_USAGE
vpn-vps-hardening.sh v$VERSION — Ubuntu 24.04 LTS, VPS для 3x-ui

Последовательность из ТРЁХ ЭТАПОВ (не запускайте все команды подряд):
  1. sudo bash vpn-vps-hardening.sh prepare
     Обновление системы, подготовка SSH, UFW и Fail2ban.
     Затем войдите по SSH-ключу из ВТОРОГО окна PowerShell на новый порт.

  2. sudo --preserve-env=SSH_CONNECTION $SELF finalize
     Выполнить только из второй, новой SSH-сессии.
     Порт 22 закрывается, парольный вход отключается, включается таймер отката.

  3. sudo --preserve-env=SSH_CONNECTION $SELF confirm
     Выполнить только из ТРЕТЬЕЙ, новой SSH-сессии.
     Проверка входа и остановка таймера автоматического отката.

  sudo $SELF next       — показать инструкции для ТЕКУЩЕГО этапа
  sudo $SELF status     — статус сервера и дальнейшие шаги
  sudo $SELF --version — версия скрипта
  sudo $SELF install-3x-ui — ПОСЛЕ confirm: установить 3x-ui + домен + SSL
  sudo $SELF panel-info   — показать сохранённые настройки 3x-ui

  ИНФОРМАЦИЯ ПО БЕЗОПАСНОСТИ
  Перед запуском сделайте snapshot и проверьте аварийную консоль провайдера.
  Не закрывайте текущий SSH-сеанс до успешного confirm.
  Не перезагружайте Ubuntu до confirm и проверки нового подключения.
  Скрипт НЕ устанавливает Docker, VPN-инбаунды или веб-сервер.
  3x-ui устанавливается опционально ПОСЛЕ подтверждения SSH.
  Бэкапы конфликтующих SSH-конфигураций: $STATE/ssh-port-backups/.
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
    next|guide|what-next) next_steps ;;
    install-3x-ui|setup-3x-ui) install_3x_ui ;;
    panel-info|3x-ui-info) panel_info ;;
    --version|-v) printf '%s\n' "$VERSION" ;;
    --help|-h|'') usage ;;
    *) usage; die "Unknown operation: $1" ;;
  esac
}
main "$@"
