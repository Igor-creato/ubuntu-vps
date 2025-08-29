#!/bin/bash

# Supabase Traefik Deployment Script - Полностью рабочая версия
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Проверка зависимостей
check_dependencies() {
    print_info "Проверка зависимостей..."
    
    for cmd in git docker docker-compose; do
        if ! command -v $cmd &> /dev/null; then
            print_error "Необходимо установить: $cmd"
            exit 1
        fi
    done
    
    if ! docker network ls | grep -q "proxy"; then
        print_error "Сеть 'proxy' не найдена. Убедитесь, что Traefik запущен."
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

# Генерация JWT токенов
generate_jwt_tokens() {
    local jwt_secret=$1
    
    # Генерация ANON_KEY
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload='{"role":"anon","iss":"supabase","iat":'$(date +%s)',"exp":'$(date -d "+10 years" +%s)'}'
    
    local base64_header=$(echo -n "$header" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local base64_payload=$(echo -n "$payload" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    local signature=$(echo -n "${base64_header}.${base64_payload}" | \
        openssl dgst -sha256 -hmac "$jwt_secret" -binary | \
        base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    echo "${base64_header}.${base64_payload}.${signature}"
}

generate_service_key() {
    local jwt_secret=$1
    
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload='{"role":"service_role","iss":"supabase","iat":'$(date +%s)',"exp":'$(date -d "+10 years" +%s)'}'
    
    local base64_header=$(echo -n "$header" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local base64_payload=$(echo -n "$payload" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    local signature=$(echo -n "${base64_header}.${base64_payload}" | \
        openssl dgst -sha256 -hmac "$jwt_secret" -binary | \
        base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    echo "${base64_header}.${base64_payload}.${signature}"
}

# Основная функция
main() {
    print_info "🚀 Supabase Traefik Deployment Script - Рабочая версия"
    
    check_dependencies
    
    # Запрос домена
    read -p "Введите ваш домен (например, example.com): " DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        print_error "Домен не может быть пустым"
        exit 1
    fi
    
    local SUPABASE_DOMAIN="supabase.$DOMAIN"
    print_info "Supabase будет доступен по адресу: https://$SUPABASE_DOMAIN"
    
    # Создание директории проекта
    print_info "Создание директории проекта..."
    mkdir -p supabase
    cd supabase
    
    # Клонирование репозитория
    if [[ ! -f "docker-compose.yml" ]]; then
        print_info "Клонирование официального репозитория Supabase..."
        git clone --depth 1 https://github.com/supabase/supabase.git temp
        cp -r temp/docker/* .
        rm -rf temp
    fi
    
    # Генерация паролей и ключей
    print_info "Генерация безопасных паролей и ключей..."
    
    local POSTGRES_PASSWORD=$(generate_password)
    local JWT_SECRET=$(generate_jwt_secret)
    local DASHBOARD_PASSWORD=$(generate_password)
    
    # Генерация JWT токенов
    local ANON_KEY=$(generate_jwt_tokens "$JWT_SECRET")
    local SERVICE_ROLE_KEY=$(generate_service_key "$JWT_SECRET")
    
    print_success "Ключи успешно сгенерированы"
    
    # Создание полного .env файла
    print_info "Создание файла окружения..."
    
    cat > .env << EOF
############
# Database #
############
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
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

# Analytics (отключено)
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

# Pooler
POOLER_TENANT_ID=supabase
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

# Secrets
SECRET_KEY_BASE=$(generate_password)
EOF
    
    print_success "Файл окружения создан: .env"
    
    # Исправление docker-compose.yml - удаление ненужных сервисов
    print_info "Исправление конфигурации Docker..."
    
    # Создаем резервную копию
    cp docker-compose.yml docker-compose.yml.backup
    
    # Удаляем vector и analytics так как они не нужны
    sed -i '/vector:/,/restart: unless-stopped/ d' docker-compose.yml
    sed -i '/analytics:/,/restart: unless-stopped/ d' docker-compose.yml
    
    # Очистка пустых depends_on
    sed -i '/depends_on:/,/restart: unless-stopped/ {/depends_on:/! {/restart: unless-stopped/! d}}' docker-compose.yml
    
    # Создание docker-compose.override.yml для Traefik
    print_info "Создание конфигурации для Traefik..."
    
    cat > docker-compose.override.yml << EOF

services:
  studio:
    environment:
      - SUPABASE_URL=http://kong:8000
      - SUPABASE_PUBLIC_URL=https://${SUPABASE_DOMAIN}
      - SUPABASE_ANON_KEY=${ANON_KEY}
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-studio.rule=Host("${SUPABASE_DOMAIN}")
      - traefik.http.routers.supabase-studio.entrypoints=websecure
      - traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt
      - traefik.http.services.supabase-studio.loadbalancer.server.port=3000
    networks:
      - default
      - proxy

  kong:
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-api.rule=Host("${SUPABASE_DOMAIN}")
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
    cat > manage.sh << 'EOF'
#!/bin/bash
case "$1" in
    start) docker compose -f docker-compose.yml -f docker-compose.override.yml up -d ;;
    stop) docker compose -f docker-compose.yml -f docker-compose.override.yml down ;;
    restart) docker compose -f docker-compose.yml -f docker-compose.override.yml restart ;;
    logs) docker compose -f docker-compose.yml -f docker-compose.override.yml logs -f ;;
    status) docker compose -f docker-compose.yml -f docker-compose.override.yml ps ;;
    update) docker compose -f docker-compose.yml -f docker-compose.override.yml pull && docker compose up -d ;;
    *) echo "Usage: $0 {start|stop|restart|logs|status|update}"; exit 1 ;;
esac
EOF
    
    chmod +x manage.sh
    
    # Запуск сервисов
    print_info "Запуск Supabase..."
    docker compose pull
    docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
    
    # Ожидание запуска
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
    print_info "🔧 Управление:"
    echo "   ./manage.sh start  - запуск"
    echo "   ./manage.sh stop   - остановка"
    echo "   ./manage.sh logs   - логи"
    echo "   ./manage.sh status - статус"
}

# Запуск
main "$@"