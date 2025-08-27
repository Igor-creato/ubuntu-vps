#!/usr/bin/env bash
# install.sh — оркестратор установки и настройки Ubuntu VPS
# Последовательность:
#  1) Обновление системы
#  2) Создание пользователя + настройка SSH
#  3) Получение Telegram chat.id
#  4) Включение автообновлений
#  5) (опционально) Установка Docker
#
# Требования: запуск от root

set -euo pipefail
IFS=$'\n\t'

# -----------------------------
# Константы и конфигурация
# -----------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.3.0"
readonly BASE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts"

# Внешние подскрипты
readonly SSH_SCRIPT_URL="${BASE_URL}/ssh-setup.sh"
readonly CHAT_ID_URL="${BASE_URL}/chat-id.sh"
readonly AUTO_UPDATE_URL="${BASE_URL}/auto_update_ubuntu.sh"
readonly DOCKER_SCRIPT_URL="${BASE_URL}/install-docker.sh"

# Цвета
readonly C_RESET=$'\033[0m'
readonly C_INFO=$'\033[1;34m'
readonly C_WARN=$'\033[1;33m'
readonly C_ERR=$'\033[1;31m'
readonly C_OK=$'\033[1;32m'

# Лог-файл
readonly LOG_FILE="/tmp/ubuntu-setup-$(date +%Y%m%d-%H%M%S).log"

# -----------------------------
# Глобальные переменные (настраиваются флагами)
# -----------------------------
USERNAME="${USERNAME-}"      # Имя создаваемого администратора (не root)
SSH_PORT="${SSH_PORT-}"      # Новый порт SSH (опционально)
WITH_DOCKER=false            # Устанавливать Docker на последнем шаге
NON_INTERACTIVE=false        # Не задавать вопросы, падать если чего-то не хватает

# -----------------------------
# Утилиты вывода
# -----------------------------
info()  { echo "${C_INFO}[INFO]${C_RESET}  $*"; }
warn()  { echo "${C_WARN}[WARN]${C_RESET}  $*"; }
ok()    { echo "${C_OK}[OK]${C_RESET}    $*"; }
err()   { echo "${C_ERR}[ERROR]${C_RESET} $*" >&2; }

abort() {
  err "$*"
  err "См. лог: $LOG_FILE"
  exit 1
}

# Выполнить команду и логировать код выхода
run_step() {
  local title="$1"; shift
  info "Выполнение: ${title}"
  if "$@" >>"$LOG_FILE" 2>&1; then
    ok "${title}"
  else
    local rc=$?
    err "Ошибка выполнения: ${title} (код: ${rc})"
    exit "$rc"
  fi
}

# Получить и выполнить удалённый скрипт, передав параметры
fetch_and_run() {
  local url="$1"; shift
  info "URL: ${url}"
  # Защита от не-bash: проверим shebang и размер как минимум
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    abort "Не удалось скачать: $url"
  fi

  local first_line
  first_line="$(head -n1 "$tmp" || true)"
  local size
  size="$(wc -c <"$tmp" | tr -d ' ')"
  info "Первая строка: ${first_line}"
  info "Размер скрипта: ${size} байт"

  if [[ "$first_line" != "#!"*bash* ]]; then
    warn "Файл может не быть bash-скриптом: ${url}"
  fi

  # Запускаем как подскрипт bash, окружение экспортировано выше
  if bash "$tmp" "$@" >>"$LOG_FILE" 2>&1; then
    ok "Скрипт выполнен успешно: $(basename "$url")"
  else
    local rc=$?
    err "Ошибка выполнения: $(basename "$url") (код: ${rc})"
    rm -f "$tmp"
    exit "$rc"
  fi
  rm -f "$tmp"
}

# -----------------------------
# Проверка окружения
# -----------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    abort "Запустите ${SCRIPT_NAME} от root (sudo -i)."
  fi
}

require_ubuntu_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    abort "Не обнаружен apt-get. Скрипт рассчитан на Ubuntu/Debian."
  fi
}

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — установка и настройка Ubuntu VPS

Использование:
  ${SCRIPT_NAME} [опции]

Опции:
  --user NAME           Имя администратора (будет создан и добавлен в sudo).
  --ssh-port PORT       Новый порт SSH (опционально). Если не задан, останется текущий/скрипт предложит.
  --with-docker         Установить Docker на последнем шаге.
  --non-interactive     Без вопросов (потребуются --user и все необходимые переменные).
  -h|--help             Показать эту справку.

Также можно прокинуть через окружение:
  USERNAME, SSH_PORT

Примеры:
  ${SCRIPT_NAME} --user igor --ssh-port 55555 --with-docker
  USERNAME=admin ${SCRIPT_NAME} --with-docker --non-interactive
EOF
}

# -----------------------------
# Парсинг аргументов
# -----------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        USERNAME="${2-}"; shift 2 || { err "Отсутствует значение для --user"; exit 2; }
        ;;
      --ssh-port)
        SSH_PORT="${2-}"; shift 2 || { err "Отсутствует значение для --ssh-port"; exit 2; }
        ;;
      --with-docker)
        WITH_DOCKER=true; shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=true; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        err "Неизвестный аргумент: $1"
        usage; exit 2
        ;;
    esac
  done
}

# -----------------------------
# Нормализация и запросы (если не non-interactive)
# -----------------------------
normalize_inputs() {
  # USERNAME
  if [[ -z "${USERNAME}" ]]; then
    if [[ "${NON_INTERACTIVE}" == true ]]; then
      abort "USERNAME не задан. Укажите --user NAME или переменную окружения USERNAME."
    fi
    read -rp "Введите имя нового пользователя (админ, не root): " USERNAME
    USERNAME="${USERNAME// /}"  # убрать пробелы
  fi
  # Базовая валидация имени
  if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    abort "Некорректное имя пользователя: '${USERNAME}'"
  fi

  # SSH_PORT (опционально)
  if [[ -z "${SSH_PORT}" && "${NON_INTERACTIVE}" == false ]]; then
    read -rp "Введите новый порт SSH (Enter — пропустить и оставить по умолчанию): " SSH_PORT || true
    SSH_PORT="${SSH_PORT// /}"
  fi
  if [[ -n "${SSH_PORT}" ]]; then
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
      abort "Некорректный порт SSH: '${SSH_PORT}'"
    fi
  fi

  export USERNAME SSH_PORT
}

# -----------------------------
# Шаги установки
# -----------------------------
step_system_update() {
  run_step "Обновление индексa пакетов"          apt-get update -y
  # Минимизируем вопросы в upgrade
  DEBIAN_FRONTEND=noninteractive run_step "Обновление установленных пакетов" apt-get -y -o Dpkg::Options::="--force-confnew" upgrade
  run_step "Авточистка пакетов"                  apt-get autoremove -y
  run_step "Очистка кеша apt"                    apt-get clean
}

step_ssh_setup() {
  # Передаём параметры в ssh-setup.sh:
  #   --user USERNAME обязательно
  #   --port SSH_PORT  если указан
  local args=( --user "$USERNAME" )
  if [[ -n "${SSH_PORT}" ]]; then
    args+=( --port "$SSH_PORT" )
  fi
  fetch_and_run "$SSH_SCRIPT_URL" "${args[@]}"
}

step_chat_id() {
  fetch_and_run "$CHAT_ID_URL"
}

step_auto_updates() {
  fetch_and_run "$AUTO_UPDATE_URL"
}

step_docker_optional() {
  if [[ "${WITH_DOCKER}" == true ]]; then
    fetch_and_run "$DOCKER_SCRIPT_URL"
  else
    info "Шаг установки Docker пропущен (не указан --with-docker)."
  fi
}

# -----------------------------
# Точка входа
# -----------------------------
main() {
  : >"$LOG_FILE" || abort "Не могу писать лог в $LOG_FILE"

  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  info "Лог выполнения: $LOG_FILE"

  require_root
  require_ubuntu_apt
  parse_args "$@"
  normalize_inputs

  # Весь пайплайн
  step_system_update
  step_ssh_setup
  step_chat_id
  step_auto_updates
  step_docker_optional

  ok "Готово! Все шаги выполнены успешно."
}

main "$@"
