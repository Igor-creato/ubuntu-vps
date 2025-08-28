#!/usr/bin/env bash
# ssh-setup.sh
# Безопасная настройка SSH: создание пользователя/ключей, смена порта, UFW и fail2ban.
# Поддерживает неинтерактивные флаги:
#   --user <name>            имя пользователя (если не задано — интерактивно)
#   --port <num>             порт SSH (1024-65535)
#   --key-file <path>        путь к публичному ключу (OpenSSH формат)
#   --nopasswd-sudo          выдать пользователю sudo без пароля (повышенный риск)
#   --non-interactive        ошибаться вместо вопросов
#   --port-only              пропустить создание/ключи, сменить только порт для существующего пользователя (спросит имя, если нет --user)

set -euo pipefail

: "${user:=${username:-${USERNAME:-}}}"

# ----------------------------
# Общие функции и проверки
# ----------------------------
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
print_ok()      { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
print_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
print_err()     { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

trap 'print_err "Ошибка на строке $LINENO"; exit 1' ERR

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  print_err "Запустите скрипт от root: sudo $0 ..."
  exit 1
fi

# ----------------------------
# Парсинг аргументов
# ----------------------------
USERNAME=""
NEW_PORT=""
KEY_FILE=""
NOPASSWD_SUDO=false
NONINTERACTIVE=false
PORT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           USERNAME="${2:-}"; shift 2;;
    --port)           NEW_PORT="${2:-}"; shift 2;;
    --key-file)       KEY_FILE="${2:-}"; shift 2;;
    --nopasswd-sudo)  NOPASSWD_SUDO=true; shift 1;;
    --non-interactive)NONINTERACTIVE=true; shift 1;;
    --port-only)      PORT_ONLY=true; shift 1;;
    *) print_err "Неизвестный аргумент: $1"; exit 1;;
  esac
done

# ----------------------------
# Утилиты-валидаторы
# ----------------------------
is_valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1024 && p<=65535 ))
}

port_is_free() {
  local p="$1"
  # Проверяем LISTEN через ss; матчим по границе (:PORT и ]:PORT для IPv6)
  ! ss -Htlpn | grep -E "[:\]]${p}\b" >/dev/null 2>&1
}

require_value() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    if $NONINTERACTIVE; then
      print_err "Требуется параметр: $name"
      exit 1
    else
      return 1
    fi
  fi
}

# ----------------------------
# Подготовка системы и пакетов
# ----------------------------
export DEBIAN_FRONTEND=noninteractive
print_info "Обновление списка пакетов и установка зависимостей..."
apt-get update -y
apt-get install -y openssh-server ufw fail2ban
dpkg --configure -a || true
apt-get -y --fix-broken install || true
apt-get -y upgrade
apt-get -y dist-upgrade || true
apt-get -y autoremove --purge
apt-get -y autoclean

systemctl enable ssh --now

# ----------------------------
# Пользователь
# ----------------------------
if $PORT_ONLY; then
  # Только смена порта; нужен существующий пользователь для AllowUsers
  if ! require_value "--user" "$USERNAME"; then
    read -r -p "Введите имя существующего пользователя: " USERNAME
  fi
  if ! id "$USERNAME" &>/dev/null; then
    print_err "Пользователь '$USERNAME' не найден"
    exit 1
  fi
else
  if ! require_value "--user" "$USERNAME"; then
    read -r -p "Введите имя нового пользователя: " USERNAME
  fi
  while ! is_valid_username "$USERNAME" || id "$USERNAME" &>/dev/null; do
    print_err "Неверное имя или пользователь уже существует"
    if $NONINTERACTIVE; then exit 1; fi
    read -r -p "Введите имя нового пользователя: " USERNAME
  done

  print_info "Создание пользователя '$USERNAME'..."
  adduser --disabled-password --gecos "" "$USERNAME"
  usermod -aG sudo "$USERNAME"

  if $NOPASSWD_SUDO; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
  else
    echo "$USERNAME ALL=(ALL) ALL" > "/etc/sudoers.d/$USERNAME"
  fi
  chmod 440 "/etc/sudoers.d/$USERNAME"
  print_ok "Пользователь создан и добавлен в sudo."
fi

# ----------------------------
# Ключи SSH
# ----------------------------
setup_ssh_keys() {
  local user="$1" home_dir="/home/$user"

  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chown "$user:$user" "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"

  local pubkey=""
  if [[ -n "$KEY_FILE" ]]; then
    if [[ -f "$KEY_FILE" ]]; then
      pubkey="$(cat "$KEY_FILE")"
    else
      print_err "Файл ключа не найден: $KEY_FILE"
      exit 1
    fi
  else
    # Пытаемся взять все ключи из root
    for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub /root/.ssh/authorized_keys; do
      if [[ -f "$f" ]]; then
        pubkey="$(cat "$f")"
        break
      fi
    done
  fi

  if [[ -z "${pubkey}" ]]; then
    if $NONINTERACTIVE; then
      print_err "Публичный ключ не найден. Задайте --key-file или используйте режим без интерактива."
      exit 1
    fi
    print_info "Публичный ключ не найден."
    echo "1) Ввести свой ключ"
    echo "2) Сгенерировать новый ed25519"
    while true; do
      read -r -p "Ваш выбор (1/2): " ch
      case "$ch" in
        1)
          print_info "Вставьте PUBLIC key (OpenSSH, одна строка на ключ), затем Ctrl+D:"
          pubkey="$(cat)"
          [[ -n "$pubkey" ]] && break
          print_err "Ключ пустой или неверного формата";;
        2)
          install -d -m 700 -o root -g root /root/.ssh
          local name="${user}_ed25519"
          ssh-keygen -t ed25519 -f "/root/.ssh/${name}" -N "" -C "${user}@$(hostname)"
          pubkey="$(cat "/root/.ssh/${name}.pub")"
          print_ok "Сгенерирован ключ. Приватный ключ: /root/.ssh/${name}  (НЕ публикуйте его!)."
          break;;
        *) print_err "Выберите 1 или 2";;
      esac
    done
  fi

  # Добавляем все ключи построчно, если их ещё нет
  local tmpfile
  tmpfile="$(mktemp)"
  cat "$home_dir/.ssh/authorized_keys" > "$tmpfile"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -qxF "$line" "$tmpfile"; then
      echo "$line" >> "$tmpfile"
    fi
  done <<< "$pubkey"

  install -m 600 -o "$user" -g "$user" "$tmpfile" "$home_dir/.ssh/authorized_keys"
  rm -f "$tmpfile"
  print_ok "Публичный ключ(и) установлен(ы) пользователю $user."
}



if ! $PORT_ONLY; then
  setup_ssh_keys "$USERNAME"
fi

# ----------------------------
# Выбор/проверка порта
# ----------------------------
if ! require_value "--port" "$NEW_PORT"; then
  while true; do
    read -r -p "Введите новый порт SSH (1024-65535): " NEW_PORT
    if is_valid_port "$NEW_PORT" && port_is_free "$NEW_PORT"; then break; fi
    print_err "Порт недопустим или занят"; [[ $NONINTERACTIVE == true ]] && exit 1
  done
else
  if ! is_valid_port "$NEW_PORT"; then
    print_err "Недопустимый порт: $NEW_PORT"
    exit 1
  fi
  if ! port_is_free "$NEW_PORT"; then
    print_err "Порт уже занят: $NEW_PORT"
    exit 1
  fi
fi

# ----------------------------
# UFW — безопасная последовательность
# ----------------------------
print_info "Настройка UFW (брандмауэр)..."
ufw default deny incoming
ufw default allow outgoing

# Разрешаем 80/443 (часто нужны на серверах)
ufw allow 80/tcp
ufw allow 443/tcp

# Разрешим текущий 22/tcp (на случай активной сессии) и НОВЫЙ порт
ufw allow 22/tcp || true
ufw allow "${NEW_PORT}/tcp"
ufw limit "${NEW_PORT}/tcp" || true

# Включаем UFW только после всех правил
ufw --force enable

# ----------------------------
# OpenSSH: drop-in конфиг
# ----------------------------
print_info "Применение безопасных настроек SSH..."
install -d -m 0755 /etc/ssh/sshd_config.d

# На случай, если в основном файле явно задан Port — аккуратно закомментируем его (чтобы drop-in имел приоритет)
if grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config; then
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i 's/^\([[:space:]]*Port[[:space:]]\+[0-9]\+\)/# \1  # disabled by ssh-setup.sh/g' /etc/ssh/sshd_config
fi

cat >/etc/ssh/sshd_config.d/10-hardening.conf <<EOF
# Managed by ssh-setup.sh
Port ${NEW_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowUsers ${USERNAME}
EOF

# Проверяем конфиг sshd и перезапускаем
/usr/sbin/sshd -t
systemctl daemon-reload
systemctl restart ssh

# ----------------------------
# fail2ban
# ----------------------------
print_info "Настройка fail2ban..."
install -d -m 0755 /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ${NEW_PORT}
filter   = sshd
logpath  = /var/log/auth.log
backend  = systemd
EOF

systemctl enable fail2ban --now
systemctl restart fail2ban

# ----------------------------
# Удаляем старое правило 22/tcp (после успешного переключения)
# ----------------------------
if ufw status | grep -qE '22/tcp'; then
  print_info "Удаляю устаревшее правило UFW для 22/tcp..."
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
fi

# ----------------------------
# Итоговая информация
# ----------------------------
IP_ADDR="$(hostname -I | awk '{print $1}')"
print_ok "Готово."
print_info "  Пользователь: ${USERNAME}"
print_info "  SSH-порт: ${NEW_PORT}"
print_info "  Подключение: ssh -p ${NEW_PORT} ${USERNAME}@${IP_ADDR}"
