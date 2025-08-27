#!/usr/bin/env bash
# Строгий режим выполнения
set -euo pipefail
IFS=$'\n\t'

# Константы и конфигурация
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.0"
readonly BASE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts"
readonly LOG_FILE="/tmp/ubuntu-setup-$(date +%Y%m%d-%H%M%S).log"

# URL скриптов (исправлена опечатка)
readonly SSH_SCRIPT_URL="${BASE_URL}/ssh-setup.sh"
readonly CHAT_ID_URL="${BASE_URL}/chat-id.sh"
readonly AUTO_UPDATE_URL="${BASE_URL}/auto_update_ubuntu.sh"  # Исправлена опечатка
readonly DOCKER_SCRIPT_URL="${BASE_URL}/install-docker.sh"

# Цвета для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Функция логирования
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "INFO")  echo -e "${BLUE}[INFO]${NC}  $message" | tee -a "$LOG_FILE" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  $message" | tee -a "$LOG_FILE" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE" ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Функция проверки зависимостей
check_dependencies() {
    local deps=("curl" "bash")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Отсутствуют необходимые зависимости: ${missing_deps[*]}"
        log "INFO" "Установите их командой: sudo apt update && sudo apt install -y ${missing_deps[*]}"
        exit 1
    fi
}

# Функция проверки прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "WARN" "Некоторые операции требуют root привилегий"
        log "INFO" "Рекомендуется запустить скрипт с sudo"
        read -p "Продолжить без root? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Выход по запросу пользователя"
            exit 0
        fi
    fi
}

# Функция проверки доступности URL
check_url() {
    local url="$1"
    local timeout=10
    
    if curl --silent --fail --head --max-time "$timeout" "$url" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Функция безопасного выполнения удаленного скрипта
safe_execute_remote_script() {
    local url="$1"
    local description="$2"
    local temp_script
    
    log "INFO" "Выполнение: $description"
    log "INFO" "URL: $url"
    
    # Проверяем доступность URL
    if ! check_url "$url"; then
        log "ERROR" "URL недоступен: $url"
        return 1
    fi
    
    # Создаем временный файл
    temp_script=$(mktemp)
    trap "rm -f '$temp_script'" EXIT
    
    # Скачиваем скрипт
    if ! curl -fsSL --max-time 30 "$url" -o "$temp_script"; then
        log "ERROR" "Не удалось скачать скрипт: $url"
        return 1
    fi
    
    # Проверяем, что файл не пустой и является bash скриптом
    if [[ ! -s "$temp_script" ]]; then
        log "ERROR" "Скачанный файл пустой: $url"
        return 1
    fi
    
    if ! head -n1 "$temp_script" | grep -q "^#!/bin/bash"; then
        log "WARN" "Файл может не быть bash скриптом: $url"
        log "INFO" "Первая строка: $(head -n1 "$temp_script")"
    fi
    
    # Показываем пользователю информацию о скрипте
    log "INFO" "Размер скрипта: $(wc -c < "$temp_script") байт"
    log "INFO" "Контрольная сумма (SHA256): $(sha256sum "$temp_script" | cut -d' ' -f1)"
    
    # Запрашиваем подтверждение
    read -p "Выполнить скрипт '$description'? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Пропуск выполнения: $description"
        return 0
    fi
    
    # Выполняем скрипт
    if bash "$temp_script"; then
        log "SUCCESS" "Успешно выполнено: $description"
        return 0
    else
        local exit_code=$?
        log "ERROR" "Ошибка выполнения: $description (код: $exit_code)"
        return $exit_code
    fi
}

# Функция отображения справки
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Скрипт автоматической настройки Ubuntu VPS сервера

ИСПОЛЬЗОВАНИЕ:
    $SCRIPT_NAME [ОПЦИИ]

ОПЦИИ:
    --ssh        Установка и настройка SSH
    --chat       Получение Telegram Chat ID
    --update     Настройка автоматических обновлений
    --docker     Установка Docker
    --help, -h   Показать эту справку
    --version    Показать версию

ПРИМЕРЫ:
    $SCRIPT_NAME                    # Установить все компоненты
    $SCRIPT_NAME --ssh --docker     # Установить только SSH и Docker
    $SCRIPT_NAME --help             # Показать справку

ФАЙЛЫ:
    Логи сохраняются в: $LOG_FILE

EOF
}

# Функция проверки совместимости системы
check_system_compatibility() {
    # Проверяем, что это Ubuntu
    if [[ ! -f /etc/os-release ]] || ! grep -q "ubuntu" /etc/os-release; then
        log "WARN" "Скрипт предназначен для Ubuntu, но обнаружена другая система"
    fi
    
    # Проверяем версию Ubuntu
    if [[ -f /etc/os-release ]]; then
        local ubuntu_version
        ubuntu_version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        log "INFO" "Версия Ubuntu: $ubuntu_version"
        
        # Предупреждаем о старых версиях
        case "$ubuntu_version" in
            "18.04"|"16.04"|"14.04")
                log "WARN" "Обнаружена устаревшая версия Ubuntu ($ubuntu_version)"
                log "WARN" "Рекомендуется обновление до более новой версии"
                ;;
        esac
    fi
    
    # Проверяем доступность интернета
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        log "ERROR" "Отсутствует подключение к интернету"
        exit 1
    fi
}

# Основная функция
main() {
    # Инициализация
    log "INFO" "Запуск $SCRIPT_NAME v$SCRIPT_VERSION"
    log "INFO" "Логи записываются в: $LOG_FILE"
    
    # Проверки системы
    check_system_compatibility
    check_dependencies
    check_root
    
    # Парсинг аргументов
    local install_ssh=false
    local chat_id=false
    local auto_update=false
    local install_docker=false
    
    # Если аргументов нет - устанавливаем всё
    if [[ $# -eq 0 ]]; then
        install_ssh=true
        chat_id=true
        auto_update=true
        install_docker=true
        log "INFO" "Аргументы не указаны - будут установлены все компоненты"
    else
        # Парсим аргументы
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --ssh)
                    install_ssh=true
                    shift
                    ;;
                --chat)
                    chat_id=true
                    shift
                    ;;
                --update)
                    auto_update=true
                    shift
                    ;;
                --docker)
                    install_docker=true
                    shift
                    ;;
                --help|-h)
                    show_help
                    exit 0
                    ;;
                --version)
                    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
                    exit 0
                    ;;
                *)
                    log "ERROR" "Неизвестная опция: $1"
                    log "INFO" "Используйте --help для справки"
                    exit 1
                    ;;
            esac
        done
    fi
    
    # Показываем план выполнения
    log "INFO" "План выполнения:"
    [[ "$install_ssh" == true ]] && log "INFO" "  ✓ Установка SSH"
    [[ "$chat_id" == true ]] && log "INFO" "  ✓ Получение Chat ID"
    [[ "$auto_update" == true ]] && log "INFO" "  ✓ Настройка автообновлений"
    [[ "$install_docker" == true ]] && log "INFO" "  ✓ Установка Docker"
    
    echo
    read -p "Продолжить? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log "INFO" "Выход по запросу пользователя"
        exit 0
    fi
    
    # Счетчик ошибок
    local error_count=0
    
    # Последовательное выполнение
    if [[ "$install_ssh" == true ]]; then
        if ! safe_execute_remote_script "$SSH_SCRIPT_URL" "Установка и настройка SSH"; then
            ((error_count++))
        fi
    fi
    
    if [[ "$chat_id" == true ]]; then
        if ! safe_execute_remote_script "$CHAT_ID_URL" "Получение Telegram Chat ID"; then
            ((error_count++))
        fi
    fi
    
    if [[ "$auto_update" == true ]]; then
        if ! safe_execute_remote_script "$AUTO_UPDATE_URL" "Настройка автоматических обновлений"; then
            ((error_count++))
        fi
    fi
    
    if [[ "$install_docker" == true ]]; then
        if ! safe_execute_remote_script "$DOCKER_SCRIPT_URL" "Установка Docker"; then
            ((error_count++))
        fi
    fi
    
    # Итоговый отчет
    echo
    if [[ $error_count -eq 0 ]]; then
        log "SUCCESS" "Все операции выполнены успешно! ✅"
    else
        log "WARN" "Завершено с ошибками: $error_count"
        log "INFO" "Проверьте лог: $LOG_FILE"
    fi
    
    log "INFO" "Рекомендуется перезагрузить систему: sudo reboot"
}

# Обработка сигналов
trap 'log "ERROR" "Скрипт прерван сигналом"; exit 130' INT TERM

# Запуск основной функции
main "$@"
