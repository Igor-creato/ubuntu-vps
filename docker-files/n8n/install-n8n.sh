
#!/bin/bash

set -e

echo "🚀 Полное развертывание n8n с PostgreSQL и Traefik"

# Создаем рабочую директорию
N8N_DIR="$HOME/n8n"
echo "📁 Создаем рабочую директорию: $N8N_DIR"
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"


# Останавливаем и удаляем старые контейнеры
echo "🧹 Очищаем старые контейнеры и volumes"
docker compose down -v 2>/dev/null || true

# Удаляем старые volumes чтобы избежать конфликтов
docker volume rm n8n-postgres-data n8n-app-data 2>/dev/null || true

# Создаем docker-compose.yml с ПРЯМЫМИ переменными (не файловыми секретами)
echo "📝 Создаем docker-compose.yml"
cat > docker-compose.yml << 'EOF'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n_user
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
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
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_POSTGRESDB_SCHEMA: public
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_HOST}/
      NODE_ENV: production
      GENERIC_TIMEZONE: Europe/Moscow
      TZ: Europe/Moscow
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_BASIC_AUTH_USER: admin
      N8N_BASIC_AUTH_PASSWORD: ${N8N_BASIC_AUTH_PASSWORD}
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PUBLIC_API_DISABLED: "true"
    volumes:
      - n8n_data:/home/node/.n8n
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
EOF

echo "✅ docker-compose.yml создан"

# Генерируем безопасные пароли и секреты
echo "🔐 Генерируем безопасные пароли и секреты"

POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)

# Запрос доменного имени
echo "🌐 Запрос конфигурационной информации"
read -p "Введите доменное имя для n8n (например: example.com) запустится на поддомене n8n.example.com: " N8N_HOST

# Создаем .env файл со ВСЕМИ переменными (включая секреты)
echo "📝 Создаем .env файл"
cat > .env << EOF
# Доменное имя для n8n
N8N_HOST="n8n.${N8N_HOST}"

# Секретные переменные
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}

# Настройки времени
GENERIC_TIMEZONE=Europe/Moscow
TZ=Europe/Moscow
EOF

echo "✅ .env файл создан"

# Устанавливаем правильные права доступа
echo "🔒 Настраиваем права доступа к файлам"
chmod 600 .env

# Проверяем наличие сети proxy
echo "🌐 Проверяем сеть proxy"
if ! docker network inspect proxy >/dev/null 2>&1; then
    echo "❌ Сеть proxy не найдена, создаем..."
    docker network create proxy
    echo "✅ Сеть proxy создана"
else
    echo "✅ Сеть proxy существует"
fi

# Выводим одноразовую информацию
echo ""
echo "================================================"
echo "🔐 ОДНОРАЗОВЫЕ УЧЕТНЫЕ ДАННЫЕ ДЛЯ N8N"
echo "================================================"
echo "🌐 Домен: https://n8n.$N8N_HOST"
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

echo "⏳ Ожидаем запуск контейнеров (10 секунд)..."
sleep 10

# Проверяем статус контейнеров
echo ""
echo "📊 Статус контейнеров:"
docker compose ps

# Проверяем логи n8n для диагностики
echo ""
echo "🔍 Проверяем логи n8n:"
docker compose logs n8n --tail=20

echo ""
echo "✅ Развертывание завершено!"
echo "🌐 n8n должен быть доступен по: https://n8n.$N8N_HOST"
echo "⏳ Если это первый запуск, подождите несколько минут пока Traefik получит SSL сертификаты"

echo ""
echo "📋 Команды для управления:"
echo "   Просмотр логов: docker compose logs -f"
echo "   Остановка: docker compose down"
echo "   Перезапуск: docker compose restart"
echo "   Обновление: docker compose pull && docker compose up -d"
