#!/bin/bash

set -e

echo "🚀 Начало развертывания n8n с Docker volumes (актуальные стандарты)"

# Создаем рабочую директорию
N8N_DIR="$HOME/n8n"
echo "📁 Создаем рабочую директорию: $N8N_DIR"
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# Создаем директорию для секретов
echo "📂 Создаем директорию для секретов"
mkdir -p secrets

# Создаем docker-compose.yml с актуальными стандартами
echo "📝 Создаем docker-compose.yml с современным синтаксисом"
cat > docker-compose.yml << 'EOF'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n_user
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - type: bind
        source: ./secrets/postgres_password
        target: /run/secrets/postgres_password
        read_only: true
    networks:
      - n8n_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n_user -d n8n"]
      interval: 30s
      timeout: 10s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n_user
      DB_POSTGRESDB_PASSWORD_FILE: /run/secrets/postgres_password
      DB_POSTGRESDB_SCHEMA: public
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_HOST}/
      NODE_ENV: production
      GENERIC_TIMEZONE: Europe/Moscow
      TZ: Europe/Moscow
      N8N_ENCRYPTION_KEY_FILE: /run/secrets/n8n_encryption_key
      N8N_BASIC_AUTH_USER: admin
      N8N_BASIC_AUTH_PASSWORD_FILE: /run/secrets/n8n_auth_password
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PUBLIC_API_DISABLED: "true"
    volumes:
      - n8n_data:/home/node/.n8n
      - n8n_files:/files
      - type: bind
        source: ./secrets/postgres_password
        target: /run/secrets/postgres_password
        read_only: true
      - type: bind
        source: ./secrets/n8n_encryption_key
        target: /run/secrets/n8n_encryption_key
        read_only: true
      - type: bind
        source: ./secrets/n8n_auth_password
        target: /run/secrets/n8n_auth_password
        read_only: true
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=proxy"
    networks:
      - n8n_internal
      - proxy
    deploy:
      resources:
        limits:
          memory: 1024M

networks:
  n8n_internal:
    driver: bridge
  proxy:
    external: true
    name: proxy

volumes:
  postgres_data:
    name: n8n-postgres-data
  n8n_data:
    name: n8n-app-data
  n8n_files:
    name: n8n-shared-files
EOF

echo "✅ docker-compose.yml создан с современным синтаксисом"

# Генерируем безопасные пароли и секреты
echo "🔐 Генерируем безопасные пароли и секреты"

POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)

# Запрос пользовательского ввода
echo "🌐 Запрос конфигурационной информации"
read -p "Введите доменное имя для n8n (например: n8n.example.com): " N8N_HOST
read -p "Введите email для сертификатов Let's Encrypt: " SSL_EMAIL

# Создаем .env файл только с необходимыми переменными
echo "📝 Создаем .env файл"
cat > .env << EOF
# Доменное имя для n8n
N8N_HOST=${N8N_HOST}

# Email для сертификатов
SSL_EMAIL=${SSL_EMAIL}

# Настройки времени
GENERIC_TIMEZONE=Europe/Moscow
TZ=Europe/Moscow
EOF

echo "✅ .env файл создан"

# Создаем файловые секреты
echo "📁 Создаем файловые секреты"
echo "$POSTGRES_PASSWORD" > ./secrets/postgres_password
echo "$N8N_ENCRYPTION_KEY" > ./secrets/n8n_encryption_key
echo "$N8N_BASIC_AUTH_PASSWORD" > ./secrets/n8n_auth_password

# Устанавливаем правильные права доступа
echo "🔒 Настраиваем права доступа к файлам"
chmod 600 .env
chmod 600 ./secrets/*
chmod 700 secrets

# Создаем Docker volumes
echo "🐳 Создаем Docker volumes"
docker volume create n8n-postgres-data
docker volume create n8n-app-data
docker volume create n8n-shared-files

# Выводим одноразовую информацию
echo ""
echo "================================================"
echo "🔐 ОДНОРАЗОВЫЕ УЧЕТНЫЕ ДАННЫЕ ДЛЯ N8N"
echo "================================================"
echo "🌐 Домен: https://$N8N_HOST"
echo "👤 Имя пользователя: admin"
echo "🔑 Пароль: $N8N_BASIC_AUTH_PASSWORD"
echo "🗄️ Пароль PostgreSQL: $POSTGRES_PASSWORD"
echo "🔒 Ключ шифрования n8n: $N8N_ENCRYPTION_KEY"
echo "================================================"
echo "⚠️ СОХРАНИТЕ ЭТИ ДАННЫЕ В БЕЗОПАСНОМ МЕСТЕ!"
echo "================================================"
echo ""

# Ожидаем подтверждения
read -p "Нажмите Enter чтобы продолжить..."

# Запускаем docker-compose
echo "🐳 Запускаем n8n с помощью Docker Compose"
docker compose up -d

echo ""
echo "✅ Развертывание завершено!"
echo "🌐 n8n будет доступен по адресу: https://$N8N_HOST"
echo "⏳ Подождите 1-2 минуты пока запустятся контейнеры"
echo ""
echo "📋 Для проверки статуса: docker compose logs -f"
echo "📊 Для просмотра volumes: docker volume ls | grep n8n"
echo "🔧 Для остановки: docker compose down"
echo "🔄 Для обновления: docker compose pull && docker compose up -d"

# Выводим информацию о volumes
echo ""
echo "💾 СОЗДАННЫЕ DOCKER VOLUMES:"
docker volume ls | grep n8n

echo ""
echo "🔒 ДАННЫЕ СОХРАНЯЮТСЯ В:"
echo "   • PostgreSQL: volume n8n-postgres-data"
echo "   • n8n приложение: volume n8n-app-data" 
echo "   • Общие файлы: volume n8n-shared-files"
echo "   • Секреты: $N8N_DIR/secrets/"

# Проверяем наличие предупреждений
echo ""
echo "🔍 Проверяем конфигурацию..."
if docker compose config >/dev/null 2>&1; then
    echo "✅ Конфигурация Docker Compose валидна"
else
    echo "⚠️  Обнаружены проблемы в конфигурации:"
    docker compose config
fi
