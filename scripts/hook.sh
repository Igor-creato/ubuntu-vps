#!/bin/bash

# Скрипт для создания и запуска N8N с Redis в режиме очереди через Traefik
# Настроен для работы с сетью proxy

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

# Создание .env файла
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

# Дополнительные настройки N8N
N8N_METRICS=true
N8N_LOG_LEVEL=info
N8N_GRACEFUL_SHUTDOWN_TIMEOUT=30
QUEUE_HEALTH_CHECK_ACTIVE=true

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

# Создание docker-compose.yml для работы с сетью proxy
create_docker_compose() {
    print_status "Создание docker-compose.yml для сети proxy..."
    
    cat > docker-compose.yml << 'EOF'
version: '3.9'

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

  # Redis для очередей
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
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      
      # Webhook роутер (hook.autmatization-bot.ru)
      - "traefik.http.routers.n8n-webhook.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n-webhook.entrypoints=websecure"
      - "traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-webhook.service=n8n-webhook"
      - "traefik.http.services.n8n-webhook.loadbalancer.server.port=5678"
      
      # Middleware для webhook
      - "traefik.http.routers.n8n-webhook.middlewares=n8n-webhook-headers"
      - "traefik.http.middlewares.n8n-webhook-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.n8n-webhook-headers.headers.customrequestheaders.X-Forwarded-Host=${N8N_HOST}"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Editor экземпляр (отдельный домен для редактора)
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
      - N8N_METRICS=${N8N_METRICS}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      
      # Editor роутер (n8n.autmatization-bot.ru)
      - "traefik.http.routers.n8n-editor.rule=Host(\`${N8N_EDITOR_HOST}\`)"
      - "traefik.http.routers.n8n-editor.entrypoints=websecure"
      - "traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-editor.service=n8n-editor"
      - "traefik.http.services.n8n-editor.loadbalancer.server.port=5678"
      
      # Middleware для editor
      - "traefik.http.routers.n8n-editor.middlewares=n8n-editor-headers"
      - "traefik.http.middlewares.n8n-editor-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.n8n-editor-headers.headers.customrequestheaders.X-Forwarded-Host=${N8N_EDITOR_HOST}"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Workers (обработка задач из очереди Redis)
  n8n-worker:
    image: n8nio/n8n:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: n8n worker --concurrency=5
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
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - QUEUE_HEALTH_CHECK_ACTIVE=${QUEUE_HEALTH_CHECK_ACTIVE}
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=${N8N_GRACEFUL_SHUTDOWN_TIMEOUT}
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
    deploy:
      replicas: 2
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  # Внутренняя сеть для связи между сервисами N8N, PostgreSQL и Redis
  n8n-internal:
    driver: bridge
    internal: false
  
  # Внешняя сеть для Traefik
  proxy:
    external: true
    name: proxy

volumes:
  postgres_data:
  redis_data:
  n8n_data:
EOF

    print_success "docker-compose.yml создан для сети proxy"
}

# Создание скрипта для управления
create_management_script() {
    print_status "Создание скрипта управления..."
    
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
    echo "  logs-main     Показать логи основного N8N"
    echo "  logs-editor   Показать логи редактора N8N"
    echo "  logs-worker   Показать логи worker'ов"
    echo "  logs-redis    Показать логи Redis"
    echo "  logs-db       Показать логи PostgreSQL"
    echo "  status        Показать статус сервисов"
    echo "  scale [N]     Масштабировать worker'ы до N экземпляров"
    echo "  network       Показать информацию о сетях"
    echo "  help          Показать эту справку"
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
        echo ""
        print_status "Проверьте статус: ./manage.sh status"
    else
        print_error "Ошибка запуска сервисов"
        exit 1
    fi
}

show_network_info() {
    print_status "Информация о сетях:"
    echo ""
    print_status "Сеть proxy:"
    docker network inspect proxy 2>/dev/null | grep -A 10 "Containers" || print_warning "Сеть proxy не найдена"
    echo ""
    print_status "Внутренняя сеть N8N:"
    docker network inspect hook_n8n-internal 2>/dev/null | grep -A 10 "Containers" || print_warning "Внутренняя сеть N8N не найдена"
}

scale_workers() {
    if [ -z "$1" ]; then
        print_error "Укажите количество worker'ов"
        exit 1
    fi
    
    print_status "Масштабирование worker'ов до $1 экземпляров..."
    docker compose up -d --scale n8n-worker="$1"
    print_success "Worker'ы масштабированы до $1 экземпляров"
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
    logs-main)
        docker compose logs -f --tail=100 n8n-main
        ;;
    logs-editor)
        docker compose logs -f --tail=100 n8n-editor
        ;;
    logs-worker)
        docker compose logs -f --tail=100 n8n-worker
        ;;
    logs-redis)
        docker compose logs -f --tail=100 redis
        ;;
    logs-db)
        docker compose logs -f --tail=100 postgres
        ;;
    status)
        print_status "Статус сервисов:"
        docker compose ps
        echo ""
        print_status "Использование ресурсов:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
        ;;
    scale)
        scale_workers "$2"
        ;;
    network)
        show_network_info
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
    print_success "Скрипт управления создан (manage.sh)"
}

# Основная функция
main() {
    print_status "Установка N8N с Redis в режиме очереди для сети proxy"
    echo ""
    
    check_dependencies
    check_proxy_network
    create_directories
    create_env_file
    create_docker_compose
    create_management_script
    
    echo ""
    print_success "Установка завершена!"
    echo ""
    print_status "Структура проекта создана в папке: $(pwd)"
    echo ""
    
    read -p "Запустить сервисы сейчас? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        # Запуск сервисов
        print_status "Запуск сервисов N8N..."
        if docker compose up -d; then
            print_success "Сервисы запущены успешно!"
            echo ""
            print_status "Доступ к сервисам:"
            print_status "  - Webhook endpoint: https://hook.autmatization-bot.ru/"
            print_status "  - Editor interface: https://n8n.autmatization-bot.ru/"
            echo ""
            print_status "Проверьте статус сервисов: ./manage.sh status"
            print_status "Просмотр логов: ./manage.sh logs"
        else
            print_error "Ошибка при запуске сервисов"
            exit 1
        fi
    else
        print_status "Сервисы не запущены. Используйте './manage.sh start' для запуска."
    fi
}

# Запуск основной функции
main "$@"
