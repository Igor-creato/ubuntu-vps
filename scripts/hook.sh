#!/bin/bash

# N8N скрипт с PostgreSQL и Redis для queue mode

set -e

# Цвета для вывода (определяем в самом начале)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Функции для цветного вывода (определяем сразу после цветов)
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Теперь можно использовать функции
print_status "Установка N8N с PostgreSQL и Redis..."

# Проверка Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker не установлен"
    exit 1
fi

print_success "Docker найден"

# Создание сетей
print_status "Создание сетей..."
docker network create proxy 2>/dev/null || true
docker network create wp-backend 2>/dev/null || true

# Создание папок
print_status "Создание папок..."
mkdir -p hook
cd hook
mkdir -p data/n8n data/redis data/postgres

# Генерация ключей и паролей (без специальных символов)
KEY=$(openssl rand -hex 32)
PG_PASSWORD=$(openssl rand -hex 16)

# Создание .env файла напрямую без sed
print_status "Создание .env..."
cat > .env <<ENVEOF
# N8N настройки
N8N_ENCRYPTION_KEY=$KEY
EXECUTIONS_MODE=queue
N8N_HOST=hook.autmatization-bot.ru
N8N_PROTOCOL=https
WEBHOOK_URL=https://hook.autmatization-bot.ru/
N8N_EDITOR_HOST=n8n.autmatization-bot.ru

# Redis настройки
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0

# PostgreSQL для n8n метаданных
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$PG_PASSWORD

# PostgreSQL переменные для контейнера
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$PG_PASSWORD

# N8N современные настройки
N8N_RUNNERS_ENABLED=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=false
N8N_GIT_NODE_DISABLE_BARE_REPOS=true
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_METRICS=true
N8N_LOG_LEVEL=info
GENERIC_TIMEZONE=Europe/Moscow
QUEUE_HEALTH_CHECK_ACTIVE=true
ENVEOF

# Создание docker-compose с PostgreSQL
print_status "Создание docker-compose.yml с PostgreSQL..."

cat > docker-compose.yml <<COMPOSEEOF
services:
  # PostgreSQL для n8n метаданных
  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - n8n-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

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
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=hook.autmatization-bot.ru
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://hook.autmatization-bot.ru/
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - DB_TYPE=\${DB_TYPE}
      - DB_POSTGRESDB_HOST=\${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=\${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=\${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=\${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - N8N_RUNNERS_ENABLED=true
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_METRICS=true
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - QUEUE_HEALTH_CHECK_ACTIVE=true
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
      - wp-backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-main.rule=Host(\`hook.autmatization-bot.ru\`)
      - traefik.http.routers.n8n-main.entrypoints=websecure
      - traefik.http.routers.n8n-main.tls.certresolver=letsencrypt
      - traefik.http.services.n8n-main.loadbalancer.server.port=5678

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
      - N8N_HOST=n8n.autmatization-bot.ru
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://hook.autmatization-bot.ru/
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - DB_TYPE=\${DB_TYPE}
      - DB_POSTGRESDB_HOST=\${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=\${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=\${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=\${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - N8N_RUNNERS_ENABLED=true
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true
      - N8N_METRICS=true
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - QUEUE_HEALTH_CHECK_ACTIVE=true
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - proxy
      - wp-backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-editor.rule=Host(\`n8n.autmatization-bot.ru\`)
      - traefik.http.routers.n8n-editor.entrypoints=websecure
      - traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt
      - traefik.http.services.n8n-editor.loadbalancer.server.port=5678

  n8n-worker-1:
    image: n8nio/n8n:latest
    container_name: n8n_worker_1
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=10"]
    environment:
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - DB_TYPE=\${DB_TYPE}
      - DB_POSTGRESDB_HOST=\${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=\${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=\${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=\${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - N8N_RUNNERS_ENABLED=true
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - QUEUE_HEALTH_CHECK_ACTIVE=true
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - wp-backend

  n8n-worker-2:
    image: n8nio/n8n:latest
    container_name: n8n_worker_2
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["worker", "--concurrency=10"]
    environment:
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - DB_TYPE=\${DB_TYPE}
      - DB_POSTGRESDB_HOST=\${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=\${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=\${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=\${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_POSTGRESDB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - N8N_RUNNERS_ENABLED=true
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - QUEUE_HEALTH_CHECK_ACTIVE=true
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - n8n-internal
      - wp-backend

networks:
  n8n-internal:
    driver: bridge
  proxy:
    external: true
    name: proxy
  wp-backend:
    external: true
    name: wp-backend

volumes:
  postgres_data:
  redis_data:
  n8n_data:
COMPOSEEOF

# Создание manage.sh
print_status "Создание manage.sh..."
cat > manage.sh <<MANAGEEOF
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "\${BLUE}[INFO]\${NC} \$1"; }
print_success() { echo -e "\${GREEN}[SUCCESS]\${NC} \$1"; }
print_warning() { echo -e "\${YELLOW}[WARNING]\${NC} \$1"; }

case "\$1" in
    start)
        print_status "Запуск N8N с PostgreSQL..."
        docker compose up -d
        print_success "N8N запущен!"
        echo ""
        echo "Webhook: https://hook.autmatization-bot.ru/"
        echo "Editor: https://n8n.autmatization-bot.ru/"
        echo ""
        print_status "Для MariaDB используйте host: wp-db"
        ;;
    stop)
        print_status "Остановка N8N..."
        docker compose down
        print_success "N8N остановлен"
        ;;
    restart)
        print_status "Перезапуск N8N..."
        docker compose restart
        print_success "N8N перезапущен"
        ;;
    logs)
        docker compose logs -f --tail=100
        ;;
    logs-main)
        docker compose logs -f --tail=100 n8n-main
        ;;
    logs-workers)
        docker compose logs -f --tail=100 n8n-worker-1 n8n-worker-2
        ;;
    logs-postgres)
        docker compose logs -f --tail=100 postgres
        ;;
    status)
        print_status "Статус сервисов:"
        docker compose ps
        echo ""
        print_status "Очередь Redis:"
        docker exec -it n8n_redis redis-cli LLEN bull:n8n:waiting 2>/dev/null || echo "Redis недоступен"
        ;;
    *)
        echo "N8N с PostgreSQL управление:"
        echo ""
        echo "Команды:"
        echo "  start         - Запуск всех сервисов"
        echo "  stop          - Остановка всех сервисов"
        echo "  restart       - Перезапуск всех сервисов"
        echo "  logs          - Все логи"
        echo "  logs-main     - Логи webhook"
        echo "  logs-workers  - Логи worker'ов"
        echo "  logs-postgres - Логи PostgreSQL"
        echo "  status        - Статус и очередь"
        ;;
esac
MANAGEEOF

chmod +x manage.sh

# Исправление прав
print_status "Исправление прав..."
chown -R 1000:1000 ./data/n8n 2>/dev/null || sudo chown -R 1000:1000 ./data/n8n 2>/dev/null || true
chmod -R 755 ./data/n8n 2>/dev/null || sudo chmod -R 755 ./data/n8n 2>/dev/null || true

echo ""
print_success "Установка завершена!"
echo ""
echo "N8N ключ шифрования: $KEY"
echo "PostgreSQL пароль: $PG_PASSWORD"
echo ""
print_warning "Сохраните эти пароли в безопасном месте!"
echo ""
echo "Команды управления:"
echo "  ./manage.sh start     - Запуск"
echo "  ./manage.sh stop      - Остановка"
echo "  ./manage.sh logs      - Логи"
echo "  ./manage.sh status    - Статус и очередь"
echo ""

# Проверка YAML синтаксиса
print_status "Проверка docker-compose.yml..."
if docker compose config >/dev/null 2>&1; then
    print_success "docker-compose.yml синтаксис корректен"
else
    print_error "Ошибка в docker-compose.yml:"
    docker compose config
    exit 1
fi

# Запуск
read -p "Запустить N8N сейчас? (y/n): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    print_status "Запуск N8N с PostgreSQL..."
    docker compose up -d
    
    echo ""
    print_success "N8N успешно запущен с PostgreSQL!"
    echo ""
    echo "Webhook: https://hook.autmatization-bot.ru/"
    echo "Editor: https://n8n.autmatization-bot.ru/"
    echo ""
    print_status "Настройки для MariaDB в N8N:"
    print_status "   Host: wp-db"
    print_status "   Port: 3306"
    print_status "   Database: wordpress"
    echo ""
    print_status "Управление: ./manage.sh [команда]"
    print_status "Проверка очереди: ./manage.sh status"
else
    echo "N8N готов к запуску. Команда: ./manage.sh start"
fi
