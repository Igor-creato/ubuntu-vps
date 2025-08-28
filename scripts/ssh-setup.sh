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
# setup_ssh_keys <username?>
# Если <username> не передан: предложит выбрать существующего sudo-пользователя или создать нового.
# Использует глобалы (если есть): NONINTERACTIVE (true/false), KEY_FILE (/путь/к/.pub)
setup_ssh_keys() {
  set -euo pipefail
  umask 077

  # --- утилиты ---
  _info() { printf "\033[0;34m[INFO]\033[0m %s\n" "$*"; }
  _ok()   { printf "\033[0;32m[OK]\033[0m %s\n"   "$*"; }
  _warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
  _err()  { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }
  _need() { command -v "$1" >/dev/null 2>&1 || { _err "Требуется команда: $1"; exit 1; }; }
  _is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]; }

  _need getent
  _need install
  _need ssh-keygen

  local user="${1:-}"
  local nonint="${NONINTERACTIVE:-false}"
  local key_file="${KEY_FILE:-}"

  # --- 0) выбрать sudo-пользователя или создать нового, если user пуст ---
  if [[ -z "$user" ]]; then
    # Список sudo, без root
    mapfile -t _sudo_users < <(getent group sudo | awk -F: '{print $4}' | tr ',' '\n' | sed '/^$/d;/^root$/d' | sort -u || true)

    if ((${#_sudo_users[@]} > 0)); then
      if [[ "$nonint" == "true" ]]; then
        # В неинтерактивном режиме — ошибка, если user не задан явно
        _err "NONINTERACTIVE=true: укажите --user для выбора существующего sudo-пользователя"
        exit 1
      fi
      _info "Найдены sudo-пользователи: ${_sudo_users[*]}"
      echo "  1) Использовать существующего"
      echo "  2) Создать нового"
      read -rp "[?] Выберите [1/2]: " _ch
      if [[ "$_ch" == "1" ]]; then
        PS3="[?] Кого использовать: "
        select sel in "${_sudo_users[@]}"; do
          [[ -n "$sel" ]] && user="$sel" && break
        done
      else
        while :; do
          read -rp "[?] Имя нового пользователя: " user
          _is_valid_username "$user" || { _warn "Недопустимое имя"; continue; }
          if id "$user" &>/dev/null; then
            _warn "Пользователь уже существует — будет использован как есть."
            break
          fi
          _info "Создаю пользователя $user и добавляю в sudo…"
          adduser --disabled-password --gecos "" "$user"
          usermod -aG sudo "$user"
          break
        done
      fi
    else
      # sudo-пользователей нет — придётся создать
      if [[ "$nonint" == "true" ]]; then
        _err "NONINTERACTIVE=true: укажите --user для создания sudo-пользователя"
        exit 1
      fi
      while :; do
        read -rp "[?] Имя нового пользователя (будет добавлен в sudo): " user
        _is_valid_username "$user" || { _warn "Недопустимое имя"; continue; }
        if id "$user" &>/dev/null; then
          _warn "Пользователь уже существует — добавляю в sudo (если ещё не там)."
          usermod -aG sudo "$user" || true
          break
        else
          adduser --disabled-password --gecos "" "$user"
          usermod -aG sudo "$user"
          break
        fi
      done
    fi
  else
    # user передан: убедимся, что существует и (опционально) в sudo
    if ! id "$user" &>/dev/null; then
      if [[ "$nonint" == "true" ]]; then
        _err "Пользователь '$user' не найден (NONINTERACTIVE)."
        exit 1
      fi
      _info "Создаю пользователя $user и добавляю в sudo…"
      adduser --disabled-password --gecos "" "$user"
      usermod -aG sudo "$user"
    else
      # Если не в sudo — предложим добавить
      if ! id -nG "$user" | grep -qw sudo; then
        if [[ "$nonint" == "true" ]]; then
          _warn "Пользователь '$user' не в группе sudo (NONINTERACTIVE) — пропускаю добавление."
        else
          read -rp "[?] Пользователь '$user' не в sudo. Добавить? [y/N]: " yn
          [[ "${yn,,}" == "y" ]] && usermod -aG sudo "$user"
        fi
      fi
    end
  fi

  # --- 1) подготовить ~/.ssh и authorized_keys ---
  local home_dir
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -d "$home_dir" ]] || { _err "Домашний каталог не найден: $home_dir"; exit 1; }

  install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
  install -m 600 -o "$user" -g "$user" /dev/null "$home_dir/.ssh/authorized_keys"

  # --- 2) есть ли ключи у root? ---
  local ROOT_AUTH="/root/.ssh/authorized_keys"
  local root_has=false
  local src=""
  if [[ -s "$ROOT_AUTH" ]]; then
    src="$(cat "$ROOT_AUTH")"
    root_has=true
    _info "Найдены ключи в $ROOT_AUTH"
  fi
  if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
    local pubs
    pubs="$(cat /root/.ssh/*.pub 2>/dev/null || true)"
    if [[ -n "$pubs" ]]; then
      src="${src:+$src"$'\n'"}$pubs"
      root_has=true
      _info "Найдены публичные ключи в /root/.ssh/*.pub"
    fi
  fi

  # --- 3) выбор сценария ---
  local choice=""
  if [[ "$root_has" == true ]]; then
    if [[ -n "$key_file" && -r "$key_file" ]]; then
      choice="2" # принудительно: используем свой файл
    elif [[ "$nonint" == "true" ]]; then
      choice="1" # перенос (тихий режим)
    else
      echo "Выберите действие:"
      echo "  1) Перенести ключи root пользователю $user"
      echo "  2) Вставить/передать свой публичный ключ(и)"
      echo "  3) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2/3]: " choice
    fi
  else
    if [[ -n "$key_file" && -r "$key_file" ]]; then
      choice="2"
    elif [[ "$nonint" == "true" ]]; then
      _err "У root ключей нет, а KEY_FILE не задан (NONINTERACTIVE)."
      exit 1
    else
      echo "Ключей у root не найдено. Выберите:"
      echo "  1) Вставить/передать свой публичный ключ(и)"
      echo "  2) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2]: " choice
      [[ "$choice" == "2" ]] && choice="3"
    fi
  fi

  # --- 4) выполнить выбранный вариант и собрать ключи в authorized_keys ---
  case "$choice" in
    1)
      # перенос от root
      [[ -n "$src" ]] || { _err "Нет ключей у root для переноса"; exit 1; }
      ;;
    2)
      # собственные ключи (из файла или ввод)
      if [[ -n "$key_file" ]]; then
        [[ -r "$key_file" ]] || { _err "Файл ключа недоступен: $key_file"; exit 1; }
        src="$(cat "$key_file")"
        _info "Ключи взяты из файла: $key_file"
      else
        _info "Вставьте PUBLIC ключи (OpenSSH), по одному в строке."
        _info "Завершите ввод Ctrl+D (EOF)."
        echo "---"
        local buf=""
        while IFS= read -r line || [[ -n "$line" ]]; do
          buf+="${line}"$'\n'
        done
        src="${buf%$'\n'}"
      fi
      ;;
    3)
      # генерация новой пары ключей для пользователя
      _info "Генерирую ed25519 ключ для $user…"
      su - "$user" -c "ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/id_ed25519 >/dev/null"
      src="$(cat "$home_dir/.ssh/id_ed25519.pub")"
      _ok "Сгенерирован ключ: $home_dir/.ssh/id_ed25519 (приватный)"
      ;;
    *)
      _err "Некорректный выбор."
      exit 1
      ;;
  esac

  # Проверка содержимого
  if [[ -z "$src" ]]; then
    _err "Ключи не получены."
    exit 1
  fi

  # Фильтр строк: только допустимые ключи, без дублей
  local tmp
  tmp="$(mktemp)"
  # старт — существующие (если были)
  cat "$home_dir/.ssh/authorized_keys" 2>/dev/null || true >"$tmp"
  # добавим новые (валидные)
  local added=0
  while IFS= read -r l; do
    # убираем лишние пробелы
    l="$(echo "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$l" || "$l" =~ ^# ]] && continue
    if [[ "$l" =~ ^(ssh-|ecdsa-|sk-) ]]; then
      if ! grep -qxF "$l" "$tmp" 2>/dev/null; then
        echo "$l" >>"$tmp"
        ((added++))
      fi
    else
      _warn "Пропущена строка (не похожа на SSH-ключ): ${l:0:50}..."
    fi
  done <<< "$src"

  install -m 600 -o "$user" -g "$user" "$tmp" "$home_dir/.ssh/authorized_keys"
  rm -f "$tmp"
  _ok "Добавлено ключей: $added"
  _info "Всего ключей у $user: $(grep -c '^\(ssh-\|ecdsa-\|sk-\)' "$home_dir/.ssh/authorized_keys" 2>/dev/null || echo 0)"

  # --- 5) удалить ключи у root (с бэкапом authorized_keys) ---
  if [[ -f "$ROOT_AUTH" ]]; then
    local ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="/root/authorized_keys.root.backup.$ts"
    cp -a "$ROOT_AUTH" "$backup" || true
    : > "$ROOT_AUTH"
    chmod 600 "$ROOT_AUTH"
    chown root:root "$ROOT_AUTH"
    _ok "Ключи у root очищены. Бэкап: $backup"
  fi

  _ok "Готово. Пользователь: $user"
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
