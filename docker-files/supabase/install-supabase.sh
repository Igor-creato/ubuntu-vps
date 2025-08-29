#!/bin/bash

# Supabase Traefik Deployment Script - Финальная исправленная версия
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Генерация паролей
generate_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-25; }
generate_jwt_secret() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-40; }

main() {
    print_info "🚀 Supabase Traefik Deployment Script"
    
    # Запрос домена
    read -p "Введите ваш домен (например, example.com): " DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        print_error "Домен не может быть пустым"
        exit 1
    fi
    
    local SUPABASE_DOMAIN="supabase.$DOMAIN"
    print_info "Supabase будет доступен по адресу: https://$SUPABASE_DOMAIN"
    
    # Создание директории
    mkdir -p supabase && cd supabase
    
    # Клонирование если нужно
    if [[ ! -f "docker-compose.yml" ]]; then
        print_info "Клонирование репозитория..."
        git clone --depth 1 https://github.com/supabase/supabase.git temp
        mv temp/docker/* .
        rm -rf temp
    fi
    
    # Генерация паролей
    POSTGRES_PASSWORD=$(generate_password)
    JWT_SECRET=$(generate_jwt_secret)
    DASHBOARD_PASSWORD=$(generate_password)
    ANON_KEY=$(docker run --rm -e JWT_SECRET=$JWT_SECRET supabase/gotrue gotrue keys --anon | tail -n1)
    SERVICE_ROLE_KEY=$(docker run --rm -e JWT_SECRET=$JWT_SECRET supabase/gotrue gotrue keys --service | tail -n1)
    
    # Создание .env
    cat > .env << EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
SUPABASE_DOMAIN=$SUPABASE_DOMAIN
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
POSTGRES_USER=postgres
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443
API_EXTERNAL_URL=https://$SUPABASE_DOMAIN
STUDIO_DEFAULT_ORGANIZATION=Supabase
STUDIO_DEFAULT_PROJECT=Default Project
STUDIO_PORT=3000
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
SITE_URL=https://$SUPABASE_DOMAIN
JWT_EXPIRY=3600
DISABLE_SIGNUP=false
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=true
ENABLE_PHONE_AUTOCONFIRM=true
SMTP_ADMIN_EMAIL=admin@$DOMAIN
SMTP_HOST=supabase-mail
SMTP_PORT=2500
SMTP_USER=fake_mail_user
SMTP_PASS=fake_mail_password
SMTP_SENDER_NAME=fake_sender
STORAGE_BACKEND=file
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
ANALYTICS_ENABLED=false
FUNCTIONS_HTTP_PORT=9002
FUNCTIONS_VERIFY_JWT=false
DOCKER_SOCKET_LOCATION=/var/run/docker.sock
REALTIME_IP_VERSION=IPv4
POOLER_TENANT_ID=supabase
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=15
VAULT_ENC_KEY=$(generate_password)
SECRET_KEY_BASE=$(generate_password)
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
EOF
    
    # Удаляем зависимость от vector
    sed -i '/vector/d' docker-compose.yml
    sed -i '/analytics:/,/depends_on:/d' docker-compose.yml
    
    # Создаем override с правильной переменной
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
    
    # Запускаем
    print_info "Запуск Supabase..."
    docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
    
    print_success "✨ Supabase успешно развернут!"
    print_info "🔗 Доступ: https://$SUPABASE_DOMAIN"
    print_info "   Username: admin"
    print_info "   Password: $DASHBOARD_PASSWORD"
}

main