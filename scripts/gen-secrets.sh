#!/usr/bin/env bash
# Случайные 32-байтные строки base64
# Пишем в .env

# Если .env уже существует — не перезаписываем POSTGRES_PASSWORD
if [[ -f .env ]] && grep -q '^POSTGRES_PASSWORD=' .env; then
  POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' .env | cut -d '=' -f2- | tr -d '\n')
else
  POSTGRES_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
fi
JWT_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
ANON_KEY="$(openssl rand -base64 32 | tr -d '\n')"
SERVICE_ROLE_KEY="$(openssl rand -base64 32 | tr -d '\n')"
DASHBOARD_USERNAME="supabase"
DASHBOARD_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
VAULT_ENC_KEY="$(openssl rand -base64 32 | tr -d '\n')"
SMTP_PASS="$(openssl rand -base64 32 | tr -d '\n')"

cat > .env <<EENV
###############  REQUIRED  ################
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
JWT_SECRET="$JWT_SECRET"
ANON_KEY="$ANON_KEY"
SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

###############  TRAEFIK / DOMAINS  ################
STUDIO_URL=supabase.autmatization-bot.ru
API_URL=supabase.autmatization-bot.ru
PUBLIC_REST_URL=https://supabase.autmatization-bot.ru/rest/v1

###############  DASHBOARD  ################
DASHBOARD_USERNAME="$DASHBOARD_USERNAME"
DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD"

###############  SMTP (пример через Gmail)  ################
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=your_bot@gmail.com
SMTP_PASS="$SMTP_PASS"
SMTP_ADMIN_EMAIL=your_bot@gmail.com

###############  ДОПОЛНИТЕЛЬНЫЕ  ################
SITE_URL=https://supabase.autmatization-bot.ru
ADDITIONAL_REDIRECT_URLS=
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=true

# ----------------------------------------------------------
# Добавляем обязательные дефолты, которых не хватает
# ----------------------------------------------------------

###############  ОБЯЗАТЕЛЬНЫЕ ДЕФОЛТЫ  ################
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_DB=postgres
DOCKER_SOCKET_LOCATION=/var/run/docker.sock
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443
SECRET_KEY_BASE="$SECRET_KEY_BASE"
VAULT_ENC_KEY="$VAULT_ENC_KEY"
API_EXTERNAL_URL=https://supabase.autmatization-bot.ru
SUPABASE_PUBLIC_URL=https://supabase.autmatization-bot.ru

# «Тихие» переменные, чтобы не валить стек
PGRST_DB_SCHEMAS=public
IMGPROXY_ENABLE_WEBP_DETECTION=true
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
ENABLE_ANONYMOUS_USERS=false
DISABLE_SIGNUP=false
JWT_EXPIRY=3600
SMTP_SENDER_NAME=Supabase
STUDIO_DEFAULT_PROJECT=default
STUDIO_DEFAULT_ORGANIZATION=default
POOLER_TENANT_ID=default
POOLER_DEFAULT_POOL_SIZE=10
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=10
POOLER_PROXY_PORT_TRANSACTION=5433
FUNCTIONS_VERIFY_JWT=true

# Logflare (заглушки, если не используем)
LOGFLARE_PUBLIC_ACCESS_TOKEN=dummy
LOGFLARE_PRIVATE_ACCESS_TOKEN=dummy

# MAILER пути (заглушки)
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify
EENV

echo "===   Секреты сгенерированы и записаны в .env   ==="
echo "Supabase Dashboard:  ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
echo "Postgres Password: ${POSTGRES_PASSWORD}"
