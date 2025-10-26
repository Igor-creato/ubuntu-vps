#!/bin/bash

# Скрипт для создания и запуска N8N с Redis в режиме очереди через Traefik
# Настроен для работы с внешней MariaDB - БЕЗ PostgreSQL

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

# Проверка сетей
check_networks() {
    print_status "Проверка Docker сетей..."
    
    # Проверка сети proxy для Traefik
    if ! docker network ls | grep -q "proxy"; then
        print_warning "Сеть 'proxy' не найдена. Создание сети..."
        docker network create proxy
        print_success "Сеть 'proxy' создана"
    else
        print_success "Сеть 'proxy' уже существует"
    fi
    
    # Проверка сети backend для MariaDB
    if ! docker network ls | grep -q "backend"; then
        print_warning "Сеть 'backend' не найдена. Создание сети..."
        docker network create backend
        print_success "Сеть 'backend' создана"
    else
        print_success "Сеть 'backend' уже существует"
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
            echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
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
    
    # Создаем папки для данных (без PostgreSQL)
    mkdir -p data/n8n
    mkdir -p data/redis
    
    print_success "Структура папок создана в $(pwd)"
}

# Создание .env файла БЕЗ PostgreSQL
create_env_file() {
    print_status "Создание файла конфигурации .env (без PostgreSQL)..."
    
    # Генерируем ключи
    N8N_ENCRYPTION_KEY=$(generate_encryption_key)
    
    cat > .env << EOF
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

# Redis настройки
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0

# N8N современные настройки (устраняют warnings)
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

# Информация о внешней MariaDB (для справки)
# Подключение к MariaDB через credentials в N8N UI:
# Host: wp-db (имя контейнера)
# Port: 3306
# Database: wordpress
# User/Password: из вашего .env файла MariaDB
MARIADB_CONTAINER_NAME=wp-db
MARIADB_DATABASE=wordpress
MARIADB_PORT=3306
EOF

    print_success "Файл .env создан без PostgreSQL"
    print_warning "Файл содержит ключ шифрования N8N:"
    print_warning "N8N ключ шифрования: $N8N_ENCRYPTION_KEY"
    print_status "Подключение к MariaDB настраивается через UI N8N (host: wp-db)"
}

# Создание docker-compose.yml БЕЗ PostgreSQL + подключение к backend сети
create_docker_compose() {
    print_status "Создание docker-compose.yml для работы с внешней MariaDB..."
    
    cat > docker-compose.yml << 'EOF'
# N8N с Redis (без PostgreSQL) + подключение к MariaDB через сеть backend
services:
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
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - N8N_PORT=${N8N_PORT}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      
      # SQLite для метаданных N8N (по умолчанию)
      # DB_TYPE не указываем - автоматически SQLite
      
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
      - backend  # Подключение к сети MariaDB
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

  # N8N Editor экземпляр (отдельный домен для редактирования)
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
      
      # SQLite для метаданных N8N (общая база с main)
      
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
      - backend  # Подключение к сети MariaDB
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
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=10"]
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      
      # SQLite для метаданных N8N (общая база)
      
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
      - backend  # Подключение к сети MariaDB
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
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=10"]
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      
      # SQLite для метаданных N8N (общая база)
      
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
      - backend  # Подключение к сети MariaDB
    healthcheck:
      test: ["CMD-SHELL", "ps aux | grep -v grep | grep worker || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  # Внутренняя сеть для N8N и Redis
  n8n-internal:
    driver: bridge
  
  # Внешняя сеть для Traefik
  proxy:
    external: true
    name: proxy
    
  # Сеть для подключения к MariaDB
  backend:
    external: true
    name: backend

volumes:
  redis_data:
  n8n_data:
EOF

    print_success "docker-compose.yml создан для работы с внешней MariaDB"
    print_status "N8N подключен к сетям: proxy (Traefik) + backend (MariaDB)"
}

# Создание расширенного скрипта управления
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
    echo "  start         Запустить все сервисы N8N"
    echo "  stop          Остановить все сервисы N8N"
    echo "  restart       Перезапустить все сервисы N8N"
    echo "  logs          Показать логи всех сервисов"
    echo "  logs-main     Показать логи основного N8N"
    echo "  logs-editor   Показать логи редактора N8N"
    echo "  logs-workers  Показать логи worker'ов"
    echo "  logs-redis    Показать логи Redis"
    echo "  status        Показать статус сервисов"
    echo "  fix-perms     Исправить права доступа N8N"
    echo "  scale [N]     Масштабировать до N worker'ов"
    echo "  mariadb-test  Проверить подключение к MariaDB"
    echo "  networks      Показать информацию о сетях"
    echo "  backup        Создать резервную копию N8N данных"
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
    fi
    
    print_success "Права доступа исправлены"
}

test_mariadb_connection() {
    print_status "Проверка подключения к MariaDB..."
    
    # Проверяем доступность контейнера wp-db
    if docker ps --filter "name=wp-db" --format "{{.Names}}" | grep -q "wp-db"; then
        print_success "Контейнер wp-db найден и запущен"
        
        # Проверяем доступность из сети backend
        if docker run --rm --network backend alpine/curl -s --connect-timeout 5 wp-db:3306 2>/dev/null; then
            print_success "MariaDB доступна по сети backend на порту 3306"
        else
            print_warning "MariaDB недоступна или не отвечает на порту 3306"
        fi
    else
        print_error "Контейнер wp-db не найден или не запущен"
        print_status "Убедитесь что MariaDB контейнер запущен с именем 'wp-db'"
    fi
    
    # Показываем инструкции для настройки credentials
    echo ""
    print_status "Для подключения к MariaDB в N8N создайте MySQL credentials:"
    print_status "  Host: wp-db"
    print_status "  Port: 3306"
    print_status "  Database: wordpress"
    print_status "  User/Password: из вашего .env файла MariaDB"
}

show_networks() {
    print_status "Информация о Docker сетях:"
    echo ""
    
    print_status "Сеть proxy (Traefik):"
    docker network inspect proxy 2>/dev/null | grep -A 10 "Containers" || print_warning "Сеть proxy не найдена"
    
    echo ""
    print_status "Сеть backend (MariaDB):"
    docker network inspect backend 2>/dev/null | grep -A 10 "Containers" || print_warning "Сеть backend не найдена"
    
    echo ""
    print_status "Внутренняя сеть N8N:"
    docker network inspect hook_n8n-internal 2>/dev/null | grep -A 10 "Containers" || print_warning "Внутренняя сеть N8N не найдена"
}

scale_workers() {
    if [ -z "$1" ]; then
        print_error "Укажите количество worker'ов (1-10)"
        exit 1
    fi
    
    if [ "$1" -lt 1 ] || [ "$1" -gt 10 ]; then
        print_error "Количество worker'ов должно быть от 1 до 10"
        exit 1
    fi
    
    print_status "Масштабирование до $1 worker'ов..."
    
    # Останавливаем существующие worker'ы
    docker compose stop n8n-worker-1 n8n-worker-2 2>/dev/null || true
    
    # Запускаем нужное количество
    for i in $(seq 1 $1); do
        if [ "$i" -le 2 ]; then
            docker compose up -d n8n-worker-$i
        else
            # Для дополнительных worker'ов создаем временные
            docker run -d --name "n8n_worker_$i" \
                --restart unless-stopped \
                --network hook_n8n-internal \
                --network backend \
                -e N8N_ENCRYPTION_KEY="$(grep N8N_ENCRYPTION_KEY .env | cut -d= -f2)" \
                -e EXECUTIONS_MODE=queue \
                -e QUEUE_BULL_REDIS_HOST=redis \
                -e QUEUE_BULL_REDIS_PORT=6379 \
                -v "$(pwd)/data/n8n:/home/node/.n8n" \
                n8nio/n8n:latest worker --concurrency=10
        fi
    done
    
    print_success "Worker'ы масштабированы до $1 экземпляров"
}

backup_data() {
    print_status "Создание резервной копии данных N8N..."
    BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Копируем данные N8N (SQLite база и настройки)
    cp -r data "$BACKUP_DIR/" 2>/dev/null || print_warning "Не удалось скопировать файлы данных"
    cp .env "$BACKUP_DIR/" 2>/dev/null || print_warning "Не удалось скопировать .env"
    cp docker-compose.yml "$BACKUP_DIR/" 2>/dev/null || print_warning "Не удалось скопировать docker-compose.yml"
    
    print_success "Резервная копия N8N создана в $BACKUP_DIR"
    print_status "Для MariaDB создавайте отдельную резервную копию"
}

start_services() {
    print_status "Проверка сетей..."
    
    # Проверяем необходимые сети
    for network in proxy backend; do
        if ! docker network ls | grep -q "$network"; then
            print_warning "Создание сети $network..."
            docker network create "$network"
        fi
    done
    
    print_status "Запуск сервисов N8N..."
    if docker compose up -d; then
        print_success "Сервисы N8N запущены"
        echo ""
        print_status "Доступ к сервисам:"
        print_status "  - Webhook endpoint: https://hook.autmatization-bot.ru/"
        print_status "  - Editor interface: https://n8n.autmatization-bot.ru/"
        echo ""
        print_status "Подключение к MariaDB:"
        print_status "  - Host: wp-db"
        print_status "  - Port: 3306"
        print_status "  - Database: wordpress"
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
        print_success "Сервисы N8N остановлены"
        ;;
    restart)
        docker compose restart
        print_success "Сервисы N8N перезапущены"
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
    logs-workers)
        docker compose logs -f --tail=100 n8n-worker-1 n8n-worker-2
        ;;
    logs-redis)
        docker compose logs -f --tail=100 redis
        ;;
    status)
        print_status "Статус сервисов N8N:"
        docker compose ps
        echo ""
        print_status "Использование ресурсов:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" $(docker compose ps -q) 2>/dev/null
        ;;
    fix-perms)
        fix_permissions
        ;;
    scale)
        scale_workers "$2"
        ;;
    mariadb-test)
        test_mariadb_connection
        ;;
    networks)
        show_networks
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

# Создание README с инструкциями для MariaDB
create_readme() {
    print_status "Создание README файла..."
    
    cat > README.md << 'EOF'
# N8N с Redis в режиме очереди + MariaDB интеграция

Этот проект развертывает N8N с поддержкой масштабирования через Redis и интеграцию с внешней MariaDB.

## Архитектура

- **N8N Main**: Webhook processor (hook.autmatization-bot.ru)
- **N8N Editor**: Редактор workflow (n8n.autmatization-bot.ru)
- **N8N Workers**: 2+ экземпляра для обработки задач из Redis очереди
- **Redis**: Очередь задач для масштабирования
- **SQLite**: Метаданные N8N (вместо PostgreSQL)
- **MariaDB**: Внешняя база данных (контейнер wp-db)

## Быстрый старт

1. Убедитесь, что Traefik и MariaDB уже запущены
2. Запустите установочный скрипт
3. Настройте подключение к MariaDB в N8N UI

## Управление

Основные команды для управления сервисами:
- start: Запуск сервисов N8N
- stop: Остановка сервисов N8N
- logs: Просмотр логов
- mariadb-test: Проверка подключения к MariaDB
- status: Статус сервисов

## Настройка подключения к MariaDB

В N8N Editor создайте MySQL credentials:
- Host: wp-db
- Port: 3306
- Database: wordpress
- User: ваш MySQL пользователь
- Password: ваш MySQL пароль

## Docker сети

- proxy: Для Traefik (внешняя)
- backend: Для MariaDB (внешняя) 
- n8n-internal: Внутренняя сеть N8N и Redis

## Масштабирование

Увеличить количество worker'ов:
./manage.sh scale 5

## Мониторинг

Проверка статуса всех сервисов:
./manage.sh status
EOF

    print_success "README.md создан"
}
