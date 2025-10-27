#!/bin/bash

# Простейший N8N скрипт без проблемных символов

set -e

echo "🚀 Установка N8N с Redis..."

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker не установлен"
    exit 1
fi

echo "✅ Docker найден"

# Создание сетей
echo "📡 Создание сетей..."
docker network create proxy 2>/dev/null || true
docker network create backend 2>/dev/null || true

# Создание папок
echo "📁 Создание папок..."
mkdir -p hook
cd hook
mkdir -p data/n8n data/redis

# Генерация ключа
KEY=$(openssl rand -base64 32)

# Создание .env (простой способ)
echo "⚙️ Создание .env..."
echo "N8N_ENCRYPTION_KEY=$KEY" > .env
echo "EXECUTIONS_MODE=queue" >> .env
echo "N8N_HOST=hook.autmatization-bot.ru" >> .env
echo "N8N_PROTOCOL=https" >> .env
echo "WEBHOOK_URL=https://hook.autmatization-bot.ru/" >> .env
echo "N8N_EDITOR_HOST=n8n.autmatization-bot.ru" >> .env
echo "QUEUE_BULL_REDIS_HOST=redis" >> .env
echo "QUEUE_BULL_REDIS_PORT=6379" >> .env
echo "QUEUE_BULL_REDIS_DB=0" >> .env
echo "N8N_RUNNERS_ENABLED=true" >> .env
echo "N8N_BLOCK_ENV_ACCESS_IN_NODE=false" >> .env
echo "N8N_GIT_NODE_DISABLE_BARE_REPOS=true" >> .env
echo "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true" >> .env
echo "N8N_METRICS=true" >> .env
echo "N8N_LOG_LEVEL=info" >> .env
echo "GENERIC_TIMEZONE=Europe/Moscow" >> .env
echo "QUEUE_HEALTH_CHECK_ACTIVE=true" >> .env

# Создание docker-compose (построчно)
echo "🐳 Создание docker-compose.yml..."

cat > docker-compose.yml << 'ENDFILE'
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
      - N8N_HOST=hook.autmatization-bot.ru
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://hook.autmatization-bot.ru/
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
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
      - backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-main.rule=Host(`hook.autmatization-bot.ru`)
      - traefik.http.routers.n8n-main.entrypoints=websecure
      - traefik.http.routers.n8n-main.tls.certresolver=letsencrypt
      - traefik.http.services.n8n-main.loadbalancer.server.port=5678

  n8n-editor:
    image: n8nio/n8n:latest
    container_name: n8n_editor
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=n8n.autmatization-bot.ru
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://hook.autmatization-bot.ru/
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
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
      - backend
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.n8n-editor.rule=Host(`n8n.autmatization-bot.ru`)
      - traefik.http.routers.n8n-editor.entrypoints=websecure
      - traefik.http.routers.n8n-editor.tls.certresolver=letsencrypt
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
      - EXECUTIONS_MODE=queue
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
      - backend
    deploy:
      replicas: 2

networks:
  n8n-internal:
    driver: bridge
  proxy:
    external: true
    name: proxy          # ← рекомендуется указывать явно (хотя и не обязательно, если имя совпадает)
  backend:
    external: true
    name: wp-backend     # ← КЛЮЧЕВАЯ СТРОКА!
ENDFILE

# Создание manage.sh
echo "🛠️ Создание manage.sh..."
cat > manage.sh << 'MANAGESCRIPT'
#!/bin/bash
case "$1" in
    start)
        echo "🚀 Запуск N8N..."
        docker compose up -d
        echo "✅ N8N запущен!"
        echo "🔗 Webhook: https://hook.autmatization-bot.ru/"
        echo "✏️ Editor: https://n8n.autmatization-bot.ru/"
        ;;
    stop)
        echo "🛑 Остановка N8N..."
        docker compose down
        echo "✅ N8N остановлен"
        ;;
    logs)
        docker compose logs -f
        ;;
    status)
        docker compose ps
        ;;
    *)
        echo "Команды: start, stop, logs, status"
        ;;
esac
MANAGESCRIPT

chmod +x manage.sh

# Исправление прав
echo "🔒 Исправление прав..."
chown -R 1000:1000 ./data/n8n 2>/dev/null || sudo chown -R 1000:1000 ./data/n8n 2>/dev/null || true
chmod -R 755 ./data/n8n 2>/dev/null || sudo chmod -R 755 ./data/n8n 2>/dev/null || true

echo ""
echo "✅ Установка завершена!"
echo ""
echo "🔑 Ключ шифрования: $KEY"
echo ""
echo "Команды управления:"
echo "  ./manage.sh start  - Запуск"
echo "  ./manage.sh stop   - Остановка"
echo "  ./manage.sh logs   - Логи"
echo "  ./manage.sh status - Статус"
echo ""

# Проверка YAML синтаксиса
echo "🔍 Проверка docker-compose.yml..."
if docker compose config >/dev/null 2>&1; then
    echo "✅ docker-compose.yml синтаксис корректен"
else
    echo "❌ Ошибка в docker-compose.yml:"
    docker compose config
    exit 1
fi

# Запуск
read -p "Запустить N8N сейчас? (y/n): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "🚀 Запуск N8N..."
    docker compose up -d
    
    echo ""
    echo "🎉 N8N успешно запущен!"
    echo ""
    echo "🔗 Webhook: https://hook.autmatization-bot.ru/"
    echo "✏️ Editor: https://n8n.autmatization-bot.ru/"
    echo ""
    echo "📋 Для MariaDB используйте host: wp-db"
else
    echo "N8N готов к запуску. Используйте: ./manage.sh start"
fi
