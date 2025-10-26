#!/bin/bash

# N8N с Redis - БЕЗ PostgreSQL (упрощенная версия без heredoc проблем)

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

# Создание .env файла (построчно, без heredoc)
create_env_file() {
    print_status "Создание .env..."
    
    N8N_KEY=$(generate_encryption_key)
    
    # Создаем .env построчно
    echo "# N8N настройки" > .env
    echo "N8N_ENCRYPTION_KEY=$N8N_KEY" >> .env
    echo "EXECUTIONS_MODE=queue" >> .env
    echo "N8N_HOST=hook.autmatization-bot.ru" >> .env
    echo "N8N_PROTOCOL=https" >> .env
    echo "N8N_PORT=5678" >> .env
    echo "WEBHOOK_URL=https://hook.autmatization-bot.ru/" >> .env
    echo "" >> .env
    echo "# N8N Editor" >> .env
    echo "N8N_EDITOR_HOST=n8n.autmatization-bot.ru" >> .env
    echo "N8N_EDITOR_PROTOCOL=https" >> .env
    echo "" >> .env
    echo "# Redis" >> .env
    echo "QUEUE_BULL_REDIS_HOST=redis" >> .env
    echo "QUEUE_BULL_REDIS_PORT=6379" >> .env
    echo "QUEUE_BULL_REDIS_DB=0" >> .env
    echo "" >> .env
    echo "# N8N современные настройки" >> .env
    echo "N8N_RUNNERS_ENABLED=true" >> .env
    echo "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true" >> .env
    echo "N8N_BLOCK_ENV_ACCESS_IN_NODE=false" >> .env
    echo "N8N_GIT_NODE_DISABLE_BARE_REPOS=true" >> .env
    echo "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true" >> .env
    echo "" >> .env
    echo "# Общие настройки" >> .env
    echo "N8N_METRICS=true" >> .env
    echo "N8N_LOG_LEVEL=info" >> .env
    echo "GENERIC_TIMEZONE=Europe/Moscow" >> .env
    echo "QUEUE_HEALTH_CHECK_ACTIVE=true" >> .env
    echo "N8N_ENDPOINT_WEBHOOK=webhook" >> .env
    echo "N8N_ENDPOINT_WEBHOOK_TEST=webhook-test" >> .env
    
    print_success ".env создан"
    print_warning "Ключ шифрования: $N8N_KEY"
}

# Создание docker-compose.yml (через echo)
create_docker_compose() {
    print_status "Создание docker-compose.yml..."
    
    # Создаем файл построчно
    echo "services:" > docker-compose.yml
    echo "" >> docker-compose.yml
    
    # Redis
    echo "  redis:" >> docker-compose.yml
    echo "    image: redis:7-alpine" >> docker-compose.yml
    echo "    container_name: n8n_redis" >> docker-compose.yml
    echo "    restart: unless-stopped" >> docker-compose.yml
    echo "    command: redis-server --appendonly no --save \"\"" >> docker-compose.yml
    echo "    volumes:" >> docker-compose.yml
    echo "      - ./data/redis:/data" >> docker-compose.yml
    echo "    networks:" >> docker-compose.yml
    echo "      - n8n-internal" >> docker-compose.yml
    echo "    healthcheck:" >> docker-compose.yml
    echo "      test: [\"CMD\", \"redis-cli\", \"ping\"]" >> docker-compose.yml
    echo "      interval: 10s" >> docker-compose.yml
    echo "      timeout: 5s" >> docker-compose.yml
    echo "      retries: 5" >> docker-compose.yml
    echo "" >> docker-compose.yml
    
    # N8N Main
    echo "  n8n-main:" >> docker-compose.yml
    echo "    image: n8nio/n8n:latest" >> docker-compose.yml
    echo "    container_name: n8n_main" >> docker-compose.yml
    echo "    restart: unless-stopped" >> docker-compose.yml
    echo "    depends_on:" >> docker-compose.yml
    echo "      redis:" >> docker-compose.yml
    echo "        condition: service_healthy" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - N8N_HOST=\${N8N_HOST}" >> docker-compose.yml
    echo "      - N8N_PROTOCOL=\${N8N_PROTOCOL}" >> docker-compose.yml
    echo "      - N8N_PORT=\${N8N_PORT}" >> docker-compose.yml
    echo "      - WEBHOOK_URL=\${WEBHOOK_URL}" >> docker-compose.yml
    echo "      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}" >> docker-compose.yml
    echo "      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_DB=\${QUEUE_BULL_REDIS_DB}" >> docker-compose.yml
    echo "      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}" >> docker-compose.yml
    echo "      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=\${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}" >> docker-compose.yml
    echo "      - N8N_BLOCK_ENV_ACCESS_IN_NODE=\${N8N_BLOCK_ENV_ACCESS_IN_NODE}" >> docker-compose.yml
    echo "      - N8N_GIT_NODE_DISABLE_BARE_REPOS=\${N8N_GIT_NODE_DISABLE_BARE_REPOS}" >> docker-compose.yml
    echo "      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=\${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}" >> docker-compose.yml
    echo "      - N8N_METRICS=\${N8N_METRICS}" >> docker-compose.yml
    echo "      - N8N_LOG_LEVEL=\${N8N_LOG_LEVEL}" >> docker-compose.yml
    echo "      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}" >> docker-compose.yml
    echo "      - QUEUE_HEALTH_CHECK_ACTIVE=\${QUEUE_HEALTH_CHECK_ACTIVE}" >> docker-compose.yml
    echo "      - N8N_ENDPOINT_WEBHOOK=\${N8N_ENDPOINT_WEBHOOK}" >> docker-compose.yml
    echo "      - N8N_ENDPOINT_WEBHOOK_TEST=\${N8N_ENDPOINT_WEBHOOK_TEST}" >> docker-compose.yml
    echo "    volumes:" >> docker-compose.yml
    echo "      - ./data/n8n:/home/node/.n8n" >> docker-compose.yml
    echo "    networks:" >> docker-compose.yml
    echo "      - n8n-internal" >> docker-compose.yml
    echo "      - proxy" >> docker-compose.yml
    echo "      - backend" >> docker-compose.yml
    echo "    labels:" >> docker-compose.yml
    echo "      - \"traefik.enable=true\"" >> docker-compose.yml
    echo "      - \"traefik.docker.network=proxy\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-webhook.rule=Host(\\\`\${N8N_HOST}\\\`)\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-webhook.entrypoints=websecure\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-webhook.service=n8n-webhook\"" >> docker-compose.yml
    echo "      - \"traefik.http.services.n8n-webhook.loadbalancer.server.port=5678\"" >> docker-compose.yml
    echo "" >> docker-compose.yml
    
    # N8N Editor
    echo "  n8n-editor:" >> docker-compose.yml
    echo "    image: n8nio/n8n:latest" >> docker-compose.yml
    echo "    container_name: n8n_editor" >> docker-compose.yml
    echo "    restart: unless-stopped" >> docker-compose.yml
    echo "    depends_on:" >> docker-compose.yml
    echo "      redis:" >> docker-compose.yml
    echo "        condition: service_healthy" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - N8N_HOST=\${N8N_EDITOR_HOST}" >> docker-compose.yml
    echo "      - N8N_PROTOCOL=\${N8N_EDITOR_PROTOCOL}" >> docker-compose.yml
    echo "      - N8N_PORT=5678" >> docker-compose.yml
    echo "      - WEBHOOK_URL=\${WEBHOOK_URL}" >> docker-compose.yml
    echo "      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}" >> docker-compose.yml
    echo "      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_DB=\${QUEUE_BULL_REDIS_DB}" >> docker-compose.yml
    echo "      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}" >> docker-compose.yml
    echo "      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=\${OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS}" >> docker-compose.yml
    echo "      - N8N_BLOCK_ENV_ACCESS_IN_NODE=\${N8N_BLOCK_ENV_ACCESS_IN_NODE}" >> docker-compose.yml
    echo "      - N8N_GIT_NODE_DISABLE_BARE_REPOS=\${N8N_GIT_NODE_DISABLE_BARE_REPOS}" >> docker-compose.yml
    echo "      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=\${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}" >> docker-compose.yml
    echo "      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true" >> docker-compose.yml
    echo "      - N8N_METRICS=\${N8N_METRICS}" >> docker-compose.yml
    echo "      - N8N_LOG_LEVEL=\${N8N_LOG_LEVEL}" >> docker-compose.yml
    echo "      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}" >> docker-compose.yml
    echo "      - QUEUE_HEALTH_CHECK_ACTIVE=\${QUEUE_HEALTH_CHECK_ACTIVE}" >> docker-compose.yml
    echo "    volumes:" >> docker-compose.yml
    echo "      - ./data/n8n:/home/node/.n8n" >> docker-compose.yml
    echo "    networks:" >> docker-compose.yml
    echo "      - n8n-internal" >> docker-compose.yml
    echo "      - proxy" >> docker-compose.yml
    echo "      - backend" >> docker-compose.yml
    echo "    labels:" >> docker-compose.yml
    echo "      - \"traefik.enable=true\"" >> docker-compose.yml
    echo "      - \"traefik.docker.network=proxy\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-editor.rule=Host(\\\`\${N8N_EDITOR_HOST}\\\`)\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-editor.entrypoints=websecure\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt\"" >> docker-compose.yml
    echo "      - \"traefik.http.routers.n8n-editor.service=n8n-editor\"" >> docker-compose.yml
    echo "      - \"traefik.http.services.n8n-editor.loadbalancer.server.port=5678\"" >> docker-compose.yml
    echo "" >> docker-compose.yml
    
    # N8N Worker
    echo "  n8n-worker:" >> docker-compose.yml
    echo "    image: n8nio/n8n:latest" >> docker-compose.yml
    echo "    restart: unless-stopped" >> docker-compose.yml
    echo "    depends_on:" >> docker-compose.yml
    echo "      redis:" >> docker-compose.yml
    echo "        condition: service_healthy" >> docker-compose.yml
    echo "    command: [\"worker\", \"--concurrency=10\"]" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}" >> docker-compose.yml
    echo "      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT}" >> docker-compose.yml
    echo "      - QUEUE_BULL_REDIS_DB=\${QUEUE_BULL_REDIS_DB}" >> docker-compose.yml
    echo "      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}" >> docker-compose.yml
    echo "      - N8N_BLOCK_ENV_ACCESS_IN_NODE=\${N8N_BLOCK_ENV_ACCESS_IN_NODE}" >> docker-compose.yml
    echo "      - N8N_GIT_NODE_DISABLE_BARE_REPOS=\${N8N_GIT_NODE_DISABLE_BARE_REPOS}" >> docker-compose.yml
    echo "      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=\${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}" >> docker-compose.yml
    echo "      - N8N_LOG_LEVEL=\${N8N_LOG_LEVEL}" >> docker-compose.yml
    echo "      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}" >> docker-compose.yml
    echo "      - QUEUE_HEALTH_CHECK_ACTIVE=\${QUEUE_HEALTH_CHECK_ACTIVE}" >> docker-compose.yml
    echo "    volumes:" >> docker-compose.yml
    echo "      - ./data/n8n:/home/node/.n8n" >> docker-compose.yml
    echo "    networks:" >> docker-compose.yml
    echo "      - n8n-internal" >> docker-compose.yml
    echo "      - backend" >> docker-compose.yml
    echo "    deploy:" >> docker-compose.yml
    echo "      replicas: 2" >> docker-compose.yml
    echo "" >> docker-compose.yml
    
    # Сети
    echo "networks:" >> docker-compose.yml
    echo "  n8n-internal:" >> docker-compose.yml
    echo "    driver: bridge" >> docker-compose.yml
    echo "  proxy:" >> docker-compose.yml
    echo "    external: true" >> docker-compose.yml
    echo "    name: proxy" >> docker-compose.yml
    echo "  backend:" >> docker-compose.yml
    echo "    external: true" >> docker-compose.yml
    echo "    name: backend" >> docker-compose.yml
    echo "" >> docker-compose.yml
    echo "volumes:" >> docker-compose.yml
    echo "  redis_data:" >> docker-compose.yml
    echo "  n8n_data:" >> docker-compose.yml
    
    print_success "docker-compose.yml создан"
}

# Создание manage.sh
create_management_script() {
    print_status "Создание manage.sh..."
    
    echo "#!/bin/bash" > manage.sh
    echo "" >> manage.sh
    echo "RED='\\033[0;31m'" >> manage.sh
    echo "GREEN='\\033[0;32m'" >> manage.sh
    echo "BLUE='\\033[0;34m'" >> manage.sh
    echo "NC='\\033[0m'" >> manage.sh
    echo "" >> manage.sh
    echo "print_status() { echo -e \"\${BLUE}[INFO]\${NC} \$1\"; }" >> manage.sh
    echo "print_success() { echo -e \"\${GREEN}[SUCCESS]\${NC} \$1\"; }" >> manage.sh
    echo "" >> manage.sh
    echo "case \"\$1\" in" >> manage.sh
    echo "    start)" >> manage.sh
    echo "        print_status \"Запуск N8N...\"" >> manage.sh
    echo "        docker compose up -d" >> manage.sh
    echo "        print_success \"N8N запущен\"" >> manage.sh
    echo "        echo \"Webhook: https://hook.autmatization-bot.ru/\"" >> manage.sh
    echo "        echo \"Editor: https://n8n.autmatization-bot.ru/\"" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "    stop)" >> manage.sh
    echo "        print_status \"Остановка N8N...\"" >> manage.sh
    echo "        docker compose down" >> manage.sh
    echo "        print_success \"N8N остановлен\"" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "    logs)" >> manage.sh
    echo "        docker compose logs -f --tail=100" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "    status)" >> manage.sh
    echo "        docker compose ps" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "    mariadb-test)" >> manage.sh
    echo "        if docker ps --filter \"name=wp-db\" | grep -q wp-db; then" >> manage.sh
    echo "            print_success \"MariaDB (wp-db) найден\"" >> manage.sh
    echo "        else" >> manage.sh
    echo "            echo \"MariaDB (wp-db) не найден\"" >> manage.sh
    echo "        fi" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "    *)" >> manage.sh
    echo "        echo \"Команды: start, stop, logs, status, mariadb-test\"" >> manage.sh
    echo "        ;;" >> manage.sh
    echo "esac" >> manage.sh
    
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
