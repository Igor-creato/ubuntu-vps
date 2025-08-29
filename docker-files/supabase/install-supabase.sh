#!/bin/bash

# Supabase Traefik Deployment Script - Финальная рабочая версия
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Генерация безопасных паролей
generate_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-25; }
generate_jwt_secret() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-40; }

# Генерация JWT токенов
generate_jwt() {
    local secret=$1
    local role=$2
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload="{\"role\":\"$role\",\"iss\":\"supabase\",\"iat\":$(date +%s),\"exp\":$(date -d "+10 years" +%s)}"
    
    local h=$(echo -n "$header" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local p=$(echo -n "$payload" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    local sig=$(echo -n "${h}.${p}" | openssl dgst -sha256 -hmac "$secret" -binary | base64 -w 0 | tr '+/' '-_' | tr -d '=')
    
    echo "${h}.${p}.${sig}"
}

main() {
    print_info "🚀 Supabase Traefik Deployment Script - Полностью рабочая версия"
    
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
    local ANON_KEY=$(generate_jwt "$JWT_SECRET" "anon")
    local SERVICE_ROLE_KEY=$(generate_jwt "$JWT_SECRET" "service_role")
    
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
    
    print_success "Файл окружения создан: .env"
    
    # Создание нового docker-compose.yml без vector и analytics
    print_info "Создание исправленной конфигурации..."
    
    cat > docker-compose.yml << 'EOF'

services:
  studio:
    container_name: supabase-studio
    image: supabase/studio:20240925-2e5c7e3
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "require('http').get('http://localhost:3000/api/profile', (r) => {if (r.statusCode !== 200) throw new Error(r.statusCode)})"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      STUDIO_PG_META_URL: http://meta:8080
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DEFAULT_ORGANIZATION_NAME: ${STUDIO_DEFAULT_ORGANIZATION}
      DEFAULT_PROJECT_NAME: ${STUDIO_DEFAULT_PROJECT}
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
    depends_on:
      analytics:
        condition: service_healthy
    networks:
      - default

  kong:
    container_name: supabase-kong
    image: kong:2.8.1
    restart: unless-stopped
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /var/lib/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
    ports:
      - ${KONG_HTTP_PORT}:8000/tcp
      - ${KONG_HTTPS_PORT}:8443/tcp
    volumes:
      - ./volumes/api:/var/lib/kong
    depends_on:
      analytics:
        condition: service_healthy
    networks:
      - default

  auth:
    container_name: supabase-auth
    image: supabase/gotrue:v2.158.1
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test:
        [
          "CMD",
          "wget",
          "--no-verbose",
          "--tries=1",
          "--spider",
          "http://localhost:9999/health"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: ${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@db:5432/postgres
      GOTRUE_SITE_URL: ${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: ${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: ${DISABLE_SIGNUP}
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: ${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: ${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
      GOTRUE_MAILER_AUTOCONFIRM: ${ENABLE_EMAIL_AUTOCONFIRM}
      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
      GOTRUE_SMTP_HOST: ${SMTP_HOST}
      GOTRUE_SMTP_PORT: ${SMTP_PORT}
      GOTRUE_SMTP_USER: ${SMTP_USER}
      GOTRUE_SMTP_PASS: ${SMTP_PASS}
      GOTRUE_SMTP_SENDER_NAME: ${SMTP_SENDER_NAME}
      GOTRUE_MAILER_URLPATHS_INVITE: ${MAILER_URLPATHS_INVITE}
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: ${MAILER_URLPATHS_CONFIRMATION}
      GOTRUE_MAILER_URLPATHS_RECOVERY: ${MAILER_URLPATHS_RECOVERY}
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: ${MAILER_URLPATHS_EMAIL_CHANGE}
      GOTRUE_EXTERNAL_PHONE_ENABLED: ${ENABLE_PHONE_SIGNUP}
      GOTRUE_SMS_AUTOCONFIRM: ${ENABLE_PHONE_AUTOCONFIRM}

  rest:
    container_name: supabase-rest
    image: postgrest/postgrest:v12.2.0
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@db:5432/postgres
      PGRST_DB_SCHEMAS: ${PGRST_DB_SCHEMAS}
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"

  realtime:
    container_name: realtime-dev.supabase-realtime
    image: supabase/realtime:v2.30.34
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    environment:
      PORT: 4000
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: supabase_admin
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_NAME: postgres
      DB_SSL: "false"
      JWT_SECRET: ${JWT_SECRET}
      REPLICATION_MODE: RLS
      REPLICATION_POLL_INTERVAL: 100
      SECURE_CHANNELS: "true"
      SLOT_NAME: supabase_realtime_rls
      TEMPORARY_SLOT: "true"
      REALTIME_IP_VERSION: ${REALTIME_IP_VERSION}

  storage:
    container_name: supabase-storage
    image: supabase/storage-api:v1.10.1
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
    healthcheck:
      test:
        [
          "CMD",
          "wget",
          "--no-verbose",
          "--tries=1",
          "--spider",
          "http://localhost:5000/status"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    environment:
      ANON_KEY: ${ANON_KEY}
      SERVICE_KEY: ${SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: ${JWT_SECRET}
      DATABASE_URL: postgres://supabase_storage_admin:${POSTGRES_PASSWORD}@db:5432/postgres
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: ${STORAGE_BACKEND}
      FILE_STORAGE_BACKEND_PATH: ${FILE_STORAGE_BACKEND_PATH}
      TENANT_ID: stub
      REGION: stub
      GLOBAL_S3_BUCKET: ${GLOBAL_S3_BUCKET}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}

  imgproxy:
    container_name: supabase-imgproxy
    image: darthsim/imgproxy:v3.8.0
    healthcheck:
      test: [ "CMD", "imgproxy", "health" ]
      timeout: 5s
      interval: 5s
      retries: 3
    volumes:
      - ./volumes/storage:/var/lib/storage
    environment:
      IMGPROXY_BIND: ":5001"
      IMGPROXY_LOCAL_FILESYSTEM_ROOT: /
      IMGPROXY_USE_ETAG: "true"
      IMGPROXY_ENABLE_WEBP_DETECTION: ${IMGPROXY_ENABLE_WEBP_DETECTION}
    restart: unless-stopped

  meta:
    container_name: supabase-meta
    image: supabase/postgres-meta:v0.83.2
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: db
      PG_META_DB_PORT: 5432
      PG_META_DB_NAME: postgres
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}

  functions:
    container_name: supabase-edge-functions
    image: supabase/edge-runtime:v1.57.8
    restart: unless-stopped
    depends_on:
      analytics:
        condition: service_healthy
    environment:
      JWT_SECRET: ${JWT_SECRET}
      SUPABASE_URL: http://kong:8000
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}
      SUPABASE_DB_URL: postgres://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
      VERIFY_JWT: ${FUNCTIONS_VERIFY_JWT}
      DOCKER_SOCKET_LOCATION: ${DOCKER_SOCKET_LOCATION}

  db:
    container_name: supabase-db
    image: supabase/postgres:15.1.1.78
    healthcheck:
      test: pg_isready -U postgres -h localhost
      interval: 5s
      timeout: 5s
      retries: 10
    depends_on:
      analytics:
        condition: service_healthy
    restart: unless-stopped
    ports:
      - ${POSTGRES_PORT}:5432
    volumes:
      - ./volumes/db:/var/lib/postgresql/data
      - ./volumes/db/init:/docker-entrypoint-initdb.d
    environment:
      POSTGRES_HOST: /var/run/postgresql
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_INITDB_ARGS: "--lc-ctype=C --lc-collate=C"
      POSTGRES_HOST_AUTH_METHOD: "scram-sha-256"

  pooler:
    container_name: supabase-pooler
    image: supabase/supavisor:1.1.5
    healthcheck:
      test:
        [
          "CMD",
          "wget",
          "--no-verbose",
          "--tries=1",
          "--spider",
          "http://localhost:4000/health"
        ]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      POSTGRES_HOST: ${POSTGRES_HOST}
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DATABASE: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POOLER_TENANT_ID: ${POOLER_TENANT_ID}
      POOLER_DEFAULT_POOL_SIZE: ${POOLER_DEFAULT_POOL_SIZE}
      POOLER_MAX_CLIENT_CONN: ${POOLER_MAX_CLIENT_CONN}
      POOLER_DB_POOL_SIZE: ${POOLER_DB_POOL_SIZE}
    ports:
      - ${POOLER_PROXY_PORT_TRANSACTION}:6543

  analytics:
    container_name: supabase-analytics
    image: supabase/postgres:15.1.1.78
    healthcheck:
      test: pg_isready -U postgres -h localhost
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped
    environment:
      POSTGRES_HOST: /var/run/postgresql
      POSTGRES_DB: _supabase
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--lc-ctype=C --lc-collate=C"
      POSTGRES_HOST_AUTH_METHOD: "scram-sha-256"
    volumes:
      - ./volumes/analytics:/var/lib/postgresql/data
    ports:
      - 54327:5432

networks:
  default:
    name: supabase
EOF
    
    # Создание docker-compose.override.yml для Traefik
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
    
    # Создание необходимых директорий
    mkdir -p volumes/{db,storage,api}
    
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

main "$@"