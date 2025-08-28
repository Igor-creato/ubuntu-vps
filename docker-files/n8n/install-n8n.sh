#!/bin/bash

set -e

echo "🔐 Проверка прав доступа..."
if [ ! -w "." ]; then
    echo "❌ Ошибка: Недостаточно прав для записи в текущую директорию"
    echo "💡 Запустите скрипт с sudo или измените владельца директории"
    exit 1
fi

# Создаем директории заранее с sudo
sudo mkdir -p postgres-data n8n-data local-files secrets
sudo chown -R 999:999 postgres-data
sudo chown -R 1000:1000 n8n-data local-files
sudo chmod -R 755 postgres-data n8n-data local-files

echo "🚀 Начало развертывания n8n с PostgreSQL и Traefik"

# Создаем рабочую директорию
N8N_DIR="$HOME/n8n"
echo "📁 Создаем рабочую директорию: $N8N_DIR"
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# Создаем необходимые поддиректории
echo "📂 Создаем структуру директорий для данных и конфигураций"
mkdir -p {postgres-data,n8n-data,local-files,secrets}

# Скачиваем docker-compose.yml из репозитория
echo "📥 Загружаем docker-compose.yml из GitHub"
DOCKER_COMPOSE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/n8n/docker-compose.yml"
curl -sSL "$DOCKER_COMPOSE_URL" -o docker-compose.yml

# Проверяем успешность загрузки
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Ошибка: Не удалось загрузить docker-compose.yml"
    exit 1
fi

echo "✅ docker-compose.yml успешно загружен"

# Генерируем безопасные пароли и секреты
echo "🔐 Генерируем безопасные пароли и секреты"

# Генерация пароля PostgreSQL
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+' | cut -c1-32)

# Генерация ключа шифрования n8n (32 символа)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 24 | tr -d '/+' | cut -c1-32)

# Генерация базового auth для n8n (если требуется)
N8N_BASIC_AUTH_USER="admin"
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '/+' | cut -c1-16)

# Запрос пользовательского ввода для домена и email
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

# Настройки безопасности :cite[9]
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true
N8N_SECURE_COOKIE=true
EOF

echo "✅ .env файл создан"

# Создаем файл для базовой аутентификации
echo "🔐 Создаем/обновляем n8n.htpasswd"
htpasswd -bc ./secrets/n8n.htpasswd "$N8N_BASIC_AUTH_USER" "$N8N_BASIC_AUTH_PASSWORD" 2>/dev/null || {
    echo "⚠️ htpasswd не найден, устанавливаем apache2-utils"
    sudo apt-get update
    sudo apt-get install -y apache2-utils
    htpasswd -bc ./secrets/n8n.htpasswd "$N8N_BASIC_AUTH_USER" "$N8N_BASIC_AUTH_PASSWORD"
}

# Устанавливаем правильные права доступа
echo "🔒 Настраиваем права доступа к файлам"
chmod 600 .env
chmod 600 ./secrets/n8n.htpasswd
chmod 700 secrets

# Настраиваем права для данных PostgreSQL и n8n
sudo chown -R 999:999 postgres-data
sudo chown -R 1000:1000 n8n-data
sudo chown -R 1000:1000 local-files

chmod 755 postgres-data n8n-data local-files

# Проверяем .env файл
echo "🔍 Проверяем .env файл"
if [ ! -f ".env" ]; then
    echo "❌ Ошибка: .env файл не найден"
    exit 1
fi

# Проверяем наличие необходимых переменных
REQUIRED_VARS=("N8N_HOST" "POSTGRES_PASSWORD" "N8N_ENCRYPTION_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    if ! grep -q "^$var=" .env; then
        echo "❌ Ошибка: Переменная $var отсутствует в .env"
        exit 1
    fi
done

echo "✅ .env файл прошел проверку"

# Выводим одноразовую информацию для пользователя
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

# Ожидаем подтверждения пользователя
read -p "Нажмите Enter чтобы продолжить и удалить чувствительные данные из .env..."

# Удаляем чувствительные данные из .env файла
echo "🧹 Удаляем чувствительные данные из .env файла"
sed -i '/POSTGRES_PASSWORD=/d' .env
sed -i '/N8N_BASIC_AUTH_PASSWORD=/d' .env
sed -i '/N8N_ENCRYPTION_KEY=/d' .env

# Добавляем ссылки на файловые секреты
cat >> .env << EOF

# Секреты через файлы (более безопасный способ) :cite[1]:cite[7]
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
echo "⏳ Подождите несколько минут пока запустятся контейнеры и получены SSL сертификаты"
echo ""
echo "📋 Для проверки статуса выполните: docker compose logs -f"
echo "🔧 Для остановки выполните: docker compose down"
echo "🔄 Для обновления выполните: docker compose pull && docker compose up -d"

# Выводим информацию о безопасности
echo ""
echo "🔒 НАСТРОЙКИ БЕЗОПАСНОСТИ:"
echo "   - Данные сохраняются вне контейнеров в директориях:"
echo "     • PostgreSQL: $N8N_DIR/postgres-data"
echo "     • n8n: $N8N_DIR/n8n-data"
echo "   - Чувствительные данные хранятся в файлах секретов"
echo "   - Включены дополнительные настройки безопасности n8n :cite[9]"
echo "   - Traefik обеспечивает SSL/TLS шифрование"
