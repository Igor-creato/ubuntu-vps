#!/bin/bash

# Supabase Traefik Deployment Script - ИСПРАВЛЕННАЯ ВЕРСИЯ
# Автоматическое развертывание Supabase с Traefik reverse proxy
# Использует современные best practices и актуальные версии

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Проверка зависимостей
check_dependencies() {
    print_info "Проверка зависимостей..."
    
    if ! command -v git &> /dev/null; then
        print_error "Git не установлен. Установите git: sudo apt install git"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен. Установите docker: sudo apt install docker.io"
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_error "Docker Compose не установлен. Установите: sudo apt install docker-compose-plugin"
        exit 1
    fi
    
    # Проверка сети proxy
    if ! docker network ls | grep -q "proxy"; then
        print_error "Сеть 'proxy' не найдена. Убедитесь, что Traefik запущен и сеть создана."
        exit 1
    fi
    
    print_success "Все зависимости установлены"
}

# Генерация безопасных паролей
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

generate_jwt_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-40
}

generate_api_key() {
    local jwt_secret=$1
    local payload='{"role":"'$2'","iss":"supabase","iat":'$(date +%s)',"exp":'$(date -d "+10 years" +%s)'}'
    echo -n "$payload" | \
        openssl dgst -sha256 -hmac "$jwt_secret" -binary | \
        base64 -w 0 | tr '+/' '-_' | tr -d '='
}

# Основная функция
main() {
    print_info "🚀 Supabase Traefik Deployment Script (Исправленная версия)"
    
    check_dependencies
    
    # Запрос домена
    read -p "Введите ваш домен (например, example.com): " DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        print_error "Домен не может быть пустым"
        exit 1
    fi
    
    local SUPABASE_DOMAIN="supabase.$DOMAIN"
    print_info "Supabase будет доступен по адресу: https://$SUPABASE_DOMAIN"
    
    # Создание директории
    print_info "Создание директории проекта..."
    mkdir -p supabase
    cd supabase
    
    # Клонирование репозитория
    if [[ ! -f "docker-compose.yml" ]]; then
        print_info "Клонирование официального репозитория Supabase..."
        git clone --depth 1 https://github.com/supabase/supabase.git temp
        mv temp/docker/* .
        rm -rf temp
    fi
    
    # Генерация паролей и ключей
    print_info "Генерация безопасных паролей и ключей..."
    
    local POSTGRES_PASSWORD=$(generate_password)
    local JWT_SECRET=$(generate_jwt_secret)
    local DASHBOARD_PASSWORD=$(generate_password)
    local ANON_KEY=$(generate_api_key "$JWT_SECRET" "anon")
    local SERVICE_ROLE_KEY=$(generate_api_key "$JWT_SECRET" "service_role")
    
    # Создание полного .env файла со всеми необходимыми переменными
    print_info "Создание файла окружения..."
    
    # Генерация порта для Postgres (найдем свободный)
    local POSTGRES_PORT=$(python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
port = 5433
while port < 6000:
    try:
        s.bind(('localhost', port))
        s.close()
        print(port)
        break
    except OSError:
        port += 1
" 2>/dev/null || echo "5433")
    
    cat > .env << EOF
############
# Database #
############
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=$POSTGRES_PORT  # Измененный порт для избежания конфликта с n8n
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

############
# Supabase #
############
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY

# API
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443
API_EXTERNAL_URL=https://$SUPABASE_DOMAIN

# Studio
STUDIO_DEFAULT_ORGANIZATION=Supabase
STUDIO_DEFAULT_PROJECT=Default Project
STUDIO_PORT=3000
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
SITE_URL=https://$SUPABASE_DOMAIN
ADDITIONAL_REDIRECT_URLS=

# Auth
JWT_EXPIRY=3600
DISABLE_SIGNUP=false
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=true
ENABLE_PHONE_AUTOCONFIRM=true

# Mailer
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# SMTP
SMTP_ADMIN_EMAIL=admin@$DOMAIN
SMTP_HOST=supabase-mail
SMTP_PORT=2500
SMTP_USER=fake_mail_user
SMTP_PASS=fake_mail_password
SMTP_SENDER_NAME=fake_sender

# Storage
STORAGE_BACKEND=file
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
GLOBAL_S3_BUCKET=stub
AWS_ACCESS_KEY_ID=stub
AWS_SECRET_ACCESS_KEY=stub
AWS_DEFAULT_REGION=stub

# Analytics disabled
ANALYTICS_ENABLED=false
LOGFLARE_API_KEY=stub
LOGFLARE_PUBLIC_ACCESS_TOKEN=stub
LOGFLARE_PRIVATE_ACCESS_TOKEN=stub

# Edge Functions
FUNCTIONS_HTTP_PORT=9002
FUNCTIONS_VERIFY_JWT=false
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# Realtime
REALTIME_IP_VERSION=IPv4

# Pooler - используем другой порт для избежания конфликта
POOLER_TENANT_ID=your-tenant-id
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=15

# Vault
VAULT_ENC_KEY=$(generate_password)

# Storage secrets
POSTGREST_JWT_SECRET=$JWT_SECRET
PGRST_DB_SCHEMAS=public,storage,graphql_public
PGRST_DB_ANON_ROLE=anon

# Dashboard
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD

# Secrets for other services
SECRET_KEY_BASE=$(generate_password)

# Default values for services
IMGPROXY_ENABLE_WEBP_DETECTION=true
ENABLE_IMAGE_PROXIMATION=true
EOF
    
    print_success "Файл окружения создан: .env"
    
    # Исправление docker-compose.yml - убираем проблемный volume
    print_info "Исправление docker-compose.yml..."
    
    # Создаем исправленный docker-compose.yml
    cp docker-compose.yml docker-compose.yml.backup
    
    # Убираем проблемный volume для docker socket
    sed -i '/DOCKER_SOCKET_LOCATION/d' docker-compose.yml
    sed -i 's|${DOCKER_SOCKET_LOCATION}:/var/run/docker.sock:ro,z|/var/run/docker.sock:/var/run/docker.sock:ro|g' docker-compose.yml
    
    # Создание docker-compose.override.yml для Traefik
    print_info "Создание конфигурации для Traefik..."
    
    cat > docker-compose.override.yml << EOF
version: "3.8"

services:
  # Отключаем vector так как аналитика отключена
  vector:
    profiles:
      - analytics
    deploy:
      replicas: 0

  studio:
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-studio.rule=Host(\`${SUPABASE_DOMAIN}\`)
      - traefik.http.routers.supabase-studio.entrypoints=websecure
      - traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt
      - traefik.http.services.supabase-studio.loadbalancer.server.port=3000
    networks:
      - default
      - proxy

  kong:
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-api.rule=Host(\`${SUPABASE_DOMAIN}\`) && PathPrefix(\`/auth\`, \`/rest\`, \`/storage\`, \`/realtime\`)
      - traefik.http.routers.supabase-api.entrypoints=websecure
      - traefik.http.routers.supabase-api.tls.certresolver=letsencrypt
      - traefik.http.services.supabase-api.loadbalancer.server.port=8000
    networks:
      - default
      - proxy

networks:
  proxy:
    external: true
EOF
    
    print_success "Конфигурация Traefik создана: docker-compose.override.yml"
    
    # Создание вспомогательных скриптов
    print_info "Создание вспомогательных скриптов..."
    
    cat > manage.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "Запуск Supabase..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
        ;;
    stop)
        echo "Остановка Supabase..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml down
        ;;
    restart)
        echo "Перезапуск Supabase..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml restart
        ;;
    logs)
        echo "Просмотр логов..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml logs -f
        ;;
    update)
        echo "Обновление образов..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml pull
        docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
        ;;
    status)
        echo "Статус сервисов..."
        docker compose -f docker-compose.yml -f docker-compose.override.yml ps
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|logs|update|status}"
        exit 1
        ;;
esac
EOF
    
    chmod +x manage.sh
    
    # Запуск сервисов
    print_info "Запуск Supabase..."
    docker compose -f docker-compose.yml -f docker-compose.override.yml pull
    docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
    
    # Ожидание запуска сервисов
    print_info "Ожидание запуска сервисов..."
    sleep 30
    
    # Проверка статуса
    print_info "Проверка статуса сервисов..."
    docker compose ps
    
    # Вывод информации
    print_success "✨ Supabase успешно развернут!"
    echo
    print_info "🔗 Доступные сервисы:"
    echo "   Supabase Studio: https://$SUPABASE_DOMAIN"
    echo "   Username: admin"
    echo "   Password: $DASHBOARD_PASSWORD"
    echo
    echo "   Database Connection:"
    echo "   Host: $SUPABASE_DOMAIN"
    echo "   Port: 5432"
    echo "   Database: postgres"
    echo "   User: postgres"
    echo "   Password: $POSTGRES_PASSWORD"
    echo
    print_info "📁 Файлы проекта:"
    echo "   Рабочая директория: $(pwd)"
    echo "   Файл окружения: .env"
    echo "   Конфигурация Traefik: docker-compose.override.yml"
    echo
    print_info "🔧 Управление:"
    echo "   Запуск: ./manage.sh start"
    echo "   Остановка: ./manage.sh stop"
    echo "   Рестарт: ./manage.sh restart"
    echo "   Логи: ./manage.sh logs"
}

# Обработка ошибок
trap 'print_error "Ошибка на строке $LINENO. Выход."' ERR

# Запуск основной функции
main