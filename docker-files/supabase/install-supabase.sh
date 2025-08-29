#!/bin/bash

# Supabase Traefik Deployment Script
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

# Генерация API ключей
generate_api_keys() {
    local jwt_secret=$1
    
    # Генерация ANON_KEY
    local anon_payload='{"role":"anon","iss":"supabase","iat":'$(date +%s)',"exp":'$(date -d "+10 years" +%s)'}'
    local anon_key=$(echo -n "$anon_payload" | \
        openssl dgst -sha256 -hmac "$jwt_secret" -binary | \
        base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    # Генерация SERVICE_ROLE_KEY
    local service_payload='{"role":"service_role","iss":"supabase","iat":'$(date +%s)',"exp":'$(date -d "+10 years" +%s)'}'
    local service_key=$(echo -n "$service_payload" | \
        openssl dgst -sha256 -hmac "$jwt_secret" -binary | \
        base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    echo "$anon_key:$service_key"
}

# Основная функция
main() {
    print_info "🚀 Supabase Traefik Deployment Script"
    print_info "Автоматическое развертывание Supabase с Traefik reverse proxy"
    
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
    if [[ ! -d "docker" ]]; then
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
    local POOLER_TENANT_ID=$(openssl rand -hex 8)
    
    # Генерация API ключей
    local api_keys=$(generate_api_keys "$JWT_SECRET")
    local ANON_KEY=$(echo "$api_keys" | cut -d':' -f1)
    local SERVICE_ROLE_KEY=$(echo "$api_keys" | cut -d':' -f2)
    
    # Создание .env файла
    print_info "Создание файла окружения..."
    
    cat > .env << EOF
# Supabase Configuration
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY

# Database Configuration
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
POSTGRES_USER=postgres

# Pooler Configuration
POOLER_TENANT_ID=$POOLER_TENANT_ID
POOLER_PROXY_PORT_TRANSACTION=6543

# Studio Configuration
STUDIO_DEFAULT_ORGANIZATION=Supabase
STUDIO_DEFAULT_PROJECT=Default Project
STUDIO_PORT=3000

# Kong Configuration
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# Dashboard Authentication
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD

# URLs
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
SITE_URL=https://$SUPABASE_DOMAIN
ADDITIONAL_REDIRECT_URLS=

# SMTP Configuration (измените при необходимости)
SMTP_ADMIN_EMAIL=admin@$DOMAIN
SMTP_HOST=supabase-mail
SMTP_PORT=2500
SMTP_USER=fake_mail_user
SMTP_PASS=fake_mail_password
SMTP_SENDER_NAME=fake_sender

# Storage Configuration
STORAGE_BACKEND=file
FILE_STORAGE_BACKEND_PATH=/var/lib/storage

# Analytics (отключено для минимального развертывания)
ANALYTICS_ENABLED=false

# Edge Functions
FUNCTIONS_HTTP_PORT=9002

# Realtime Configuration
REALTIME_IP_VERSION=IPv4

# Other services
ENABLE_IMAGE_PROXIMATION=true
IMGPROXY_ENABLE_WEBP_DETECTION=true
EOF
    
    print_success "Файл окружения создан: .env"
    
    # Создание docker-compose.override.yml для Traefik
    print_info "Создание конфигурации для Traefik..."
    
    cat > docker-compose.override.yml << EOF
version: "3.8"

services:
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
    
    # Скрипт для управления сервисом
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
    
    # Скрипт для резервного копирования
    cat > backup.sh << 'EOF'
#!/bin/bash

BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "Создание резервной копии базы данных..."
docker compose exec db pg_dump -U postgres postgres > "$BACKUP_DIR/database.sql"

echo "Создание резервной копии конфигурации..."
cp .env "$BACKUP_DIR/"
cp docker-compose.yml "$BACKUP_DIR/"
cp docker-compose.override.yml "$BACKUP_DIR/"

echo "Резервная копия создана: $BACKUP_DIR"
EOF
    
    chmod +x backup.sh
    
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
    echo "   Резервное копирование: ./backup.sh"
}

# Обработка ошибок
trap 'print_error "Ошибка на строке $LINENO. Выход."' ERR

# Запуск основной функции
main