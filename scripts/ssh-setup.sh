#!/usr/bin/env bash
# ssh-setup.sh
# Безопасная настройка SSH: создание пользователя/ключей, смена порта, UFW и fail2ban.
# Флаги:
#   --user <name>            имя пользователя (если не задано — интерактивно)
#   --port <num>             порт SSH (1024-65535)
#   --key-file <path>        путь к публичному ключу (OpenSSH формат)
#   --nopasswd-sudo          выдать пользователю sudo без пароля (повышенный риск)
#   --non-interactive        ошибаться вместо вопросов
#   --port-only              пропустить создание/ключи; сменить только порт. USERNAME обязателен или будет выбран последний созданный.

set -euo pipefail

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
USERNAME="${user:-${username:-${USERNAME:-}}}"
NEW_PORT=""
KEY_FILE=""
NOPASSWD_SUDO=false
NONINTERACTIVE=false
PORT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)            USERNAME="${2:-}"; shift 2;;
    --port)            NEW_PORT="${2:-}"; shift 2;;
    --key-file)        KEY_FILE="${2:-}"; shift 2;;
    --nopasswd-sudo)   NOPASSWD_SUDO=true; shift 1;;
    --non-interactive) NONINTERACTIVE=true; shift 1;;
    --port-only)       PORT_ONLY=true; shift 1;;
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
  ! ss -Htlpn | grep -E "[:\]]${p}\b" >/dev/null 2>&1
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
# Ключи SSH и пользователь
# ----------------------------
# setup_ssh_keys <username?>
# Если <username> не передан:
#   - найдёт "последнего созданного" пользователя (макс. UID >=1000)
#   - предложит: 1) использовать его, 2) создать нового
# Использует глобалы: NONINTERACTIVE, KEY_FILE, NOPASSWD_SUDO
setup_ssh_keys() {
  set -euo pipefail
  umask 077

  _info() { printf "\033[0;34m[INFO]\033[0m %s\n" "$*"; }
  _ok()   { printf "\033[0;32m[OK]\033[0m %s\n"   "$*"; }
  _warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
  _err()  { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }
  _is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]; }

  local user="${1:-${USERNAME:-}}"
  local nonint="${NONINTERACTIVE:-false}"
  local key_file="${KEY_FILE:-}"

  # --- 0) Определяем пользователя ---
  if [[ -z "$user" ]]; then
    local last_user=""
    last_user="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd \
                 | sort -t: -k2,2n | tail -1 | cut -d: -f1)"
    if [[ -n "$last_user" ]]; then
      if [[ "$nonint" == "true" ]]; then
        user="$last_user"
        _info "NONINTERACTIVE: используем последнего созданного пользователя: $user"
      else
        _info "Обнаружен последний созданный пользователь: $last_user"
        echo "  1) Использовать '$last_user'"
        echo "  2) Создать нового"
        local _ch; read -rp "[?] Выберите [1/2]: " _ch
        if [[ "$_ch" == "1" ]]; then
          user="$last_user"
        else
          while :; do
            read -rp "[?] Имя нового пользователя: " user
            _is_valid_username "$user" || { _warn "Недопустимое имя"; continue; }
            if id "$user" &>/dev/null; then
              _warn "Пользователь уже существует — будет использован."
              break
            else
              _info "Создаю пользователя '$user' и добавляю в sudo…"
              adduser --disabled-password --gecos "" "$user"
              usermod -aG sudo "$user"
              break
            fi
          done
        fi
      fi
    else
      # нет ни одного пользователя с UID>=1000
      if [[ "$nonint" == "true" ]]; then
        _err "Нет пользователей с UID>=1000. Укажи --user для создания."
        exit 1
      fi
      while :; do
        read -rp "[?] Имя нового пользователя (будет добавлен в sudo): " user
        _is_valid_username "$user" || { _warn "Недопустимое имя"; continue; }
        if id "$user" &>/dev/null; then
          _warn "Пользователь уже существует — добавляю в sudo (если нужно)."
          id -nG "$user" | grep -qw sudo || usermod -aG sudo "$user"
          break
        else
          adduser --disabled-password --gecos "" "$user"
          usermod -aG sudo "$user"
          break
        fi
      done
    fi
  else
    # user передан явно — создать при необходимости
    if ! id "$user" &>/dev/null; then
      if [[ "$nonint" == "true" ]]; then
        _err "Пользователь '$user' не найден (NONINTERACTIVE)."
        exit 1
      fi
      _info "Создаю пользователя '$user' и добавляю в sudo…"
      adduser --disabled-password --gecos "" "$user"
      usermod -aG sudo "$user"
    fi
  fi

  # выдача sudo NOPASSWD по флагу
  if [[ "${NOPASSWD_SUDO:-false}" == "true" ]]; then
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
  else
    echo "$user ALL=(ALL) ALL" > "/etc/sudoers.d/$user"
  fi
  chmod 440 "/etc/sudoers.d/$user"

  # убедиться, что в sudo
  id -nG "$user" | grep -qw sudo || usermod -aG sudo "$user"

  # --- 1) ~/.ssh и authorized_keys ---
  local home_dir; home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -d "$home_dir" ]] || { _err "Домашний каталог не найден: $home_dir"; exit 1; }

  mkdir -p "$home_dir/.ssh"; chmod 700 "$home_dir/.ssh"; chown "$user:$user" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"; chmod 600 "$home_dir/.ssh/authorized_keys"; chown "$user:$user" "$home_dir/.ssh/authorized_keys"

  # --- 2) Источники ключей ---
  local ROOT_AUTH="/root/.ssh/authorized_keys"
  local root_has=false
  local src=""
  if [[ -s "$ROOT_AUTH" ]]; then
    src="$(cat "$ROOT_AUTH")"; root_has=true; _info "Найдены ключи в $ROOT_AUTH"
  fi
  if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
    local pubs; pubs="$(cat /root/.ssh/*.pub 2>/dev/null || true)"
    [[ -n "$pubs" ]] && { src="${src:+$src$'\n'}$pubs"; root_has=true; _info "Найдены /root/.ssh/*.pub"; }
  fi

  # --- 3) Выбор сценария ---
  local choice=""
  if [[ "$root_has" == true ]]; then
    if [[ -n "${key_file}" && -r "${key_file}" ]]; then
      choice="2"
    elif [[ "$nonint" == "true" ]]; then
      choice="1"
    else
      echo "Выберите действие:"
      echo "  1) Перенести ключи root пользователю $user"
      echo "  2) Вставить/передать свой публичный ключ(и)"
      echo "  3) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2/3]: " choice
    fi
  else
    if [[ -n "${key_file}" && -r "${key_file}" ]]; then
      choice="2"
    elif [[ "$nonint" == "true" ]]; then
      _err "У root ключей нет, KEY_FILE не задан (NONINTERACTIVE)."
      exit 1
    else
      echo "Ключей у root не найдено. Выберите:"
      echo "  1) Вставить/передать свой публичный ключ(и)"
      echo "  2) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2]: " choice
      [[ "$choice" == "2" ]] && choice="3"
    fi
  fi

  # --- 4) Выполняем сценарий ---
  case "$choice" in
    1) [[ -n "$src" ]] || { _err "Нет ключей у root для переноса"; exit 1; } ;;
    2)
      if [[ -n "${key_file}" ]]; then
        [[ -r "${key_file}" ]] || { _err "Файл ключа недоступен: ${key_file}"; exit 1; }
        src="$(cat "${key_file}")"; _info "Ключи взяты из файла: ${key_file}"
      else
        _info "Вставьте PUBLIC ключи (OpenSSH), по одному в строке. Завершите ввод Ctrl+D."
        echo "---"
        local buf=""; while IFS= read -r line || [[ -n "$line" ]]; do buf+="${line}"$'\n'; done
        src="${buf%$'\n'}"
      fi
      ;;
    3)
      _info "Генерирую ed25519 ключ для $user…"
      su - "$user" -c "ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/id_ed25519 >/dev/null"
      src="$(cat "$home_dir/.ssh/id_ed25519.pub")"
      _ok "Сгенерирован ключ: $home_dir/.ssh/id_ed25519 (приватный)"
      ;;
    *) _err "Некорректный выбор."; exit 1;;
  esac

  [[ -n "$src" ]] || { _err "Ключи не получены."; exit 1; }

  # --- 5) Записываем authorized_keys безопасно (tmp + mv), фильтруем и дедуп ---
  local tmp; tmp="$(mktemp)"
  ( cat "$home_dir/.ssh/authorized_keys" 2>/dev/null || true ) >"$tmp"

  local added=0 line
  src="$(printf "%s" "$src" | tr -d '\r')"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then
      if ! grep -qxF "$line" "$tmp" 2>/dev/null; then
        printf "%s\n" "$line" >>"$tmp"
        ((added++))
      fi
    else
      _warn "Пропущена строка (не похожа на SSH-ключ): ${line:0:50}..."
    fi
  done <<< "$src"

  chown "$user:$user" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$home_dir/.ssh/authorized_keys"

  _ok "Добавлено ключей: $added"
  _info "Всего ключей у $user: $(grep -c '^\(ssh-\|ecdsa-\|sk-\)' "$home_dir/.ssh/authorized_keys" 2>/dev/null || echo 0)"

  # --- 6) Чистим ключи у root (с бэкапом) ---
  if [[ -f "$ROOT_AUTH" ]]; then
    local ts backup; ts="$(date +%Y%m%d-%H%M%S)"; backup="/root/authorized_keys.root.backup.$ts"
    cp -a "$ROOT_AUTH" "$backup" || true
    : > "$ROOT_AUTH"; chmod 600 "$ROOT_AUTH"; chown root:root "$ROOT_AUTH"
    _ok "Ключи у root очищены. Бэкап: $backup"
  fi

  # Вернём выбранное имя наверх
  USERNAME="$user"
  export USERNAME
  _ok "Готово. Пользователь: $user"
}

# если не --port-only: выполним настройку пользователя и ключей
if ! $PORT_ONLY; then
  setup_ssh_keys "${USERNAME:-}"
else
  # --port-only: нужен существующий пользователь для AllowUsers
  if [[ -z "${USERNAME:-}" ]]; then
    USERNAME="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd | sort -t: -k2,2n | tail -1 | cut -d: -f1)"
  fi
  if [[ -z "${USERNAME:-}" || -z "$(id -u "$USERNAME" 2>/dev/null)" ]]; then
    print_err "Нужен существующий пользователь ( --user ). Запустите без --port-only для создания/настройки ключей."
    exit 1
  fi
fi

# ----------------------------
# Выбор/проверка порта
# ----------------------------
if [[ -z "$NEW_PORT" ]]; then
  if $NONINTERACTIVE; then
    print_err "Требуется --port в неинтерактивном режиме"
    exit 1
  fi
  while true; do
    read -r -p "Введите новый порт SSH (1024-65535): " NEW_PORT
    if is_valid_port "$NEW_PORT" && port_is_free "$NEW_PORT"; then break; fi
    print_err "Порт недопустим или занят"
  done
else
  is_valid_port "$NEW_PORT" || { print_err "Недопустимый порт: $NEW_PORT"; exit 1; }
  port_is_free "$NEW_PORT" || { print_err "Порт уже занят: $NEW_PORT"; exit 1; }
fi

# ----------------------------
# UFW — безопасная последовательность
# ----------------------------
print_info "Настройка UFW (брандмауэр)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp || true
ufw allow "${NEW_PORT}/tcp"
ufw limit "${NEW_PORT}/tcp" || true
ufw --force enable

# ----------------------------
# OpenSSH: drop-in конфиг
# ----------------------------
print_info "Применение безопасных настроек SSH..."
install -d -m 0755 /etc/ssh/sshd_config.d

# На случай, если в основном файле явно задан Port — закомментируем (чтобы drop-in имел приоритет)
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
systemctl restart fail2ban || true

# ----------------------------
# Подтверждение перед закрытием 22/tcp
# ----------------------------
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
print_info "Проверьте вход с другой сессии (не разрывая текущую):"
echo "  ssh -p ${NEW_PORT} ${USERNAME}@${SERVER_IP:-<IP-сервера>}"

if $NONINTERACTIVE; then
  print_warn "NONINTERACTIVE: порт 22/tcp оставлен открытым. Закройте вручную после проверки: ufw delete allow 22/tcp"
else
  while :; do
    read -rp "[?] Удалось войти по ключу и новому порту? Напишите YES чтобы закрыть 22/tcp, NO — оставить: " ok
    case "${ok^^}" in
      YES) ufw delete allow 22/tcp >/dev/null 2>&1 || true; print_ok "Порт 22/tcp закрыт."; break;;
      NO)  print_warn "Оставляю 22/tcp открытым. Закройте позже: ufw delete allow 22/tcp"; break;;
      *)   echo "Введите YES или NO.";;
    esac
  done
fi

# ----------------------------
# Итоговая информация
# ----------------------------
IP_ADDR="$(hostname -I | awk '{print $1}')"
print_ok "Готово."
print_info "  Пользователь: ${USERNAME}"
print_info "  SSH-порт: ${NEW_PORT}"
print_info "  Подключение: ssh -p ${NEW_PORT} ${USERNAME}@${IP_ADDR}"
