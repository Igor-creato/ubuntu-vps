#!/bin/bash

set -e

echo "🚀 Начало развертывания n8n с Docker volumes"

# Создаем рабочую директорию
N8N_DIR="$HOME/n8n"
echo "📁 Создаем рабочую директорию: $N8N_DIR"
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# Создаем директорию для конфигураций
echo "📂 Создаем структуру директорий для конфигураций"
mkdir -p secrets

# Скачиваем docker-compose.yml
echo "📥 Загружаем docker-compose.yml"
cat > docker-compose.yml << 'EOF'

services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-n8n}
      POSTGRES_USER: ${POSTGRES_USER:-n8n_user}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-n8n_user} -d ${POSTGRES_DB:-n8n}"]
      interval: 30s
      timeout: 10s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n_user}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_SCHEMA=public
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_HOST}/
      - NODE_ENV=production
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-Europe/Moscow}
      - TZ=${GENERIC_TIMEZONE:-Europe/Moscow}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PUBLIC_API_DISABLED=true
      - N8N_USER_MANAGEMENT_DISABLED=false
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER:-admin}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
      - n8n_files:/files
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
    deploy:
      resources:
        limits:
          memory: 1024M
        reservations:
          memory: 512M

networks:
  n8n_internal:
    driver: bridge
  proxy:
    external: true
    name: proxy

volumes:
  postgres_data:
    driver: local
    name: n8n-postgres-data
  n8n_data:
    driver: local
    name: n8n-app-data
  n8n_files:
    driver: local
    name: n8n-shared-files
EOF

echo "✅ docker-compose.yml создан"

# Генерируем безопасные пароли и секреты
echo "🔐 Генерируем безопасные пароли и секреты"

POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+' | cut -c1-32)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 24 | tr -d '/+' | cut -c1-32)
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '/+' | cut -c1-16)
N8N_BASIC_AUTH_USER="admin"

# Запрос пользовательского ввода
echo "🌐 Запрос конфигурационной информации"
read -p "Введите доменное имя для n8n (например: n8n.example.com): " N8N_HOST
read -p "Введите email для сертификатов Let's Encrypt: " SSL_EMAIL

# Создаем .env файл
echo "📝 Создаем .env файл с конфигурацией"
cat > .env << EOF
# Доменное имя для n8n
N8N_HOST=${N8N_HOST}

# Настройки PostgreSQL
POSTGRES_DB=n8n
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Базовая аутентификация n8n
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}

# Ключ шифрования n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# Настройки времени
GENERIC_TIMEZONE=Europe/Moscow
TZ=Europe/Moscow

# Email для сертификатов
SSL_EMAIL=${SSL_EMAIL}

# Настройки безопасности
N8N_DIAGNOSTICS_ENABLED=false
N8N_PUBLIC_API_DISABLED=true
N8N_USER_MANAGEMENT_DISABLED=false
EOF

echo "✅ .env файл создан"

# Создаем файл для базовой аутентификации
echo "🔐 Создаем n8n.htpasswd"
if ! command -v htpasswd &> /dev/null; then
    echo "⚠️ htpasswd не найден, устанавливаем apache2-utils"
    sudo apt-get update
    sudo apt-get install -y apache2-utils
fi

htpasswd -bc ./secrets/n8n.htpasswd "$N8N_BASIC_AUTH_USER" "$N8N_BASIC_AUTH_PASSWORD"

# Устанавливаем правильные права доступа
echo "🔒 Настраиваем права доступа к файлам"
chmod 600 .env
chmod 600 ./secrets/n8n.htpasswd
chmod 700 secrets

# Проверяем .env файл
echo "🔍 Проверяем .env файл"
if [ ! -f ".env" ]; then
    echo "❌ Ошибка: .env файл не найден"
    exit 1
fi

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
echo "👤 Имя пользователя: $N8N_BASIC_AUTH_USER"
echo "🔑 Пароль: $N8N_BASIC_AUTH_PASSWORD"
echo "🗄️ Пароль PostgreSQL: $POSTGRES_PASSWORD"
echo "🔒 Ключ шифрования n8n: $N8N_ENCRYPTION_KEY"
echo "================================================"
echo "⚠️ СОХРАНИТЕ ЭТИ ДАННЫЕ В БЕЗОПАСНОМ МЕСТЕ!"
echo "⚠️ ОНИ БУДУТ УДАЛЕНЫ ИЗ .env ФАЙЛА!"
echo "================================================"
echo ""

# Ожидаем подтверждения
read -p "Нажмите Enter чтобы продолжить и удалить чувствительные данные из .env..."

# Удаляем чувствительные данные из .env
echo "🧹 Удаляем чувствительные данные из .env файла"
sed -i '/POSTGRES_PASSWORD=/d' .env
sed -i '/N8N_BASIC_AUTH_PASSWORD=/d' .env
sed -i '/N8N_ENCRYPTION_KEY=/d' .env

# Добавляем ссылки на файловые секреты
cat >> .env << EOF

# Секреты через файлы
POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
N8N_BASIC_AUTH_PASSWORD_FILE=/run/secrets/n8n_auth_password
N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_encryption_key
EOF

# Создаем файловые секреты
echo "📁 Создаем файловые секреты"
echo "$POSTGRES_PASSWORD" > ./secrets/postgres_password
echo "$N8N_BASIC_AUTH_PASSWORD" > ./secrets/n8n_auth_password
echo "$N8N_ENCRYPTION_KEY" > ./secrets/n8n_encryption_key

# Устанавливаем права доступа для секретов
chmod 600 ./secrets/*

# Запускаем docker-compose
echo "🐳 Запускаем n8n с помощью Docker Compose"
docker compose up -d

echo ""
echo "✅ Развертывание завершено!"
echo "🌐 n8n будет доступен по адресу: https://$N8N_HOST"
echo "⏳ Подождите несколько минут пока запустятся контейнеры"
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
