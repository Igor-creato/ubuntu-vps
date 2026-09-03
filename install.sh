#!/usr/bin/env bash
# Строгий режим выполнения
set -euo pipefail
IFS=$'\n\t'

# Константы и конфигурация
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="3.0.0"
BASE_URL="${UBUNTU_VPS_BASE_URL:-https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts}"
readonly BASE_URL
LOG_FILE="/tmp/ubuntu-setup-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE

# URL скриптов
readonly SSH_SCRIPT_URL="${BASE_URL}/ssh-setup.sh"
readonly CHAT_ID_URL="${BASE_URL}/chat-id.sh"
readonly AUTO_UPDATE_URL="${BASE_URL}/auto_update_ubuntu.sh"
readonly DOCKER_SCRIPT_URL="${BASE_URL}/install-docker.sh"
readonly SSH_SCRIPT_SHA256="8532b0c24810bb81db5a1ecb1f2c116ed680574caa19d80077d19541fbcdd901"
readonly CHAT_ID_SHA256="3dd92314e3472eb60a5805e80e66bf09644d532adc2518e9443107032dc68eb2"
readonly AUTO_UPDATE_SHA256="d78539f007cb20363e87378b20f20de3ee483500005e4e89219b07214f9488ea"
readonly DOCKER_SCRIPT_SHA256="08245f762e816df9537f5a400ef41c1cbecc1c912647c22f080eeb0b9482b21f"

# Цвета для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Параметры для ssh-setup.sh (можно прокинуть окружением)
USERNAME="${USERNAME-}"
SSH_PORT="${SSH_PORT-}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE-}"
errors=0

build_ssh_child_args() {
  [[ -z "${USERNAME:-}" ]] || printf '%s\n' --user "$USERNAME"
  [[ -z "${SSH_PORT:-}" ]] || printf '%s\n' --port "$SSH_PORT"
  [[ -z "${PUBLIC_KEY_FILE:-}" ]] || printf '%s\n' --public-key-file "$PUBLIC_KEY_FILE"
}

verify_script_digest() {
  local script_path="$1"
  local expected="$2"
  local actual
  actual="$(sha256sum "$script_path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

increment_errors() {
  errors=$((errors + 1))
}

final_result_status() {
  [[ $errors -eq 0 ]]
}

build_execution_plan() {
  local install_ssh="$1"
  local get_chat_id="$2"
  local setup_auto_update="$3"
  local install_docker="$4"
  [[ "$install_ssh" == true ]] && printf '%s\n' ssh
  printf '%s\n' system-update
  [[ "$install_ssh" == true ]] && printf '%s\n' ssh-verify
  [[ "$get_chat_id" == true ]] && printf '%s\n' chat
  [[ "$setup_auto_update" == true ]] && printf '%s\n' auto-update
  [[ "$install_docker" == true ]] && printf '%s\n' docker
  return 0
}

build_update_arguments() {
  printf '%s\n' 'upgrade -y --with-new-pkgs'
}

prompt_ssh_inputs() {
  if [[ -z "${USERNAME:-}" ]]; then
    read -r -p "Имя административного пользователя: " USERNAME
  fi
  if [[ -z "${SSH_PORT:-}" ]]; then
    read -r -p "Новый SSH-порт (1-65535): " SSH_PORT
  fi
}

confirm_execution() {
  [[ "${VPS_AUTO_CONFIRM:-false}" == true ]] && return 0
  local reply
  read -r -p "Продолжить? (Y/n): " -n 1 reply
  echo
  [[ ! "$reply" =~ ^[Nn]$ ]]
}

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
  local deps=("curl" "bash" "sha256sum" "wc" "head" "awk")
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

# Требуем root (исправлено fi)
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "Нужны права root. Запустите: sudo $SCRIPT_NAME ..."
    exit 1
  fi
}

# Проверка системы и сети
check_system_compatibility() {
  [[ -f /etc/os-release ]] || { log "ERROR" "Не найден /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || { log "ERROR" "Поддерживается только Ubuntu"; exit 1; }
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) log "ERROR" "Поддерживаются Ubuntu 22.04 и 24.04; обнаружена ${VERSION_ID:-unknown}"; exit 1 ;;
  esac

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

# Безопасное исполнение удалённого скрипта (с поддержкой аргументов)
safe_execute_remote_script() {
  local url="$1"; shift
  local description="$1"; shift
  local expected_digest="$1"; shift
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
  if ! verify_script_digest "$temp_script" "$expected_digest"; then
    log "ERROR" "SHA256 не совпадает с проверенной версией; выполнение запрещено"
    return 1
  fi

  if [[ $# -gt 0 ]]; then
    log "INFO" "Параметры подскрипта: $*"
  fi

  if [[ "${VPS_AUTO_CONFIRM:-false}" != true ]]; then
    read -p "Выполнить '$description'? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "INFO" "Пропуск: $description"
      return 0
    fi
  fi

  # Экспорт совместимых переменных окружения (на случай, если подскрипт обращается к $user)
  if [[ -n "${USERNAME:-}" ]]; then
    export USERNAME
    export user="$USERNAME"
  fi
  if [[ -n "${SSH_PORT:-}" ]]; then
    export SSH_PORT
  fi

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
  --username NAME       Имя пользователя для ssh-setup.sh  (альтернатива: переменная окружения USERNAME)
  --ssh-port PORT       Порт SSH для ssh-setup.sh          (альтернатива: переменная окружения SSH_PORT)
  --public-key-file PATH Публичный ключ/authorized_keys для ssh-setup.sh
  --help, -h            Показать справку
  --version             Показать версию

ПРИМЕРЫ:
  $SCRIPT_NAME
  $SCRIPT_NAME --ssh --docker
  $SCRIPT_NAME --ssh --username igor --ssh-port 55555
  USERNAME=admin SSH_PORT=2222 $SCRIPT_NAME --ssh
EOF
}

# Шаг 1 — обновление системы (всегда)
system_update() {
  log "INFO" "Безопасное обновление пакетов после подготовки SSH..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y --with-new-pkgs
  apt-get -y autoclean

  if [[ -f /var/run/reboot-required ]]; then
    log "WARN" "Система требует перезагрузки после обновления."
  fi
}

# Парсинг опций
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
      --username)
        [[ $# -ge 2 ]] || { log "ERROR" "Для --username требуется значение"; return 2; }
        USERNAME="$2"; shift
        ;;
      --ssh-port)
        [[ $# -ge 2 ]] || { log "ERROR" "Для --ssh-port требуется значение"; return 2; }
        SSH_PORT="$2"; shift
        ;;
      --public-key-file)
        [[ $# -ge 2 ]] || { log "ERROR" "Для --public-key-file требуется значение"; return 2; }
        PUBLIC_KEY_FILE="$2"; shift
        ;;
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

validate_inputs() {
  if [[ -n "${USERNAME:-}" ]]; then
    if [[ "$USERNAME" == root ]] || ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
      log "ERROR" "Некорректное имя пользователя: '$USERNAME'"
      exit 2
    fi
    if command -v getent >/dev/null 2>&1; then
      local passwd_record uid
      if passwd_record="$(getent passwd "$USERNAME")"; then
        IFS=: read -r _ _ uid _ <<<"$passwd_record"
        if [[ "$uid" == 0 ]]; then
          log "ERROR" "Пользователь '$USERNAME' имеет UID 0 и не может быть target SSH hardening"
          exit 2
        fi
      fi
    fi
  fi
  if [[ -n "${SSH_PORT:-}" ]]; then
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ && ${#SSH_PORT} -le 5 ]] || (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
      log "ERROR" "Некорректный порт SSH: '$SSH_PORT'"
      exit 2
    fi
  fi
  if [[ -n "${PUBLIC_KEY_FILE:-}" && ! -s "$PUBLIC_KEY_FILE" ]]; then
    log "ERROR" "Файл публичного ключа отсутствует или пуст: $PUBLIC_KEY_FILE"
    exit 2
  fi
}

main() {
  log "INFO" "Запуск $SCRIPT_NAME v$SCRIPT_VERSION"
  log "INFO" "Логи: $LOG_FILE"

  local install_ssh=false
  local get_chat_id=false
  local setup_auto_update=false
  local install_docker=false
  local planned_step

  parse_args install_ssh get_chat_id setup_auto_update install_docker "$@"
  if [[ "$install_ssh" == true ]]; then
    prompt_ssh_inputs
  fi
  validate_inputs
  require_root
  check_dependencies
  check_system_compatibility

  log "INFO" "План выполнения:"
  while IFS= read -r planned_step; do
    log "INFO" "  - $planned_step"
  done < <(build_execution_plan "$install_ssh" "$get_chat_id" "$setup_auto_update" "$install_docker")

  echo
  if ! confirm_execution; then
    log "INFO" "Выход по запросу пользователя."
    exit 0
  fi

  if [[ "$install_ssh" == true ]]; then
    local -a args=()
    mapfile -t args < <(build_ssh_child_args)
    safe_execute_remote_script "$SSH_SCRIPT_URL" "Транзакционная настройка SSH" "$SSH_SCRIPT_SHA256" "${args[@]}" || {
      log "ERROR" "SSH migration не завершена; остальные мутации отменены"
      exit 1
    }
  fi

  system_update || { log "ERROR" "Сбой обновления системы"; exit 1; }

  if [[ "$install_ssh" == true ]]; then
    local -a verify_args=(--verify-only)
    [[ -z "${USERNAME:-}" ]] || verify_args+=(--user "$USERNAME")
    [[ -z "${SSH_PORT:-}" ]] || verify_args+=(--port "$SSH_PORT")
    VPS_AUTO_CONFIRM=true safe_execute_remote_script "$SSH_SCRIPT_URL" "Проверка SSH после обновления" "$SSH_SCRIPT_SHA256" "${verify_args[@]}" || {
      log "ERROR" "SSH verification после обновления не прошла; не закрывайте текущую сессию"
      exit 1
    }
  fi

  if [[ "$get_chat_id" == true ]]; then
    safe_execute_remote_script "$CHAT_ID_URL" "Получение Telegram Chat ID" "$CHAT_ID_SHA256" || increment_errors
  fi

  if [[ "$setup_auto_update" == true ]]; then
    safe_execute_remote_script "$AUTO_UPDATE_URL" "Настройка автоматических обновлений" "$AUTO_UPDATE_SHA256" || increment_errors
  fi

  if [[ "$install_docker" == true ]]; then
    local -a docker_args=()
    [[ -z "${USERNAME:-}" ]] || docker_args+=(--user "$USERNAME")
    safe_execute_remote_script "$DOCKER_SCRIPT_URL" "Установка Docker" "$DOCKER_SCRIPT_SHA256" "${docker_args[@]}" || increment_errors
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

  final_result_status
}

trap 'log "ERROR" "Скрипт прерван сигналом"; exit 130' INT TERM
if [[ "${VPS_INSTALL_LIBRARY:-0}" != "1" ]]; then
  main "$@"
fi
