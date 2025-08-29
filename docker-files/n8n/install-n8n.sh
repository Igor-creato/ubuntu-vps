#!/bin/bash

set -e

echo "🚀 Безопасное развертывание n8n с Docker Secrets"

# Создаем рабочую директорию
N8N_DIR="$HOME/n8n"
echo "📁 Создаем рабочую директорию: $N8N_DIR"
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# Создаем docker-compose.yml с Docker Secrets
echo "📝 Создаем docker-compose.yml с Docker Secrets"
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
    secrets:
      - postgres_password
    networks:
      - n8n_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n_user -d n8n"]
      interval: 30s
      timeout: 10s
      retries: 5

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
    volumes:
      - n8n_data:/home/node/.n8n
    secrets:
      - postgres_password
      - n8n_encryption_key
      - n8n_auth_password
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=proxy"
    networks:
      - n8n_internal
      - proxy

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

secrets:
  postgres_password:
    file: ./secrets/postgres_password
  n8n_encryption_key:
    file: ./secrets/n8n_encryption_key
  n8n_auth_password:
    file: ./secrets/n8n_auth_password
EOF

echo "✅ docker-compose.yml создан с Docker Secrets"

# Генерируем безопасные пароли и секреты
echo "🔐 Генерируем безопасные пароли и секреты"

POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)

# Запрос доменного имени
echo "🌐 Запрос конфигурационной информации"
read -p "Введите доменное имя для n8n (например: n8n.example.com): " N8N_HOST

# Создаем .env файл только с НЕсекретными переменными
echo "📝 Создаем .env файл"
cat > .env << EOF
# Доменное имя для n8n
N8N_HOST=${N8N_HOST}

# Настройки времени
GENERIC_TIMEZONE=Europe/Moscow
TZ=Europe/Moscow
EOF

echo "✅ .env файл создан"

# Создаем файлы секретов
echo "📁 Создаем файлы секретов"
mkdir -p secrets
echo "$POSTGRES_PASSWORD" > ./secrets/postgres_password
echo "$N8N_ENCRYPTION_KEY" > ./secrets/n8n_encryption_key
echo "$N8N_BASIC_AUTH_PASSWORD" > ./secrets/n8n_auth_password

# Устанавливаем правильные права доступа
echo "🔒 Настраиваем права доступа"
chmod 600 .env
chmod 600 ./secrets/*
chmod 700 secrets

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

# Очищаем переменные с секретами из памяти
unset POSTGRES_PASSWORD
unset N8N_ENCRYPTION_KEY
unset N8N_BASIC_AUTH_PASSWORD

echo "🧹 Секреты удалены из памяти"

# Запускаем docker-compose
echo "🐳 Запускаем n8n с помощью Docker Compose"
docker compose up -d

echo "⏳ Ожидаем запуск контейнеров..."
sleep 10

# Проверяем статус
echo "📊 Статус контейнеров:"
docker compose ps

echo ""
echo "✅ Развертывание завершено!"
