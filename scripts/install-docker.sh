#!/usr/bin/env bash

# Улучшенный скрипт установки Docker и Docker Compose для Ubuntu
# Версия: 2.0
# Совместимость: Ubuntu 20.04+, 22.04+, 24.04+

set -euo pipefail
IFS=$'\n\t'

# === КОНСТАНТЫ И КОНФИГУРАЦИЯ ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/${SCRIPT_NAME%.*}.log"
readonly DOCKER_GPG_KEY="/etc/apt/keyrings/docker.gpg"
readonly DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
readonly MIN_UBUNTU_VERSION="20.04"

# === ФУНКЦИИ ЛОГИРОВАНИЯ ===
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# === ФУНКЦИЯ: проверка системы ===
check_system() {
    log_info "Проверяю системные требования..."
    
    # Проверка ОС
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_error "Скрипт предназначен только для Ubuntu"
        exit 1
    fi
    
    # Проверка версии Ubuntu
    local ubuntu_version
    ubuntu_version=$(lsb_release -rs)
    if ! printf '%s\n%s\n' "$MIN_UBUNTU_VERSION" "$ubuntu_version" | sort -V | head -n1 | grep -q "^$MIN_UBUNTU_VERSION$"; then
        log_error "Требуется Ubuntu $MIN_UBUNTU_VERSION или новее. Текущая версия: $ubuntu_version"
        exit 1
    fi
    
    # Проверка архитектуры
    local arch
    arch=$(dpkg --print-architecture)
    if [[ ! "$arch" =~ ^(amd64|arm64|armhf)$ ]]; then
        log_warn "Неподдерживаемая архитектура: $arch. Продолжаю, но могут быть проблемы."
    fi
    
    # Проверка прав root/sudo
    if [[ $EUID -eq 0 ]]; then
        log_warn "Скрипт запущен от root. Рекомендуется запуск от пользователя с sudo правами."
    elif ! sudo -n true 2>/dev/null; then
        log_error "Требуются sudo права для выполнения скрипта"
        exit 1
    fi
    
    # Проверка доступного места
    local available_space
    available_space=$(df /var/lib 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [[ "$available_space" -lt 2000000 ]]; then  # 2GB в KB
        log_warn "Недостаточно места на диске (< 2GB в /var/lib). Docker может работать нестабильно."
    fi
    
    log_info "Системные требования выполнены"
}

# === ФУНКЦИЯ: найти целевого пользователя ===
get_target_user() {
    local target_user=""
    
    # Если скрипт запущен не от root, используем текущего пользователя
    if [[ $EUID -ne 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        target_user="$SUDO_USER"
    else
        # Ищем последнего созданного обычного пользователя
        target_user=$(getent passwd \
            | awk -F: '$3>=1000 && $3<65534 && $1!="nobody" && $7 ~ /\/(bash|zsh|fish)$/ {users[$3]=$1} END {for(uid in users) print uid, users[uid]}' \
            | sort -n \
            | tail -n 1 \
            | cut -d' ' -f2)
    fi
    
    # Валидация пользователя
    if [[ -n "$target_user" ]] && id "$target_user" &>/dev/null; then
        echo "$target_user"
    else
        return 1
    fi
}

# === ФУНКЦИЯ: очистка при ошибке ===
cleanup_on_error() {
    local exit_code=$?
    log_error "Произошла ошибка. Код выхода: $exit_code"
    
    # Удаляем частично установленные файлы
    if [[ -f "$DOCKER_GPG_KEY.tmp" ]]; then
        sudo rm -f "$DOCKER_GPG_KEY.tmp"
    fi
    
    exit $exit_code
}

# === ФУНКЦИЯ: проверка Docker ===
check_docker_installed() {
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "unknown")
        log_info "Docker уже установлен: $docker_version"
        
        # Проверяем, нужно ли обновление
        if docker --version | grep -q "Docker version"; then
            return 0  # Docker установлен корректно
        fi
    fi
    return 1  # Docker не установлен или установлен некорректно
}

# === ФУНКЦИЯ: установка Docker ===
install_docker() {
    log_info "Начинаю установку Docker Engine..."
    
    # Удаляем старые версии
    log_info "Удаляю старые версии Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Обновляем систему
    log_info "Обновляю список пакетов..."
    sudo apt-get update -y
    
    # Устанавливаем зависимости
    log_info "Устанавливаю зависимости..."
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common
    
    # Создаем директорию для ключей
    sudo install -m 0755 -d /etc/apt/keyrings
    
    # Загружаем и устанавливаем GPG ключ
    log_info "Добавляю официальный GPG ключ Docker..."
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o "${DOCKER_GPG_KEY}.tmp"; then
        sudo mv "${DOCKER_GPG_KEY}.tmp" "$DOCKER_GPG_KEY"
        sudo chmod a+r "$DOCKER_GPG_KEY"
    else
        log_error "Не удалось загрузить GPG ключ Docker"
        exit 1
    fi
    
    # Добавляем репозиторий
    log_info "Добавляю репозиторий Docker..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_GPG_KEY] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" \
        | sudo tee "$DOCKER_REPO_FILE" > /dev/null
    
    # Обновляем список пакетов и устанавливаем Docker
    log_info "Устанавливаю Docker Engine и компоненты..."
    sudo apt-get update -y
    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    # Включаем и запускаем службу
    log_info "Включаю и запускаю службу Docker..."
    sudo systemctl enable docker
    sudo systemctl start docker
    
    # Проверяем статус службы
    if ! sudo systemctl is-active --quiet docker; then
        log_error "Служба Docker не запустилась"
        exit 1
    fi
    
    log_info "Docker Engine установлен успешно"
}

# === ФУНКЦИЯ: установка Docker Compose (standalone) ===
install_docker_compose_standalone() {
    log_info "Устанавливаю standalone версию Docker Compose..."
    
    # Получаем последнюю версию
    local compose_version
    if ! compose_version=$(curl -s --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/docker/compose/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"v?([^"]+)".*/\1/'); then
        log_error "Не удалось получить информацию о последней версии Docker Compose"
        exit 1
    fi
    
    if [[ -z "$compose_version" ]]; then
        log_error "Не удалось определить версию Docker Compose"
        exit 1
    fi
    
    log_info "Скачиваю Docker Compose версии $compose_version..."
    
    # Скачиваем бинарный файл
    local compose_url="https://github.com/docker/compose/releases/download/v${compose_version}/docker-compose-$(uname -s)-$(uname -m)"
    if sudo curl -L --connect-timeout 30 --max-time 300 "$compose_url" -o /usr/local/bin/docker-compose; then
        sudo chmod +x /usr/local/bin/docker-compose
        
        # Создаем симлинк для совместимости
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
        
        log_info "Docker Compose standalone установлен успешно"
    else
        log_error "Не удалось скачать Docker Compose"
        exit 1
    fi
}

# === ФУНКЦИЯ: настройка пользователя ===
configure_user() {
    local target_user
    if ! target_user=$(get_target_user); then
        log_warn "Не удалось определить целевого пользователя. Пропускаю добавление в группу docker."
        return 0
    fi
    
    log_info "Настраиваю права для пользователя $target_user..."
    
    # Создаем группу docker, если не существует
    if ! getent group docker &>/dev/null; then
        sudo groupadd docker
        log_info "Создана группа docker"
    fi
    
    # Добавляем пользователя в группу
    if ! groups "$target_user" | grep -qw docker; then
        sudo usermod -aG docker "$target_user"
        log_info "Пользователь $target_user добавлен в группу docker"
        log_warn "Для применения изменений выполните: newgrp docker или перезайдите в систему"
    else
        log_info "Пользователь $target_user уже состоит в группе docker"
    fi
    
    # Настраиваем права на сокет Docker (дополнительная безопасность)
    if [[ -S /var/run/docker.sock ]]; then
        sudo chown root:docker /var/run/docker.sock
        sudo chmod 660 /var/run/docker.sock
    fi
}

# === ФУНКЦИЯ: проверка установки ===
verify_installation() {
    log_info "Проверяю установку..."
    
    # Проверяем Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker не найден в PATH"
        exit 1
    fi
    
    local docker_version
    if ! docker_version=$(docker --version 2>/dev/null); then
        log_error "Не удалось получить версию Docker"
        exit 1
    fi
    log_info "Установлен: $docker_version"
    
    # Проверяем Docker Compose (plugin)
    if docker compose version &>/dev/null; then
        local compose_plugin_version
        compose_plugin_version=$(docker compose version --short 2>/dev/null || echo "неизвестно")
        log_info "Docker Compose Plugin: v$compose_plugin_version"
    fi
    
    # Проверяем Docker Compose (standalone)
    if command -v docker-compose &>/dev/null; then
        local compose_standalone_version
        compose_standalone_version=$(docker-compose --version 2>/dev/null || echo "ошибка")
        log_info "Docker Compose Standalone: $compose_standalone_version"
    fi
    
    # Тестируем Docker (если пользователь в группе docker)
    local target_user
    if target_user=$(get_target_user) && groups "$target_user" | grep -qw docker; then
        log_info "Тестирую Docker от имени пользователя $target_user..."
        if sudo -u "$target_user" docker run --rm hello-world &>/dev/null; then
            log_info "Тест Docker успешен"
        else
            log_warn "Тест Docker неуспешен. Возможно, требуется перезайти в систему."
        fi
    fi
}

# === ФУНКЦИЯ: настройка безопасности ===
configure_security() {
    log_info "Настраиваю параметры безопасности..."
    
    # Настраиваем логирование Docker
    local daemon_config="/etc/docker/daemon.json"
    if [[ ! -f "$daemon_config" ]]; then
        sudo mkdir -p /etc/docker
        cat << 'EOF' | sudo tee "$daemon_config" > /dev/null
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "live-restore": true,
    "userland-proxy": false,
    "no-new-privileges": true
}
EOF
        log_info "Создан файл конфигурации Docker daemon"
        
        # Перезапускаем Docker для применения настроек
        sudo systemctl restart docker
        
        # Ждем запуска службы
        sleep 5
        if ! sudo systemctl is-active --quiet docker; then
            log_error "Не удалось перезапустить Docker с новыми настройками"
            exit 1
        fi
    fi
}

# === ОСНОВНАЯ ФУНКЦИЯ ===
main() {
    # Настройка обработки сигналов
    trap cleanup_on_error ERR INT TERM
    
    log_info "=== Начало установки Docker и Docker Compose ==="
    log_info "Скрипт: $SCRIPT_NAME"
    log_info "Пользователь: $(whoami)"
    log_info "Система: $(lsb_release -d | cut -f2)"
    
    # Создаем лог-файл
    sudo touch "$LOG_FILE"
    sudo chmod 644 "$LOG_FILE"
    
    # Проверки системы
    check_system
    
    # Установка Docker (если не установлен)
    if ! check_docker_installed; then
        install_docker
        configure_security
    else
        log_info "Пропускаю установку Docker - уже установлен"
    fi
    
    # Установка standalone Docker Compose (дополнительно к plugin)
    install_docker_compose_standalone
    
    # Настройка пользователя
    configure_user
    
    # Проверка установки
    verify_installation
    
    log_info "=== Установка завершена успешно! ==="
    log_info "Лог сохранен в: $LOG_FILE"
    
    # Показываем информацию о следующих шагах
    cat << EOF

┌─────────────────────────────────────────────────────────────┐
│                    УСТАНОВКА ЗАВЕРШЕНА!                     │
├─────────────────────────────────────────────────────────────┤
│ Следующие шаги:                                             │
│                                                             │
│ 1. Для применения прав группы docker выполните:             │
│    newgrp docker                                            │
│    или перезайдите в систему                                │
│                                                             │
│ 2. Проверьте работу Docker:                                 │
│    docker run hello-world                                   │
│                                                             │
│ 3. Проверьте Docker Compose:                                │
│    docker compose version                                   │
│    docker-compose --version                                 │
│                                                             │
│ Лог установки: $LOG_FILE                       │
└─────────────────────────────────────────────────────────────┘

EOF
}

# Запуск основной функции
main "$@"
