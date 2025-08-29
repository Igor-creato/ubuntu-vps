#!/usr/bin/env bash
# install-supabase-traefik.sh
# Автонастройка self-hosted Supabase (full stack) + Traefik (внешняя сеть proxy) + доступ к PgBouncer для n8n.
# - Клонирует официальную репу Supabase и копирует ./docker/* в ./supabase
# - Генерирует .env по docker/.env.example (JWT, anon/service ключи, пароли)
# - Создаёт override docker-compose.traefik.yml:
#     * Traefik-лейблы для шлюза (kong)
#     * Подключение pgbouncer к внешней сети 'proxy' (без публикации портов)
# - Запускает docker compose (pull + up -d)
#
# Требования: docker, "docker compose" (plugin), git, openssl, sed, awk
# OS: Ubuntu 22.04+ (проверено)

set -Eeuo pipefail

### ========= Конфиг по умолчанию =========
PROJECT_DIR="${PWD}/supabase"           # куда сложим compose и .env
REPO_URL="https://github.com/supabase/supabase.git"
TRAEFIK_NETWORK="proxy"                 # внешняя сеть traefik (общая с n8n)
ROUTER_NAME="supabase"                  # имя роутера/сервиса в Traefik
KONG_HTTP_PORT_DEFAULT="8000"
KONG_HTTPS_PORT_DEFAULT="8443"

### ========= Утилиты/проверки =========
fail() { echo "[ERROR] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Не найдено: $1"; }

need git
need docker
if ! docker compose version >/dev/null 2>&1; then
  fail "Не найден docker compose plugin. Инструкция: https://docs.docker.com/engine/install/"
fi
need openssl
need sed
need awk

### ========= Ввод домена =========
echo "Введите домен для Дашборда Supabase (FQDN), например: supabase.example.com"
read -r -p "Домен: " DASHBOARD_FQDN
[[ -n "${DASHBOARD_FQDN// }" ]] || fail "Домен не может быть пустым."
DASHBOARD_FQDN="${DASHBOARD_FQDN,,}"   # в нижний регистр

# certresolver в Traefik. По-умолчанию — letsencrypt (как в твоём Traefik compose).
TRAEFIK_CERT_RESOLVER="${TRAEFIK_CERT_RESOLVER:-letsencrypt}"

### ========= Проверка внешней сети Traefik =========
if ! docker network ls --format '{{.Name}}' | grep -qx "${TRAEFIK_NETWORK}"; then
  fail "Внешняя сеть '${TRAEFIK_NETWORK}' не найдена. Создайте её заранее: docker network create ${TRAEFIK_NETWORK}"
fi

### ========= Подготовка проекта =========
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "[INFO] Клонирую официальную репу Supabase (только последняя ревизия)..."
git clone --depth 1 "$REPO_URL" "$TMP_DIR/supabase"

echo "[INFO] Создаю каталог проекта: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
echo "[INFO] Копирую ./docker/* из репозитория в проект..."
cp -R "$TMP_DIR/supabase/docker/." "$PROJECT_DIR/"

cd "$PROJECT_DIR"

# Определяем, как называется пулер в этом compose: supavisor / pooler / pgbouncer
detect_pooler() {
  local name=""
  if grep -qE '^\s*supavisor:\s*$' docker-compose.yml; then
    name="supavisor"
  elif grep -qE '^\s*pooler:\s*$' docker-compose.yml; then
    name="pooler"
  elif grep -qE '^\s*pgbouncer:\s*$' docker-compose.yml; then
    name="pgbouncer"
  fi
  printf '%s' "$name"
}

POOLER_SERVICE="$(detect_pooler)"
[[ -n "$POOLER_SERVICE" ]] || fail "Не найден сервис пулера (supavisor/pooler/pgbouncer) в docker-compose.yml"

# Порты и формат логина для разных пулеров
case "$POOLER_SERVICE" in
  supavisor|pooler)
    POOLER_HOST="$POOLER_SERVICE"
    POOLER_PORT_SESSION=5432
    POOLER_PORT_TX=6543
    POOLER_USER="postgres.${POOLER_TENANT_ID}"   # важно для Supavisor
    ;;
  pgbouncer)
    POOLER_HOST="pgbouncer"
    POOLER_PORT_SESSION=6432
    POOLER_PORT_TX=""
    POOLER_USER="postgres"
    ;;
esac


### ========= Работа с .env (на базе .env.example) =========
[[ -f ".env.example" ]] || [[ -f ".env" ]] || fail ".env.example не найден в $PROJECT_DIR"
if [[ -f ".env.example" ]]; then
  cp -f .env.example .env
else
  cp -f .env ".env.backup.$(date +%Y%m%d-%H%M%S)"
fi

umask 077

# Утилиты генерации
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
rand_b64url() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '='; }
rand_hex() { openssl rand -hex "$1"; }

# Мини-генератор HS256 JWT
make_jwt() {
  local role="$1" secret="$2" exp_in="$3"
  local iat exp header payload header_b64 payload_b64 sign
  iat="$(date +%s)"; exp="$((iat + exp_in))"
  header='{"alg":"HS256","typ":"JWT"}'
  payload=$(printf '{"role":"%s","iat":%d,"exp":%d,"iss":"supabase","aud":"authenticated"}' "$role" "$iat" "$exp")
  header_b64="$(printf '%s' "$header" | b64url)"
  payload_b64="$(printf '%s' "$payload" | b64url)"
  sign="$(printf '%s' "${header_b64}.${payload_b64}" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)"
  printf '%s.%s.%s' "$header_b64" "$payload_b64" "$sign"
}

# set_env VAR VAL
set_env() {
  local var="$1" val="$2" esc
  esc="$(printf '%s' "$val" | sed -e 's/[&/\]/\\&/g')"
  if grep -qE "^${var}=" .env; then
    sed -i -E "s|^${var}=.*|${var}=${esc}|" .env
  else
    printf '%s=%s\n' "$var" "$val" >> .env
  fi
}

echo "[INFO] Генерирую секреты и ключи..."

POSTGRES_PASSWORD="$(rand_b64url 32)"
JWT_SECRET="$(rand_hex 32)"
ANON_KEY="$(make_jwt "anon" "$JWT_SECRET" $((60*60*24*365*5)))"
SERVICE_ROLE_KEY="$(make_jwt "service_role" "$JWT_SECRET" $((60*60*24*365*5)))"

DASHBOARD_USERNAME="admin"
DASHBOARD_PASSWORD="$(rand_b64url 24)"

SUPABASE_URL_EXTERNAL="https://${DASHBOARD_FQDN}"

POOLER_TENANT_ID="tenant-$(rand_hex 4)"
SECRET_KEY_BASE="$(rand_hex 32)"
LOGFLARE_PRIVATE_ACCESS_TOKEN="$(rand_hex 16)"

set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
set_env "JWT_SECRET" "$JWT_SECRET"
set_env "ANON_KEY" "$ANON_KEY"
set_env "SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY"

set_env "SUPABASE_PUBLIC_URL" "$SUPABASE_URL_EXTERNAL"
set_env "API_EXTERNAL_URL" "$SUPABASE_URL_EXTERNAL"
set_env "SITE_URL" "$SUPABASE_URL_EXTERNAL"

set_env "DASHBOARD_USERNAME" "$DASHBOARD_USERNAME"
set_env "DASHBOARD_PASSWORD" "$DASHBOARD_PASSWORD"

set_env "POOLER_TENANT_ID" "$POOLER_TENANT_ID"
set_env "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
set_env "LOGFLARE_PRIVATE_ACCESS_TOKEN" "$LOGFLARE_PRIVATE_ACCESS_TOKEN"

set_env "KONG_HTTP_PORT" "$KONG_HTTP_PORT_DEFAULT"
set_env "KONG_HTTPS_PORT" "$KONG_HTTPS_PORT_DEFAULT"

### ========= Traefik + PgBouncer override =========
# kong — публикуем через Traefik; pgbouncer — просто присоединяем к внешней сети 'proxy'
cat > docker-compose.traefik.yml <<YAML
services:
  kong:
    ports: []
    networks:
      - default
      - ${TRAEFIK_NETWORK}
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${TRAEFIK_NETWORK}"
      - "traefik.http.routers.${ROUTER_NAME}.rule=Host(\`${DASHBOARD_FQDN}\`)"
      - "traefik.http.routers.${ROUTER_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${ROUTER_NAME}.tls=true"
      - "traefik.http.routers.${ROUTER_NAME}.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"
      - "traefik.http.services.${ROUTER_NAME}.loadbalancer.server.port=${KONG_HTTP_PORT_DEFAULT}"

  ${POOLER_SERVICE}:          # <-- вместо "pgbouncer"
    networks:
      - default
      - ${TRAEFIK_NETWORK}

networks:
  ${TRAEFIK_NETWORK}:
    external: true
YAML

### ========= Запуск =========
echo "[INFO] Тяну образы..."
docker compose pull

echo "[INFO] Запускаю Supabase стек (с override Traefik/PgBouncer)..."
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d

echo
echo "================= ГОТОВО ================="
echo "Дашборд:         ${SUPABASE_URL_EXTERNAL}"
echo "Basic Auth:      ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
echo
echo "JWT secret:      ${JWT_SECRET}"
echo "anon key:        ${ANON_KEY}"
echo "service key:     ${SERVICE_ROLE_KEY}"
echo
echo "Postgres (внутри docker-сети):"
echo "  роль:          postgres"
echo "  пароль:        ${POSTGRES_PASSWORD}"
echo "  доступ:        через PgBouncer (prod-подход), без публикации наружу"
echo
echo "n8n → Supabase через PgBouncer (сеть '${TRAEFIK_NETWORK}'):"
echo "  Host:          pgbouncer"
echo "  Port:          6432"
echo "  DB:            postgres"
echo "  User:          postgres"
echo "  Password:      ${POSTGRES_PASSWORD}"
echo "  DSN:           postgresql://postgres:${POSTGRES_PASSWORD}@pgbouncer:6432/postgres?sslmode=disable"
echo
echo "Файлы:"
echo "  compose:       ${PROJECT_DIR}/docker-compose.yml (+ docker-compose.traefik.yml)"
echo "  env:           ${PROJECT_DIR}/.env"
echo
echo "Подсказки:"
echo "  - Контейнеры в РАЗНЫХ compose-проектах видят друг друга в общей внешней сети '${TRAEFIK_NETWORK}'."
echo "  - В compose n8n добавь: networks: [${TRAEFIK_NETWORK}] и используй Host 'pgbouncer'."
echo "  - Проверь, что у 'kong' и 'pgbouncer' НЕТ опубликованных портов на хост."
echo "=========================================="
