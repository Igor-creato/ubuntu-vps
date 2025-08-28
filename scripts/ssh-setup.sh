#!/usr/bin/env bash
# ssh-setup.sh — безопасная настройка SSH: пользователь/ключи, смена порта, UFW и fail2ban.
# Флаги:
#   --user <name>            имя пользователя (если не задано — интерактивно)
#   --port <num>             порт SSH (1024-65535)
#   --key-file <path>        путь к публичному ключу (OpenSSH формат)
#   --nopasswd-sudo          дать sudo без пароля (повышенный риск)
#   --non-interactive        ошибаться вместо вопросов
#   --port-only              пропустить создание/ключи; сменить только порт (USERNAME обязателен или берётся последний созданный)

set -Eeuo pipefail
shopt -s extglob

# ---------- Цвета/логгеры ----------
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
print_ok()   { printf "${GREEN}[OK]${NC} %s\n"   "$*"; }
print_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
print_err()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

trap 'print_err "Ошибка на строке $LINENO"; exit 1' ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || { print_err "Запустите скрипт от root: sudo $0 ..."; exit 1; }
[[ "${DEBUG:-0}" = 1 ]] && set -x

# ---------- Аргументы ----------
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
    --nopasswd-sudo)   NOPASSWD_SUDO=true; shift;;
    --non-interactive) NONINTERACTIVE=true; shift;;
    --port-only)       PORT_ONLY=true; shift;;
    *) print_err "Неизвестный аргумент: $1"; exit 1;;
  esac
done

# ---------- Вспомогательные ----------
is_valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]; }
is_valid_port()     { local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1024 && p<=65535 )); }
port_is_free()      { local p="$1"; if command -v ss >/dev/null 2>&1; then ! ss -Htlpn 2>/dev/null | grep -E "[:\]]${p}\b" >/dev/null; else true; fi; }

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
    print_ok "Резервная копия создана: ${f}.bak.${ts}"
  fi
}

set_sshd_opt() {
  local key="$1" val="$2" file="/etc/ssh/sshd_config"
  if grep -Eiq "^\s*#?\s*${key}\b" "$file"; then
    sed -ri "s|^\s*#?\s*${key}\b.*|${key} ${val}|I" "$file"
  else
    printf "\n%s %s\n" "$key" "$val" >>"$file"
  fi
}

append_allow_user() {
  local user="$1" file="/etc/ssh/sshd_config"
  if grep -Eiq '^\s*AllowUsers\b' "$file"; then
    if ! grep -Eq "^\s*AllowUsers\b.*\b${user}\b" "$file"; then
      sed -ri "s|^\s*AllowUsers\b(.*)|AllowUsers\1 ${user}|I" "$file"
    fi
  else
    printf "\nAllowUsers %s\n" "$user" >>"$file"
  fi
}

current_ssh_port() {
  local file="/etc/ssh/sshd_config" p=""
  p="$(awk 'tolower($1)=="port"{print $2}' "$file" 2>/dev/null | tail -1 || true)"
  [[ -n "$p" ]] && { echo "$p"; return; }
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [[ -n "$p" ]] && { echo "$p"; return; }
  fi
  echo 22
}

ensure_dirs() { install -d -m 0755 /run/sshd; }

# ---------- Пакеты/сервисы ----------
export DEBIAN_FRONTEND=noninteractive
print_info "Обновление пакетов и установка зависимостей..."
apt-get update -y
apt-get install -y openssh-server ufw fail2ban sudo
dpkg --configure -a || true
apt-get -y --fix-broken install || true
apt-get -y upgrade
apt-get -y autoremove --purge
apt-get -y autoclean

systemctl enable ssh --now
ensure_dirs

# ---------- Пользователь и ключи ----------
setup_ssh_keys() {
  set -Eeuo pipefail
  umask 077
  local user="${1:-${USERNAME:-}}"
  local key_file="${KEY_FILE:-}"

  # -- выбор/создание пользователя --
  if [[ -z "$user" ]]; then
    local last_user
    last_user="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd | sort -t: -k2,2n | tail -1 | cut -d: -f1 || true)"
    if [[ -n "$last_user" ]]; then
      if $NONINTERACTIVE; then
        user="$last_user"; print_info "NONINTERACTIVE: использую пользователя: $user"
      else
        print_info "Найден пользователь: $last_user"
        echo "  1) Использовать '$last_user'"
        echo "  2) Создать нового"
        local c; read -rp "[?] Выберите [1/2]: " c
        if [[ "$c" == "1" ]]; then
          user="$last_user"
        else
          while :; do
            read -rp "[?] Имя нового пользователя: " user
            is_valid_username "$user" || { print_warn "Недопустимое имя"; continue; }
            if id "$user" &>/dev/null; then
              print_warn "Пользователь уже существует, будет использован."
              break
            else
              adduser --disabled-password --gecos "" "$user"
              usermod -aG sudo "$user"
              break
            fi
          done
        fi
      fi
    else
      $NONINTERACTIVE && { print_err "Нет пользователей с UID>=1000. Укажите --user."; exit 1; }
      while :; do
        read -rp "[?] Имя нового пользователя (будет добавлен в sudo): " user
        is_valid_username "$user" || { print_warn "Недопустимое имя"; continue; }
        if id "$user" &>/dev/null; then
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
    if ! id "$user" &>/dev/null; then
      $NONINTERACTIVE && { print_err "Пользователь '$user' не найден (NONINTERACTIVE)."; exit 1; }
      adduser --disabled-password --gecos "" "$user"
      usermod -aG sudo "$user"
    fi
  fi

  # sudoers
  if $NOPASSWD_SUDO; then
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
  else
    echo "$user ALL=(ALL) ALL" > "/etc/sudoers.d/$user"
  fi
  chmod 440 "/etc/sudoers.d/$user"
  id -nG "$user" | grep -qw sudo || usermod -aG sudo "$user"

  # пути
  local home_dir; home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ -d "$home_dir" ]] || { print_err "Домашний каталог не найден: $home_dir"; exit 1; }

  install -d -m 0700 -o "$user" -g "$user" "$home_dir/.ssh"
  install -m 0600 -o "$user" -g "$user" /dev/null "$home_dir/.ssh/authorized_keys"

  # -- выбор источника ключей --
  local root_auth="/root/.ssh/authorized_keys"
  local have_root_keys="no"
  if [[ -s "$root_auth" ]]; then have_root_keys="yes"; fi
  if compgen -G "/root/.ssh/"'*.pub' >/dev/null 2>&1; then have_root_keys="yes"; fi

  local choice=""
  if [[ "$have_root_keys" == "yes" ]]; then
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
      print_err "У root ключей нет, а --key-file не задан (NONINTERACTIVE)."; exit 1
    else
      echo "Ключей у root не найдено. Выберите:"
      echo "  1) Вставить/передать свой публичный ключ(и)"
      echo "  2) Сгенерировать новый ключ (ed25519) для $user"
      read -rp "[?] Вариант [1/2]: " choice
      [[ "$choice" == "2" ]] && choice="3"
    fi
  fi

  # --- подготовим временные файлы ---
  local tmp_existing tmp_candidates tmp_merged
  tmp_existing="$(mktemp)"; tmp_candidates="$(mktemp)"; tmp_merged="$(mktemp)"
  # существующие ключи пользователя
  cat "$home_dir/.ssh/authorized_keys" > "$tmp_existing" || true

  # — функции фильтрации и дедупа —
  filter_keys() {
    # stdin -> stdout: обрезать пробелы, убрать комментарии/пустые строки, оставить валидные префиксы
    awk '
      {
        gsub(/\r/,"");
        sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,"");
        if ($0 ~ /^#/ || $0 == "") next;
        if ($0 ~ /^(ssh-|ecdsa-|sk-)/) print $0;
      }'
  }
  merge_unique() {
    # stdin (много файлов) -> stdout: сохранить первый порядок, убрать дубли
    awk '!seen[$0]++'
  }

  # --- заполняем кандидаты согласно выбору ---
  case "$choice" in
    1)
      # перенос из root
      if [[ -r "$root_auth" ]]; then
        cat "$root_auth" >> "$tmp_candidates" || true
      fi
      (
        shopt -s nullglob
        for f in /root/.ssh/*.pub; do
          [[ -r "$f" ]] && cat "$f" >> "$tmp_candidates"
        done
      )
      ;;
    2)
      if [[ -n "$key_file" ]]; then
        [[ -r "$key_file" ]] || { print_err "Файл ключей недоступен: $key_file"; exit 1; }
        cat "$key_file" >> "$tmp_candidates"
      else
        print_info "Вставьте PUBLIC ключи (OpenSSH), по одному в строке. Завершите ввод Ctrl+D."
        echo "---"
        # читаем произвольное количество строк в файл-кандидат
        cat >> "$tmp_candidates"
      fi
      ;;
    3)
      print_info "Генерация ed25519 ключа для $user…"
      su - "$user" -c "ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/id_ed25519 >/dev/null"
      cat "$home_dir/.ssh/id_ed25519.pub" >> "$tmp_candidates"
      ;;
    *) print_err "Некорректный выбор."; exit 1;;
  esac

  # — фильтруем кандидатов —
  filter_keys < "$tmp_candidates" > "${tmp_candidates}.clean"
  mv -f "${tmp_candidates}.clean" "$tmp_candidates"

  # — формируем объединённый список и считаем добавленные —
  local before after added_count
  before="$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$tmp_existing" || true)"
  cat "$tmp_existing" "$tmp_candidates" | filter_keys | merge_unique > "$tmp_merged"
  after="$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$tmp_merged" || true)"
  if [[ -z "$before" ]]; then before=0; fi
  if [[ -z "$after"  ]]; then after=0; fi
  added_count=$(( after - before ))
  (( added_count < 0 )) && added_count=0

  # — атомарно кладём authorized_keys —
  install -m 0600 -o "$user" -g "$user" "$tmp_merged" "$home_dir/.ssh/authorized_keys"

  print_ok "Добавлено ключей: ${added_count}"
  print_info "Всего ключей у $user: ${after}"

  # Очистка ключей у root (с бэкапом)
  if [[ -f "$root_auth" ]]; then
    local ts backup; ts="$(date +%Y%m%d-%H%M%S)"; backup="/root/authorized_keys.root.backup.$ts"
    cp -a "$root_auth" "$backup" || true
    : > "$root_auth"; chmod 600 "$root_auth"; chown root:root "$root_auth"
    print_ok "Ключи у root очищены. Бэкап: $backup"
  fi

  # уборка tmp
  rm -f "$tmp_existing" "$tmp_candidates" "$tmp_merged"

  USERNAME="$user"; export USERNAME
  print_ok "Готово. Пользователь: $user"
}

if ! $PORT_ONLY; then
  setup_ssh_keys "${USERNAME:-}"
else
  if [[ -z "${USERNAME:-}" ]]; then
    USERNAME="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1":"$3}' /etc/passwd | sort -t: -k2,2n | tail -1 | cut -d: -f1 || true)"
  fi
  if [[ -n "${USERNAME:-}" && "$(id -u "$USERNAME" 2>/dev/null || echo)" ]]; then
    : # ok
  else
    print_warn "USERNAME не задан или не существует — пропущу AllowUsers."
  fi
fi

# ---------- Смена порта и жёсткие опции SSH ----------
OLD_PORT="$(current_ssh_port)"

if [[ -z "$NEW_PORT" ]]; then
  if $NONINTERACTIVE; then print_err "В non-interactive требуется --port"; exit 1; fi
  while :; do
    read -rp "Введите новый порт SSH (1024-65535): " NEW_PORT
    is_valid_port "$NEW_PORT" || { print_warn "Неверный порт"; continue; }
    port_is_free "$NEW_PORT" || { print_warn "Порт занят"; continue; }
    break
  done
else
  is_valid_port "$NEW_PORT" || { print_err "Неверный порт: $NEW_PORT"; exit 1; }
  port_is_free "$NEW_PORT" || { print_err "Порт $NEW_PORT занят"; exit 1; }
fi

print_info "Обновляю /etc/ssh/sshd_config…"
backup_file /etc/ssh/sshd_config

set_sshd_opt "PasswordAuthentication" "no"
set_sshd_opt "ChallengeResponseAuthentication" "no"
set_sshd_opt "PermitRootLogin" "no"
set_sshd_opt "PubkeyAuthentication" "yes"
set_sshd_opt "UsePAM" "yes"
set_sshd_opt "X11Forwarding" "no"
set_sshd_opt "Port" "$NEW_PORT"

if [[ -n "${USERNAME:-}" ]]; then
  append_allow_user "$USERNAME"
fi

ensure_dirs
if ! sshd -t -f /etc/ssh/sshd_config; then
  print_err "Проверка sshd_config не прошла. Откатываю порт."
  set_sshd_opt "Port" "$OLD_PORT"
  exit 1
fi

# ---------- UFW ----------
print_info "Настройка UFW…"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$NEW_PORT"/tcp || true
  ufw --force enable || true
fi

# ---------- Fail2ban ----------
print_info "Настройка fail2ban…"
install -d -m 0755 /etc/fail2ban
JAIL_LOCAL="/etc/fail2ban/jail.local"
backup_file "$JAIL_LOCAL"
cat >"$JAIL_LOCAL" <<EOF
[sshd]
enabled  = true
port     = ${NEW_PORT}
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban --now
systemctl reload fail2ban || systemctl restart fail2ban || true

# ---------- Перезапуск SSH ----------
print_info "Перезапускаю sshd…"
systemctl restart ssh || systemctl reload ssh || { print_err "Не удалось перезапустить sshd"; exit 1; }

# ---------- Финальные проверки ----------
sleep 1
if ss -Hntl 2>/dev/null | grep -q "[:\]]${NEW_PORT}\b"; then
  print_ok "sshd слушает порт ${NEW_PORT}/tcp"
else
  print_warn "Не вижу прослушивания порта ${NEW_PORT}. Проверьте: ss -ntl | grep ${NEW_PORT}"
fi

print_ok "Готово:
 - Пользователь: ${USERNAME:-<не менялся>}
 - Порт SSH: $NEW_PORT (старый: $OLD_PORT)
 - Парольный вход: отключён
 - root вход: отключён
 - UFW: новый порт разрешён (если UFW установлен)
 - fail2ban: включён для sshd на порту $NEW_PORT
"
exit 0
