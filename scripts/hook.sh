#!/bin/bash

# Скрипт для создания и запуска N8N с Redis в режиме очереди через Traefik
# Настроен для работы с сетью proxy - ИСПРАВЛЕННАЯ ВЕРСИЯ

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода цветного текста
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка зависимостей
check_dependencies() {
    print_status "Проверка зависимостей..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен. Установите Docker и попробуйте снова."
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
        print_error "Docker Compose не установлен. Установите Docker Compose и попробуйте снова."
        exit 1
    fi
    
    print_success "Все зависимости установлены"
}

# Проверка сети proxy
check_proxy_network() {
    print_status "Проверка сети proxy..."
    
    if ! docker network ls | grep -q "proxy"; then
        print_warning "Сеть 'proxy' не найдена. Создание сети..."
        docker network create proxy
        print_success "Сеть 'proxy' создана"
    else
        print_success "Сеть 'proxy' уже существует"
    fi
}

# Настройка системных параметров Redis
configure_redis_sysctl() {
    print_status "Настройка системных параметров для Redis..."
    
    # Проверка и настройка vm.overcommit_memory
    current_overcommit=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "0")
    if [ "$current_overcommit" != "1" ]; then
        print_warning "Настройка vm.overcommit_memory для Redis..."
        if command -v sudo &> /dev/null; then
            sudo sysctl vm.overcommit_memory=1
            echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf >/dev/null
        else
            sysctl vm.overcommit_memory=1 2>/dev/null || print_warning "Не удалось настроить vm.overcommit_memory"
        fi
        print_success "Системные параметры Redis настроены"
    else
        print_success "Системные параметры Redis уже настроены"
    fi
}

# Генерация безопасного пароля
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Генерация ключа шифрования
generate_encryption_key() {
    openssl rand -base64 32
}

# Создание структуры папок
create_directories() {
    print_status "Создание структуры папок..."
    
    # Создаем основную папку hook
    mkdir -p hook
    cd hook
    
    # Создаем папки для данных
    mkdir -p data/n8n
    mkdir -p data/postgres
    mkdir -p data/redis
    
    print_success "Структура папок создана в $(pwd)"
}

# Создание .env файла с исправленными параметрами
create_env_file() {
    print_status "Создание файла конфигурации .env..."
    
    # Генерируем пароли и ключи
    POSTGRES_PASSWORD=$(generate_password)
    N8N_ENCRYPTION_KEY=$(generate_encryption_key)
    
    cat > .env << EOF
# PostgreSQL настройки
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# N8N настройки
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
EXECUTIONS_MODE=queue
N8N_HOST=hook.autmatization-bot.ru
N8N_PROTOCOL=https
N8N_PORT=5678
WEBHOOK_URL=https://hook.autmatization-bot.ru/

# N8N Editor настройки (второй экземпляр)
N8N_EDITOR_HOST=n8n.autmatization-bot.ru
N8N_EDITOR_PROTOCOL=https
N8N_EDITOR_PORT=5679

# База данных настройки
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD

# Redis настройки
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0

# N8N Современные настройки (устраняют warnings)
N8N_RUNNERS_ENABLED=true
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=false
N8N_GIT_NODE_DISABLE_BARE_REPOS=true

# Дополнительные настройки N8N
N8N_METRICS=true
N8N_LOG_LEVEL=info
N8N_GRACEFUL_SHUTDOWN_TIMEOUT=30
QUEUE_HEALTH_CHECK_ACTIVE=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Таймзона
GENERIC_TIMEZONE=Europe/Moscow

# Настройки для обработки webhook
N8N_DISABLE_PRODUCTION_MAIN_PROCESS=false
N8N_ENDPOINT_WEBHOOK=webhook
N8N_ENDPOINT_WEBHOOK_TEST=webhook-test
EOF

    print_success "Файл .env создан с уникальными паролями и ключами"
    print_warning "Сохраните пароли в безопасном месте:"
    print_warning "PostgreSQL пароль: $POSTGRES_PASSWORD"
    print_warning "N8N ключ шифрования: $N8N_ENCRYPTION_KEY"
}

# Создание исправленного docker-compose.yml
create_docker_compose() {
    print_status "Создание исправленного docker-compose.yml..."
    
    cat > docker-compose.yml << 'EOF'
# Удалена устаревшая строка version (Docker Compose v2+)
services:
  # PostgreSQL база данных
  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - n8n-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis для очередей с исправленными настройками
  redis:
    image: redis:7-alpine
    container_name: n8n_redis
    restart: unless-stopped
    command: redis-server --appendonly no --save ""
    volumes:
      - ./data/redis:/data
    networks:
      - n8n-internal
    sysctls:
      - net.core.somaxconn=1024
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # N8N основной экземпляр (webhook processor)
  n8n-main:
    image: n8nio/n8n:latest
    container_name: n8n_main
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - N8N_PORT=${N8N_PORT}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_METRICS=${N8N_METRICS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_ENDPOINT_WEBHOOK=${N8N_ENDPOINT_WEBHOOK}
      - N8N_ENDPOINT_WEBHOOK_TEST=${N8N_ENDPOINT_WEBHOOK_TEST}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n-webhook.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n-webhook.entrypoints=websecure"
      - "traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-webhook.service=n8n-webhook"
      - "traefik.http.services.n8n-webhook.loadbalancer.server.port=5678"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Editor экземпляр (исправлен host)
  n8n-editor:
    image: n8nio/n8n:latest
    container_name: n8n_editor
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_EDITOR_HOST}
      - N8N_PROTOCOL=${N8N_EDITOR_PROTOCOL}
      - N8N_PORT=5678
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_METRICS=${N8N_METRICS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n-editor.rule=Host(`${N8N_EDITOR_HOST}`)"
      - "traefik.http.routers.n8n-editor.entrypoints=websecure"
      - "traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-editor.service=n8n-editor"
      - "traefik.http.services.n8n-editor.loadbalancer.server.port=5678"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Worker 1
  n8n-worker-1:
    image: n8nio/n8n:latest
    container_name: n8n_worker_1
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=5"]
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=${N8N_GRACEFUL_SHUTDOWN_TIMEOUT}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
    healthcheck:
      test: ["CMD-SHELL", "ps aux | grep -v grep | grep worker || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Worker 2
  n8n-worker-2:
    image: n8nio/n8n:latest
    container_name: n8n_worker_2
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=5"]
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=${N8N_GRACEFUL_SHUTDOWN_TIMEOUT}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
    healthcheck:
      test: ["CMD-SHELL", "ps aux | grep -v grep | grep worker || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  n8n-internal:
    driver: bridge
  proxy:
    external: true
    name: proxy

volumes:
  postgres_data:
  redis_data:
  n8n_data:
EOF

    print_success "docker-compose.yml создан без deprecated параметров"
}

# Создание скрипта для управления с дополнительными командами
create_management_script() {
    print_status "Создание расширенного скрипта управления..."
    
    cat > manage.sh << 'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    echo "Использование: $0 [КОМАНДА]"
    echo ""
    echo "Команды:"
    echo "  start         Запустить все сервисы"
    echo "  stop          Остановить все сервисы"
    echo "  restart       Перезапустить все сервисы"
    echo "  logs          Показать логи всех сервисов"
    echo "  status        Показать статус сервисов"
    echo "  fix-perms     Исправить права доступа N8N"
    echo "  clean-db      Очистить базу данных (ОСТОРОЖНО!)"
    echo "  backup        Создать резервную копию"
    echo "  help          Показать эту справку"
}

fix_permissions() {
    print_status "Исправление прав доступа к файлам N8N..."
    
    if command -v sudo &> /dev/null; then
        sudo chown -R 1000:1000 ./data/n8n 2>/dev/null || chown -R 1000:1000 ./data/n8n
        sudo chmod -R 755 ./data/n8n 2>/dev/null || chmod -R 755 ./data/n8n
    else
        chown -R 1000:1000 ./data/n8n
        chmod -R 755 ./data/n8n
    fi
    
    if [ -f "./data/n8n/config" ]; then
        if command -v sudo &> /dev/null; then
            sudo chmod 600 ./data/n8n/config 2>/dev/null || chmod 600 ./data/n8n/config
        else
            chmod 600 ./data/n8n/config
        fi
        print_success "Права доступа к файлу конфигурации исправлены"
    fi
    
    print_success "Права доступа исправлены"
}

clean_database() {
    read -p "Вы уверены, что хотите очистить базу данных? (yes/no): " -r
    if [[ $REPLY =~ ^yes$ ]]; then
        print_warning "Остановка сервисов..."
        docker compose down
        print_warning "Очистка базы данных..."
        sudo rm -rf ./data/postgres/*
        sudo rm -rf ./data/n8n/database.sqlite
        print_success "База данных очищена"
        print_status "Запустите 'start' для пересоздания базы"
    else
        print_status "Операция отменена"
    fi
}

backup_data() {
    print_status "Создание резервной копии данных..."
    BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    docker compose exec postgres pg_dump -U n8n n8n > "$BACKUP_DIR/database.sql" 2>/dev/null || print_warning "Не удалось создать дамп базы данных"
    cp -r data "$BACKUP_DIR/" 2>/dev/null || print_warning "Не удалось скопировать файлы данных"
    cp .env "$BACKUP_DIR/" 2>/dev/null || print_warning "Не удалось скопировать .env"
    
    print_success "Резервная копия создана в $BACKUP_DIR"
}

start_services() {
    print_status "Проверка сети proxy..."
    if ! docker network ls | grep -q "proxy"; then
        print_warning "Создание сети proxy..."
        docker network create proxy
    fi
    
    print_status "Запуск сервисов N8N..."
    if docker compose up -d; then
        print_success "Сервисы запущены"
        echo ""
        print_status "Доступ к сервисам:"
        print_status "  - Webhook endpoint: https://hook.autmatization-bot.ru/"
        print_status "  - Editor interface: https://n8n.autmatization-bot.ru/"
    else
        print_error "Ошибка запуска сервисов"
        exit 1
    fi
}

case "$1" in
    start)
        start_services
        ;;
    stop)
        docker compose down
        print_success "Сервисы остановлены"
        ;;
    restart)
        docker compose restart
        print_success "Сервисы перезапущены"
        ;;
    logs)
        docker compose logs -f --tail=100
        ;;
    status)
        docker compose ps
        ;;
    fix-perms)
        fix_permissions
        ;;
    clean-db)
        clean_database
        ;;
    backup)
        backup_data
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        print_error "Неизвестная команда: $1"
        show_help
        exit 1
        ;;
esac
EOF

    chmod +x manage.sh
    print_success "Расширенный скрипт управления создан (manage.sh)"
}

# Исправление прав доступа к файлам N8N
fix_n8n_permissions() {
    print_status "Исправление прав доступа к файлам N8N..."
    
    if command -v sudo &> /dev/null; then
        sudo chown -R 1000:1000 ./data/n8n 2>/dev/null || chown -R 1000:1000 ./data/n8n
        sudo chmod -R 755 ./data/n8n 2>/dev/null || chmod -R 755 ./data/n8n
    else
        chown -R 1000:1000 ./data/n8n
        chmod -R 755 ./data/n8n
    fi
    
    if [ -f "./data/n8n/config" ]; then
        if command -v sudo &> /dev/null; then
            sudo chmod 600 ./data/n8n/config 2>/dev/null || chmod 600 ./data/n8n/config
        else
            chmod 600 ./data/n8n/config
        fi
        print_success "Права доступа к файлу конфигурации исправлены"
    fi
    
    print_success "Права доступа исправлены"
}

# Запуск сервисов
start_services() {
    print_status "Запуск сервисов N8N..."
    if docker compose up -d; then
        print_success "Сервисы запущены успешно!"
        echo ""
        print_status "Доступ к сервисам:"
        print_status "  - Webhook endpoint: https://hook.autmatization-bot.ru/"
        print_status "  - Editor interface: https://n8n.autmatization-bot.ru/"
        echo ""
        print_status "Мониторинг сервисов:"
        print_status "  - Статус: ./manage.sh status"
        print_status "  - Логи: ./manage.sh logs"
        print_status "  - Очистка БД при ошибках миграции: ./manage.sh clean-db"
    else
        print_error "Ошибка при запуске сервисов"
        exit 1
    fi
}

# Основная функция
main() {
    print_status "Установка N8N с Redis в режиме очереди для сети proxy - ИСПРАВЛЕННАЯ ВЕРСИЯ"
    echo ""
    
    check_dependencies
    check_proxy_network
    configure_redis_sysctl
    create_directories
    create_env_file
    create_docker_compose
    create_management_script
    fix_n8n_permissions
    
    echo ""
    print_success "Установка завершена!"
    echo ""
    print_status "Исправления в этой версии:"
    print_status "  ✓ Удален устаревший параметр 'version' из docker-compose.yml"
    print_status "  ✓ Настроен vm.overcommit_memory для Redis"
    print_status "  ✓ Добавлены современные переменные N8N (убирают warnings)"
    print_status "  ✓ Исправлена конфигурация N8N Editor"
    print_status "  ✓ Добавлена команда для очистки БД при ошибках миграции"
    echo ""
    print_status "Структура проекта создана в папке: $(pwd)"
    echo ""
    
    read -p "Запустить сервисы сейчас? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        start_services
    else
        print_status "Сервисы не запущены. Команды для управления:"
        print_status "  ./manage.sh start     # Запуск сервисов"
        print_status "  ./manage.sh clean-db  # Очистка БД при ошибках"
        print_status "  ./manage.sh help      # Все команды"
    fi
}

# Запуск основной функции
main "$@"
