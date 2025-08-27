#!/usr/bin/env bash
# Строгий режим выполнения
set -euo pipefail
IFS=$'\n\t'

# Константы и конфигурация
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2"   # <<< повышена версия
readonly BASE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts"
readonly LOG_FILE="/tmp/ubuntu-setup-$(date +%Y%m%d-%H%M%S).log"

# URL скриптов
readonly SSH_SCRIPT_URL="${BASE_URL}/ssh-setup.sh"
readonly CHAT_ID_URL="${BASE_URL}/chat-id.sh"
readonly AUTO_UPDATE_URL="${BASE_URL}/auto_update_ubuntu.sh"
readonly DOCKER_SCRIPT_URL="${BASE_URL}/install-docker.sh"

# Цвета для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --- Параметры, которые нужны ssh-setup.sh ---  # <<<
USERNAME="${USERNAME-}"   # можно задать через окружение USERNAME
SSH_PORT="${SSH_PORT-}"   # можно задать через окружение SSH_PORT

# Логирование
log() {
  local level="$1"; shift
  local message="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  case "$level" in
    INFO)    echo -e "${BLUE}[INFO]${NC}    $message" | tee -a "$LOG_FILE" ;;
    WARN)    echo -e "${YELLOW}[WARN]${NC}    $message" | tee -a "$LOG_FILE" ;;
    ERROR)   echo -e "${RED}[ERROR]${NC}   $message" | tee -a "$LOG_FILE" ;;
    SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE" ;;
    *)       echo "[${level}] $message" | tee -a "$LOG_FILE" ;;
  esac

  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Проверка зависимостей
check_dependencies() {
  local deps=("curl" "bash" "sha256sum" "wc" "head")
  local missing=()
  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "ERROR" "Отсутствуют зависимости: ${missing[*]}"
    log "INFO"  "Установка: apt-get update && apt-get install -y ${missing[*]}"
    exit 1
  fi
}

# Требуем root
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "Нужны права root. Запустите: sudo $SCRIPT_NAME ..."
    exit 1
  }
}

# Проверка системы и сети
check_system_compatibility() {
  if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then
    log "WARN" "Обнаружена не Ubuntu. Скрипт рассчитан на Ubuntu."
  fi

  if [[ -f /etc/os-release ]]; then
    local ubuntu_version
    ubuntu_version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 || true)
    [[ -n "${ubuntu_version:-}" ]] && log "INFO" "Версия Ubuntu: $ubuntu_version"
  fi

  # Проверка доступа в интернет без ICMP: HEAD-запрос
  if ! curl -I -s --max-time 10 https://deb.debian.org >/dev/null; then
    log "ERROR" "Нет сетевого доступа (HTTPS недоступен)."
    exit 1
  fi
}

# Проверка доступности URL
check_url() {
  local url="$1"
  curl --silent --fail --head --max-time 10 "$url" >/dev/null 2>&1
}

# Безопасное исполнение удалённого скрипта
# Теперь поддерживает передачу аргументов подскрипту: safe_execute_remote_script URL "desc" -- arg1 arg2 ...  # <<<
safe_execute_remote_script() {
  local url="$1"; shift
  local description="$1"; shift
  local temp_script

  log "INFO" "Выполнение: $description"
  log "INFO" "URL: $url"

  if ! check_url "$url"; then
    log "ERROR" "URL недоступен: $url"
    return 1
  fi

  temp_script="$(mktemp)"
  # Очистка временного файла при любом выходе из функции/скрипта
  trap '[[ -f "'"$temp_script"'" ]] && rm -f "'"$temp_script"'" || true' RETURN

  if ! curl -fsSL --max-time 60 "$url" -o "$temp_script"; then
    log "ERROR" "Не удалось скачать: $url"
    return 1
  fi

  if [[ ! -s "$temp_script" ]]; then
    log "ERROR" "Скачанный файл пуст: $url"
    return 1
  fi

  local first_line
  first_line="$(head -n1 "$temp_script" || true)"
  if ! grep -Eq '^#!(/usr/bin/env[[:space:]]+bash|/bin/bash)$' <<<"$first_line"; then
    log "WARN" "Не найден ожидаемый shebang bash."
    log "INFO" "Первая строка: $first_line"
  fi

  log "INFO" "Размер скрипта: $(wc -c < "$temp_script") байт"
  log "INFO" "SHA256: $(sha256sum "$temp_script" | cut -d' ' -f1)"

  # Показать, какие аргументы пойдут в подскрипт  # <<<
  if [[ $# -gt 0 ]]; then
    log "INFO" "Параметры подскрипта: $*"
  fi

  read -p "Выполнить '$description'? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Пропуск: $description"
    return 0
  fi

  # ВАЖНО: экспортируем совместимые переменные окружения для старых подскриптов  # <<<
  # Если подскрипт ожидает переменную `user`, она будет задана.
  if [[ -n "${USERNAME:-}" ]]; then
    export USERNAME
    export user="$USERNAME"
  fi
  if [[ -n "${SSH_PORT:-}" ]]; then
    export SSH_PORT
  fi

  # Запуск с аргументами (если переданы)
  if bash "$temp_script" "$@"; then
    log "SUCCESS" "Успешно: $description"
    return 0
  else
    local code=$?
    log "ERROR" "Ошибка выполнения: $description (код: $code)"
    return $code
  fi
}

# Справка
show_help() {
  cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Оркестратор первичной настройки Ubuntu VPS

ИСПОЛЬЗОВАНИЕ:
  $SCRIPT_NAME [ОПЦИИ]

ОПЦИИ:
  --ssh                 Установка и настройка SSH
  --chat                Получение Telegram Chat ID
  --update              Настройка автоматических обновлений
  --docker              Установка Docker

  --username NAME       Имя пользователя для ssh-setup.sh  (альтернатива: переменная окружения USERNAME)   # <<<
  --ssh-port PORT       Порт SSH для ssh-setup.sh           (альтернатива: переменная окружения SSH_PORT)  # <<<
  --help, -h            Показать справку
  --version             Показать версию

ПРИМЕРЫ:
  $SCRIPT_NAME                            # Выполнить всё (в правильном порядке)
  $SCRIPT_NAME --ssh --docker             # Обновление системы + SSH, затем Docker
  $SCRIPT_NAME --ssh --username igor --ssh-port 55555       # <<<
  USERNAME=admin SSH_PORT=2222 $SCRIPT_NAME --ssh            # <<<
EOF
}

# Шаг 1 — обновление системы (всегда)
system_update() {
  log "INFO" "Обновление списка пакетов и установленного ПО..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -y dist-upgrade
  apt-get -y autoremove --purge
  apt-get -y autoclean

  if [[ -f /var/run/reboot-required ]]; then
    log "WARN" "Система требует перезагрузки после обновления."
  fi
}

# --- парсинг опций, включая --username/--ssh-port ---  # <<<
parse_args() {
  local -n _install_ssh=$1
  local -n _get_chat_id=$2
  local -n _setup_auto_update=$3
  local -n _install_docker=$4
  shift 4

  if [[ $# -eq 0 ]]; then
    _install_ssh=true
    _get_chat_id=true
    _setup_auto_update=true
    _install_docker=true
    log "INFO" "Опции не заданы — будут выполнены все шаги."
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh)        _install_ssh=true ;;
      --chat)       _get_chat_id=true ;;
      --update)     _setup_auto_update=true ;;
      --docker)     _install_docker=true ;;
      --username)   USERNAME="${2-}"; shift ;;
      --ssh-port)   SSH_PORT="${2-}"; shift ;;
      --help|-h)    show_help; exit 0 ;;
      --version)    echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
      *)
        log "ERROR" "Неизвестная опция: $1"
        exit 1
        ;;
    esac
    shift
  done
}

# --- валидация USERNAME/SSH_PORT (мягкая) ---  # <<<
validate_inputs() {
  if [[ -n "${USERNAME:-}" ]]; then
    if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
      log "ERROR" "Некорректное имя пользователя: '$USERNAME'"
      exit 2
    fi
  fi
  if [[ -n "${SSH_PORT:-}" ]]; then
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
      log "ERROR" "Некорректный порт SSH: '$SSH_PORT'"
      exit 2
    fi
  fi
}

main() {
  log "INFO" "Запуск $SCRIPT_NAME v$SCRIPT_VERSION"
  log "INFO" "Логи: $LOG_FILE"

  require_root
  check_dependencies
  check_system_compatibility

  local install_ssh=false
  local get_chat_id=false
  local setup_auto_update=false
  local install_docker=false

  parse_args install_ssh get_chat_id setup_auto_update install_docker "$@"
  validate_inputs

  # План выполнения (фиксированный порядок)
  log "INFO" "План выполнения:"
  log "INFO" "  1) Обновление системы (обязательно)"
  [[ "$install_ssh" == true       ]] && log "INFO" "  2) Настройка SSH"
  [[ "$get_chat_id" == true       ]] && log "INFO" "  3) Получение Chat ID"
  [[ "$setup_auto_update" == true ]] && log "INFO" "  4) Настройка автообновлений"
  [[ "$install_docker" == true    ]] && log "INFO" "  5) Установка Docker"

  echo
  read -p "Продолжить? (Y/n): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    log "INFO" "Выход по запросу пользователя."
    exit 0
  fi

  local errors=0

  # 1) Обновление системы
  system_update || { log "ERROR" "Сбой обновления системы"; exit 1; }

  # 2) SSH — формируем аргументы для подскрипта    # <<<
  if [[ "$install_ssh" == true ]]; then
    args=()
    if [[ -n "${USERNAME:-}" ]]; then
      args+=( --user "$USERNAME" )
    fi
    if [[ -n "${SSH_PORT:-}" ]]; then
      args+=( --port "$SSH_PORT" )
    fi
    # ВАЖНО: даже если args пуст, мы всё равно экспортируем окружение внутри safe_execute_remote_script
    safe_execute_remote_script "$SSH_SCRIPT_URL" "Установка и настройка SSH" "${args[@]}" || ((errors++))
  fi

  # 3) Chat ID
  if [[ "$get_chat_id" == true ]]; then
    safe_execute_remote_script "$CHAT_ID_URL" "Получение Telegram Chat ID" || ((errors++))
  fi

  # 4) Автообновления
  if [[ "$setup_auto_update" == true ]]; then
    safe_execute_remote_script "$AUTO_UPDATE_URL" "Настройка автоматических обновлений" || ((errors++))
  fi

  # 5) Docker (опционально и в конце)
  if [[ "$install_docker" == true ]]; then
    safe_execute_remote_script "$DOCKER_SCRIPT_URL" "Установка Docker" || ((errors++))
  fi

  echo
  if [[ $errors -eq 0 ]]; then
    log "SUCCESS" "Все операции выполнены успешно! ✅"
  else
    log "WARN" "Завершено с ошибками: $errors. Проверьте лог: $LOG_FILE"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    log "INFO" "Рекомендуется перезагрузка: sudo reboot"
  fi
}

trap 'log "ERROR" "Скрипт прерван сигналом"; exit 130' INT TERM
main "$@"
