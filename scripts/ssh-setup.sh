#!/usr/bin/env bash
# ssh-setup.sh — безопасная настройка SSH: пользователь/ключи, смена порта, UFW и fail2ban.
# Флаги:
#   --user <name>            имя пользователя (если не задано — интерактивно)
#   --port <num>             порт SSH (1024-65535)
#   --key-file <path>        путь к публичному ключу (OpenSSH формат)
#   --nopasswd-sudo          дать sudo без пароля (повышенный риск)
#   --non-interactive        ошибаться вместо вопросов
#   --port-only              пропустить создание/ключи; сменить только порт (USERNAME обязателен или будет выбран последний созданный).

set -Eeuo pipefail
shopt -s extglob

# -------- Логгеры --------
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
print_ok()   { printf "${GREEN}[OK]${NC} %s\n"   "$*"; }
print_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
print_err()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

trap 'print_err "Ошибка на строке $LINENO"; [[ "${DEBUG:-0}" = 1 ]] && set +x; exit 1' ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || { print_err "Запустите скрипт от root: sudo $0 ..."; exit 1; }
[[ "${DEBUG:-0}" = 1 ]] && set -x

# -------- Аргументы --------
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

# -------- Валидации --------
is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]; }
is_valid_port()     { local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1024 && p<=65535 )); }
port_is_free()      { local p="$1"; ! ss -Htlpn | grep -E "[:\]]${p}\b" >/dev/null 2>&1; }  # ss см. мануал

# -------- Пакеты --------
export DEBIAN_FRONTEND=noninteractive
print_info "Обновление пакетов и установка зависимостей..."
apt-get update -y
apt-get install -y openssh-server ufw fail2ban
dpkg --configure -a || true
apt-get -y --fix-broken install || true
apt-get -y upgrade
apt-get -y dist-upgrade || true
apt-get -y autoremove --purge
apt-get -y autoclean
systemctl enable ssh --now

# -------- Функция: пользователь + ключи --------
# setup_ssh_keys <username?>
# Если имя не передано:
#   - берёт «последнего созданного» пользователя (макс. UID >=1000) и предлагает 1) использовать его, 2) создать нового.
# Умеет: перенос ключей из root, многострочный ввод, генерация ed25519; чистит ключи у root (с бэкапом).
setup_ssh_keys() {
  set -Eeuo pipefail
  umask 077

  local user="${1:-${USERNAME:-}}"
  local key_file="${KEY_FILE:-}"

  # --- выбор/создание пользователя ---
  if [[ -z "$user" ]]; then
    local last_user
    last_user="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd | sort -t: -k2,2n | tail -1 | cut -d: -f1)"
    if [[ -n "$last_user" ]]; then
      if $NONINTERACTIVE; then
        user="$last_user"; print_info "NONINTERACTIVE: Использую последнего созданного пользователя: $user"
      else
        print_info "Найден последний созданный пользователь: $last_user"
        echo "  1) Использовать '$last_user'"
        echo "  2) Создать нового"
        local _ch; read -rp "[?] Выберите [1/2]: " _ch
        if [[ "$_ch" == "1" ]]; then
          user="$last_user"
        else
          while :; do
            read -rp "[?] Имя нового пользователя: " user
            is_valid_username "$user" || { print_warn "Недопустимое имя"; continue; }
            if id "$user" &>/dev/null; then
              print_warn "Пользователь уже существует — будет использован."
              break
            else
              print_info "Создаю пользователя '$user' и добавляю в sudo…"
              adduser --disabled-password --gecos "" "$user"
              usermod -aG sudo "$user"
              break
            fi
          done
        fi
      fi
    else
      # нет обычных пользователей — создаём
      $NONINTERACTIVE && { print_err "Нет пользователей с UID>=1000. Укажи --user для создания."; exit 1; }
      while :; do
        read -rp "[?] Имя нового пользователя (будет добавлен в sudo): " user
        is_valid_username "$user" || { print_warn "Недопустимое имя"; continue; }
        if id "$user" &>/dev/null; then
          print_warn "Пользователь уже существует — добавляю в sudo (если нужно)."
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
    # имя передано — создать при необходимости
    if ! id "$user" &>/dev/null; then
      $NONINTERACTIVE && { print_err "Пользователь '$user' не найден (NONINTERACTIVE)."; exit 1; }
      print_info "Создаю пользователя '$user' и добавляю в sudo…"
      adduser --disabled-password --gecos "" "$user"
      usermod -aG sudo "$user"
    fi
  fi

  # sudoers (по флагу NOPASSWD_SUDO)
  if $NOPASSWD_SUDO; then
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
  else
    echo "$user ALL=(ALL) ALL" > "/etc/sudoers.d/$user"
  fi
  chmod 440 "/etc/sudoers.d/$user"
  id -nG "$user" | grep -qw sudo || usermod -aG sudo "$user"

  # --- ~/.ssh/authorized_keys ---
  local home_dir; home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -d "$home_dir" ]] || { print_err "Домашний каталог не найден: $home_dir"; exit 1; }
  mkdir -p "$home_dir/.ssh"; chmod 700 "$home_dir/.ssh"; chown "$user:$user" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"; chmod 600 "$home_dir/.ssh/authorized_keys"; chown "$user:$user" "$home_dir/.ssh/authorized_keys"

  # --- Собираем ключи из root, если есть ---
  local ROOT_AUTH="/root/.ssh/authorized_keys"
  local have_root=false
  [[ -s "$ROOT_AUTH" ]] && { print_info "Найдены ключи в $ROOT_AUTH"; have_root=true; }
  compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1 && { print_info "Найдены /root/.ssh/*.pub"; have_root=true; }

  # --- Выбор сценария ---
  local choice=""
  if $have_root; then
    if [[ -n "$key_file" && -r "$key_file" ]]; then
      choice="2"
    elif $NONINTERACTIVE; then
      choice="1"
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
    elif $NONINTERACTIVE; then
      print_err "У root ключей нет, а KEY_FILE не задан (NONINTERACTIVE)."; exit 1
    else
      echo "Ключей у root не найдено. Выберите:"
      echo "  1) Вставить/передать свой публичный ключ(и)"
      echo "  2) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2]: " choice
      [[ "$choice" == "2" ]] && choice="3"
    fi
  fi

  # --- Готовим временный файл и добавляем ключи согласно выбору ---
  local tmp; tmp="$(mktemp)"
  # старт: существующие ключи пользователя
  ( cat "$home_dir/.ssh/authorized_keys" 2>/dev/null || true ) >"$tmp"

  add_lines() {
    # Функция: прочитать STDIN, отфильтровать валидные ключи и добавить в "$tmp" без дублей
    local line added_local=0
    while IFS= read -r line; do
      line="${line//$'\r'/}"                       # убрать CR
      line="${line#"${line%%[![:space:]]*}"}"     # ltrim
      line="${line%"${line##*[![:space:]]}"}"     # rtrim
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] || { print_warn "Строка не похожа на SSH-ключ: ${line:0:50}..."; continue; }
      if ! grep -qxF "$line" "$tmp" 2>/dev/null; then
        printf "%s\n" "$line" >>"$tmp"; ((added_local++))
      fi
    done
    echo "$added_local"
  }

  local added=0
  case "$choice" in
    1)
      # Перенос напрямую из /root/.ssh/*
      if [[ -s "$ROOT_AUTH" ]]; then
        count="$(add_lines < "$ROOT_AUTH")"; ((added+=count))
      fi
      if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
        count="$(cat /root/.ssh/*.pub 2>/dev/null | add_lines)"; ((added+=count))
      fi
      ;;
    2)
      if [[ -n "$key_file" ]]; then
        [[ -r "$key_file" ]] || { print_err "Файл ключа недоступен: $key_file"; exit 1; }
        count="$(add_lines < "$key_file")"; ((added+=count))
      else
        print_info "Вставьте PUBLIC ключи (OpenSSH), по одному в строке. Завершите ввод Ctrl+D."
        echo "---"
        count="$(add_lines)"; ((added+=count))
      fi
      ;;
    3)
      print_info "Генерирую ed25519 ключ для $user…"
      su - "$user" -c "ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/id_ed25519 >/dev/null"
      count="$(add_lines < "$home_dir/.ssh/id_ed25519.pub")"; ((added+=count))
      ;;
    *)
      print_err "Некорректный выбор."; exit 1;;
  esac

  # Атомарная замена authorized_keys
  chown "$user:$user" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$home_dir/.ssh/authorized_keys"

  print_ok "Добавлено ключей: $added"
  print_info "Всего ключей у $user: $(grep -c '^\(ssh-\|ecdsa-\|sk-\)' "$home_dir/.ssh/authorized_keys" 2>/dev/null || echo 0)"

  # Очистка ключей у root (с бэкапом)
  local ROOT_AUTH="/root/.ssh/authorized_keys"
  if [[ -f "$ROOT_AUTH" ]]; then
    local ts backup; ts="$(date +%Y%m%d-%H%M%S)"; backup="/root/authorized_keys.root.backup.$ts"
    cp -a "$ROOT_AUTH" "$backup" || true
    : > "$ROOT_AUTH"; chmod 600 "$ROOT_AUTH"; chown root:root "$ROOT_AUTH"
    print_ok "Ключи у root очищены. Бэкап: $backup"
  fi

  # вернём имя в глобал
  USERNAME="$user"; export USERNAME
  print_ok "Готово. Пользователь: $user"
}

# ---- Запуск функции (если не --port-only) ----
if ! $PORT_ONLY; then
  setup_ssh_keys "${USERNAME:-}"
else
  # --port-only: нужен существующий пользователь (для AllowUsers)
  if [[ -z "${USERNAME:-}" ]]; then
    USERNAME="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd | sort -t: -k2,2n | tail -1 | cut -d: -f1)"
  fi
  [[ -n "${USERNAME:-}" && -n "$(id -u "$USERNAME" 2>/dev/null || echo)" ]] || { print_err "Нужен существующий пользователь (--user)."; exit 1; }
fi

# -------- Порт SSH --------
if [[ -z "$NEW_PORT" ]]; then
  if $NONINTERACTIVE; then print_err "Требуется --port в NONINTERACTIVE"; exit 1; fi
  while :; do
    read -r -p "Введите новый порт SSH (1024-65535): " NEW_PO_
