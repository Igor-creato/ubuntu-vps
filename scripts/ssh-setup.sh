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
  local user="$1"
  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  
  # Проверяем, что домашний каталог существует
  if [[ ! -d "$home_dir" ]]; then
    print_err "Домашний каталог $home_dir не найден для пользователя $user"
    return 1
  fi
  
  # Создаем ~/.ssh и authorized_keys с корректными правами
  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  : > "$home_dir/.ssh/authorized_keys"
  chown "$user:$user" "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  
  # Собираем исходные ключи из всех возможных источников
  local src_content=""
  local found_keys=false
  
  # Проверяем authorized_keys у root
  if [[ -s /root/.ssh/authorized_keys ]]; then
    src_content="$(cat /root/.ssh/authorized_keys)"
    found_keys=true
    print_info "Найдены ключи в /root/.ssh/authorized_keys"
  fi
  
  # Проверяем публичные ключи у root
  if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
    local pub_content
    pub_content="$(cat /root/.ssh/*.pub 2>/dev/null)"
    if [[ -n "$pub_content" ]]; then
      if [[ -n "$src_content" ]]; then
        src_content="${src_content}"$'\n'"${pub_content}"
      else
        src_content="$pub_content"
      fi
      found_keys=true
      print_info "Найдены публичные ключи в /root/.ssh/*.pub"
    fi
  fi
  
  # Если ключей у root нет — предложить 2 варианта
  if [[ "$found_keys" == false ]]; then
    if ${NONINTERACTIVE:-false}; then
      print_err "Ключи не найдены у root. Укажите --key-file в неинтерактивном режиме."
      return 1
    fi
    
    echo
    print_info "Ключи у root не найдены. Выберите вариант:"
    echo "  1) Ввести свои публичные ключи (многострочный ввод, завершить Ctrl+D)"
    echo "  2) Сгенерировать новый ed25519 ключ"
    echo
    
    while true; do
      read -r -p "Ваш выбор (1/2): " ch
      case "$ch" in
        1)
          echo
          print_info "Вставьте PUBLIC ключи (OpenSSH формат):"
          print_info "Можно вставить несколько ключей, каждый на новой строке"
          print_info "Завершите ввод нажатием Ctrl+D"
          echo "---"
          
          # Читаем многострочный ввод до EOF (Ctrl+D)
          local user_input=""
          while IFS= read -r line || [[ -n "$line" ]]; do
            user_input="${user_input}${line}"$'\n'
          done
          
          # Убираем последний перенос строки если он есть
          user_input="${user_input%$'\n'}"
          
          if [[ -n "$user_input" ]]; then
            src_content="$user_input"
            print_ok "Получено $(echo "$user_input" | wc -l) строк(и) с ключами"
            break
          else
            print_err "Пустой ввод. Попробуйте снова."
          fi
          ;;
        2)
          # Создаем каталог .ssh у root если его нет
          install -d -m 700 -o root -g root /root/.ssh
          
          local key_name="${user}_ed25519"
          local key_path="/root/.ssh/${key_name}"
          
          print_info "Генерируем ed25519 ключ..."
          if ssh-keygen -t ed25519 -f "$key_path" -N "" -C "${user}@$(hostname)" >/dev/null 2>&1; then
            src_content="$(cat "${key_path}.pub")"
            print_ok "Ключ сгенерирован успешно!"
            print_info "Приватный ключ: ${key_path}"
            print_info "Публичный ключ: ${key_path}.pub"
            break
          else
            print_err "Ошибка генерации ключа. Попробуйте вариант 1."
          fi
          ;;
        *)
          print_err "Введите 1 или 2."
          ;;
      esac
    done
  fi
  
  # Проверяем, что у нас есть содержимое для добавления
  if [[ -z "$src_content" ]]; then
    print_err "Нет ключей для установки"
    return 1
  fi
  
  # Добавляем все строки-ключи без дублей
  local tmpfile
  tmpfile="$(mktemp)"
  
  # Копируем существующие ключи
  if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
    cp -f "$home_dir/.ssh/authorized_keys" "$tmpfile"
  fi
  
  # Добавляем новые ключи, проверяя на дубликаты
  local added_count=0
  while IFS= read -r line; do
    # Пропускаем пустые строки и комментарии
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Убираем лишние пробелы
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    
    # Проверяем, что это похоже на SSH ключ
    if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then
      # Проверяем на дубликаты
      if ! grep -qxF "$line" "$tmpfile" 2>/dev/null; then
        echo "$line" >> "$tmpfile"
        ((added_count++))
      fi
    else
      print_err "Пропускаем строку (не SSH ключ): ${line:0:50}..."
    fi
  done <<< "$src_content"
  
  # Устанавливаем файл с правильными правами
  install -m 600 -o "$user" -g "$user" "$tmpfile" "$home_dir/.ssh/authorized_keys"
  rm -f "$tmpfile"
  
  if [[ "$added_count" -gt 0 ]]; then
    print_ok "Добавлено $added_count публичный(х) ключ(ей) пользователю $user"
  else
    print_info "Новые ключи не добавлены (возможно, уже существуют)"
  fi
  
  # Показываем финальный статус
  local total_keys
  total_keys="$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$home_dir/.ssh/authorized_keys" 2>/dev/null || echo 0)"
  print_info "Всего ключей у пользователя $user: $total_keys"
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
