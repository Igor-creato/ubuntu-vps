#!/bin/bash

# Скрипт для создания и запуска N8N с Redis в режиме очереди через Traefik
# Создает структуру папок, конфигурационные файлы и запускает контейнеры

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

# Создание docker-compose.yml
create_docker_compose() {
    print_status "Создание docker-compose.yml..."
    
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
      - n8n-network
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
      - n8n-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # N8N основной экземпляр (webhook processor + editor)
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
      - n8n-network
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik"
      - "traefik.http.routers.n8n-webhook.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n-webhook.entrypoints=websecure"
      - "traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-webhook.service=n8n-webhook"
      - "traefik.http.services.n8n-webhook.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n-webhook.middlewares=n8n-headers"
      - "traefik.http.middlewares.n8n-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.n8n-headers.headers.customrequestheaders.X-Forwarded-Host=${N8N_HOST}"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Editor экземпляр
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
      - n8n-network
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik"
      - "traefik.http.routers.n8n-editor.rule=Host(\`${N8N_EDITOR_HOST}\`)"
      - "traefik.http.routers.n8n-editor.entrypoints=websecure"
      - "traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n-editor.service=n8n-editor"
      - "traefik.http.services.n8n-editor.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n-editor.middlewares=n8n-editor-headers"
      - "traefik.http.middlewares.n8n-editor-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.n8n-editor-headers.headers.customrequestheaders.X-Forwarded-Host=${N8N_EDITOR_HOST}"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  # N8N Workers
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
      - n8n-network
    scale: 2
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  n8n-network:
    driver: bridge
  traefik:
    external: true

volumes:
  postgres_data:
  redis_data:
  n8n_data:
EOF

    print_success "docker-compose.yml создан"
}


# Создание скрипта для управления
create_management_script() {
    print_status "Создание скрипта управления..."
    
    cat > manage.sh << 'EOF'
#!/bin/bash

# Скрипт для управления N8N с Redis

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
    echo "  logs-worker   Показать логи worker'ов"
    echo "  logs-redis    Показать логи Redis"
    echo "  logs-db       Показать логи PostgreSQL"
    echo "  status        Показать статус сервисов"
    echo "  scale [N]     Масштабировать worker'ы до N экземпляров"
    echo "  shell-main    Войти в shell основного N8N"
    echo "  shell-worker  Войти в shell worker'а"
    echo "  backup        Создать резервную копию данных"
    echo "  update        Обновить образы и перезапустить"
    echo "  clean         Очистить все данные (ОСТОРОЖНО!)"
    echo "  help          Показать эту справку"
}

start_services() {
    print_status "Запуск сервисов N8N..."
    if docker compose up -d; then
        print_success "Сервисы запущены"
        print_status "Webhook endpoint: https://hook.autmatization-bot.ru/"
        print_status "Editor interface: https://n8n.autmatization-bot.ru/"
    else
        print_error "Ошибка запуска сервисов"
        exit 1
    fi
}

stop_services() {
    print_status "Остановка сервисов N8N..."
    docker compose down
    print_success "Сервисы остановлены"
}

restart_services() {
    print_status "Перезапуск сервисов N8N..."
    docker compose restart
    print_success "Сервисы перезапущены"
}

show_logs() {
    docker compose logs -f --tail=100
}

show_main_logs() {
    docker compose logs -f --tail=100 n8n-main n8n-editor
}

show_worker_logs() {
    docker compose logs -f --tail=100 n8n-worker
}

show_redis_logs() {
    docker compose logs -f --tail=100 redis
}

show_db_logs() {
    docker compose logs -f --tail=100 postgres
}

show_status() {
    print_status "Статус сервисов:"
    docker compose ps
    echo ""
    print_status "Использование ресурсов:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
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

shell_main() {
    print_status "Вход в shell основного N8N..."
    docker compose exec n8n-main /bin/sh
}

shell_worker() {
    print_status "Вход в shell worker'а..."
    docker compose exec n8n-worker /bin/sh
}

backup_data() {
    print_status "Создание резервной копии данных..."
    BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Бэкап базы данных
    docker compose exec postgres pg_dump -U n8n n8n > "$BACKUP_DIR/database.sql"
    
    # Бэкап файлов N8N
    cp -r data "$BACKUP_DIR/"
    cp .env "$BACKUP_DIR/"
    
    print_success "Резервная копия создана в $BACKUP_DIR"
}

update_services() {
    print_status "Обновление образов..."
    docker compose pull
    print_status "Перезапуск с новыми образами..."
    docker compose up -d
    print_success "Обновление завершено"
}

clean_data() {
    read -p "Вы уверены, что хотите удалить ВСЕ данные? (yes/no): " -r
    if [[ $REPLY =~ ^yes$ ]]; then
        print_warning "Остановка сервисов..."
        docker compose down -v
        print_warning "Удаление данных..."
        sudo rm -rf data/*
        print_success "Данные очищены"
    else
        print_status "Операция отменена"
    fi
}

case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    logs)
        show_logs
        ;;
    logs-main)
        show_main_logs
        ;;
    logs-worker)
        show_worker_logs
        ;;
    logs-redis)
        show_redis_logs
        ;;
    logs-db)
        show_db_logs
        ;;
    status)
        show_status
        ;;
    scale)
        scale_workers "$2"
        ;;
    shell-main)
        shell_main
        ;;
    shell-worker)
        shell_worker
        ;;
    backup)
        backup_data
        ;;
    update)
        update_services
        ;;
    clean)
        clean_data
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        print_error "Команда не указана"
        show_help
        exit 1
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


# Создание README файла

