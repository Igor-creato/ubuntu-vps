#!/bin/bash

# N8N с Redis - ИСПРАВЛЕННАЯ ВЕРСИЯ без экранирования в YAML

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка зависимостей
check_dependencies() {
    print_status "Проверка зависимостей..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен"
        exit 1
    fi
    
    print_success "Docker найден"
}

# Проверка сетей
check_networks() {
    print_status "Проверка сетей..."
    
    for network in proxy backend; do
        if ! docker network ls | grep -q "$network"; then
            print_warning "Создание сети $network..."
            docker network create "$network" || true
        fi
    done
    
    print_success "Сети готовы"
}

# Генерация ключей
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

generate_encryption_key() {
    openssl rand -base64 32
}

# Создание папок
create_directories() {
    print_status "Создание папок..."
    
    mkdir -p hook
    cd hook
    mkdir -p data/n8n data/redis
    
    print_success "Папки созданы в $(pwd)"
}

# Создание .env файла
create_env_file() {
    print_status "Создание .env..."
    
    N8N_KEY=$(generate_encryption_key)
    
    cat > .env << 'ENVFILE'
# N8N настройки
N8N_ENCRYPTION_KEY=REPLACE_KEY_HERE
EXECUTIONS_MODE=queue
N8N_HOST=hook.autmatization-bot.ru
N8N_PROTOCOL=https
N8N_PORT=5678
WEBHOOK_URL=https://hook.autmatization-bot.ru/

# N8N Editor
N8N_EDITOR_HOST=n8n.autmatization-bot.ru
N8N_EDITOR_PROTOCOL=https

# Redis
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0

# N8N современные настройки
N8N_RUNNERS_ENABLED=true
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=false
N8N_GIT_NODE_DISABLE_BARE_REPOS=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Общие настройки
N8N_METRICS=true
N8N_LOG_LEVEL=info
GENERIC_TIMEZONE=Europe/Moscow
QUEUE_HEALTH_CHECK_ACTIVE=true
N8N_ENDPOINT_WEBHOOK=webhook
N8N_ENDPOINT_WEBHOOK_TEST=webhook-test
ENVFILE

    # Заменяем placeholder на реальный ключ
    sed -i "s/REPLACE_KEY_HERE/$N8N_KEY/" .env
    
    print_success ".env создан"
    print_warning "Ключ шифрования: $N8N_KEY"
}

# Создание docker-compose.yml БЕЗ проблемного экранирования
create_docker_compose() {
    print_status "Создание docker-compose.yml..."
    
    cat > docker-compose.yml << 'YAMLFILE'
services:

  redis:
    image: redis:7-alpine
    container_name: n8n_redis
    restart: unless-stopped
    command: redis-server --appendonly no --save ""
    volumes:
      - ./data/redis:/data
    networks:
      - n8n-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n-main:
    image: n8nio/n8n:latest
    container_name: n8n_main
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - N8N_PORT=${N8N_PORT}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_METRICS=${N8N_METRICS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_ENDPOINT_WEBHOOK=${N8N_ENDPOINT_WEBHOOK}
      - N8N_ENDPOINT_WEBHOOK_TEST=${N8N_ENDPOINT_WEBHOOK_TEST}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
      - backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-webhook.rule=Host(`${N8N_HOST}`)
      - traefik.http.routers.n8n-webhook.entrypoints=websecure
      - traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt
      - traefik.http.routers.n8n-webhook.service=n8n-webhook
      - traefik.http.services.n8n-webhook.loadbalancer.server.port=5678

  n8n-editor:
    image: n8nio/n8n:latest
    container_name: n8n_editor
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_EDITOR_HOST}
      - N8N_PROTOCOL=${N8N_EDITOR_PROTOCOL}
      - N8N_PORT=5678
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true
      - N8N_METRICS=${N8N_METRICS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
      - backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-editor.rule=Host(`${N8N_EDITOR_HOST}`)
      - traefik.http.routers.n8n-editor.entrypoints=websecure
      - traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt
      - traefik.http.routers.n8n-editor.service=n8n-editor
      - traefik.http.services.n8n-editor.loadbalancer.server.port=5678

  n8n-worker:
    image: n8nio/n8n:latest
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=10"]
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
      - QUEUE_BULL_REDIS_DB=${QUEUE_BULL_REDIS_DB}
      - N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=${N8N_BLOCK_ENV_ACCESS_IN_NODE}
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=${N8N_GIT_NODE_DISABLE_BARE_REPOS}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - backend
    deploy:
      replicas: 2

networks:
  n8n-internal:
    driver: bridge
  proxy:
    external: true
    name: proxy
  backend:
    external: true
    name: backend

volumes:
  redis_data:
  n8n_data:
YAMLFILE
    
    print_success "docker-compose.yml создан"
}

# Создание manage.sh
create_management_script() {
    print_status "Создание manage.sh..."
    
    cat > manage.sh << 'MANAGEFILE'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

case "$1" in
    start)
        print_status "Запуск N8N..."
        docker compose up -d
        print_success "N8N запущен"
        echo "Webhook: https://hook.autmatization-bot.ru/"
        echo "Editor: https://n8n.autmatization-bot.ru/"
        ;;
    stop)
        print_status "Остановка N8N..."
        docker compose down
        print_success "N8N остановлен"
        ;;
    logs)
        docker compose logs -f --tail=100
        ;;
    status)
        docker compose ps
        ;;
    mariadb-test)
        if docker ps --filter "name=wp-db" | grep -q wp-db; then
            print_success "MariaDB (wp-db) найден"
        else
            echo "MariaDB (wp-db) не найден"
        fi
        ;;
    *)
        echo "Команды: start, stop, logs, status, mariadb-test"
        ;;
esac
MANAGEFILE
    
    chmod +x manage.sh
    print_success "manage.sh создан"
}

# Исправление прав
fix_permissions() {
    print_status "Исправление прав..."
    chown -R 1000:1000 ./data/n8n 2>/dev/null || sudo chown -R 1000:1000 ./data/n8n 2>/dev/null || true
    chmod -R 755 ./data/n8n 2>/dev/null || sudo chmod -R 755 ./data/n8n 2>/dev/null || true
    print_success "Права исправлены"
}

# Основная функция
main() {
    print_status "=== N8N установка без PostgreSQL ==="
    
    check_dependencies
    check_networks
    create_directories
    create_env_file
    create_docker_compose
    create_management_script
    fix_permissions
    
    print_success "Установка завершена!"
    echo ""
    print_status "Команды управления:"
    print_status "  ./manage.sh start    - Запуск"
    print_status "  ./manage.sh stop     - Остановка"  
    print_status "  ./manage.sh logs     - Логи"
    print_status "  ./manage.sh status   - Статус"
    echo ""
    
    read -p "Запустить N8N сейчас? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Запуск..."
        docker compose up -d
        print_success "N8N запущен!"
        echo ""
        echo "🔗 Webhook: https://hook.autmatization-bot.ru/"
        echo "✏️  Editor: https://n8n.autmatization-bot.ru/"
        echo ""
        print_status "Для MariaDB используйте host: wp-db"
    fi
}

# Запуск
main "$@"
