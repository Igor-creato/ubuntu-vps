#!/usr/bin/env bash
# install-supabase-traefik.sh
# Автонастройка self-hosted Supabase (full stack) + Traefik (внешняя сеть proxy).
# - Клонирует официальную репу Supabase и копирует ./docker/* в ./supabase
# - Генерирует .env по docker/.env.example (JWT, anon/service ключи, пароли)
# - Создаёт override docker-compose.traefik.yml с Traefik-лейблами для шлюза (kong)
# - Запускает docker compose (pull + up -d)
#
# Документация Supabase (официально):
#   - Self-Hosting with Docker, доступ Studio через API gateway :8000
#   - Обязательные секреты и базовая auth для Dashboard
#   https://supabase.com/docs/guides/self-hosting/docker
#
# Требования: docker, "docker compose" (plugin), git, openssl, sed, awk
# OS: Linux/macOS (проверено под Ubuntu 22.04+)
set -Eeuo pipefail

### ========= Конфиг по умолчанию =========
PROJECT_DIR="${PWD}/supabase"           # куда сложим compose и .env
REPO_URL="https://github.com/supabase/supabase.git"
TRAEFIK_NETWORK="proxy"                 # внешняя сеть traefik
ROUTER_NAME="supabase"                  # имя роутера/сервиса в Traefik
DEFAULT_RESOLVER=""                     # можно задать, например: letsencrypt
KONG_HTTP_PORT_DEFAULT="8000"
KONG_HTTPS_PORT_DEFAULT="8443"

### ========= Утилиты/проверки =========
fail() { echo "[ERROR] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Не найдено: $1"; }

need git
need docker
# Проверяем docker compose (plugin). Если есть только docker-compose — не используем (устаревшее).
if ! docker compose version >/dev/null 2>&1; then
  fail "Не найден docker compose plugin. Установите по инструкции Docker: https://docs.docker.com/engine/install/"
fi
need openssl
need sed
need awk

### ========= Ввод домена =========
echo "Введите домен для Дашборда Supabase (FQDN), например: supabase.example.com"
read -r -p "Домен: " DASHBOARD_FQDN
[[ -n "${DASHBOARD_FQDN// }" ]] || fail "Домен не может быть пустым."
DASHBOARD_FQDN="${DASHBOARD_FQDN,,}"   # в нижний регистр

# (опционально) задать certresolver, если в Traefik он назван не по-умолчанию.
read -r -p "Имя TLS certresolver для Traefik (Enter — пропустить): " TRAEFIK_CERT_RESOLVER
TRAEFIK_CERT_RESOLVER="${TRAEFIK_CERT_RESOLVER:-$DEFAULT_RESOLVER}"

### ========= Проверка внешней сети Traefik =========
if ! docker network ls --format '{{.Name}}' | grep -qx "${TRAEFIK_NETWORK}"; then
  fail "Внешняя сеть '${TRAEFIK_NETWORK}' не найдена. Создайте её в Traefik заранее."
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
# согласно официальной инструкции: cp -rf supabase/docker/* supabase-project
# https://supabase.com/docs/guides/self-hosting/docker
cp -R "$TMP_DIR/supabase/docker/." "$PROJECT_DIR/"

cd "$PROJECT_DIR"

### ========= Работа с .env (на базе .env.example) =========
[[ -f ".env.example" ]] || [[ -f ".env" ]] || fail ".env.example не найден в $PROJECT_DIR"

# На случай, если в master оно называется ровно ".env.example"
if [[ -f ".env.example" ]]; then
  cp -f .env.example .env
elif [[ -f ".env" ]]; then
  # если из репы приехал уже готовый .env — сделаем бэкап и перезапишем на его основе
  cp -f .env ".env.backup.$(date +%Y%m%d-%H%M%S)"
fi

# Закроем права на секреты
umask 077

# Утилиты генерации секретов и base64url
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
rand_b64url() { # длина в байтах -> base64url
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '='
}
rand_hex() { # длина в байтах -> hex
  openssl rand -hex "$1"
}

# Мини-генератор HS256 JWT (без внешних зависимостей)
# Аргументы: <role> <jwt_secret> <exp_seconds_from_now>
make_jwt() {
  local role="$1" secret="$2" exp_in="$3"
  local iat exp header payload header_b64 payload_b64 sign
  iat="$(date +%s)"
  exp="$((iat + exp_in))"
  header='{"alg":"HS256","typ":"JWT"}'
  # Включим стандартные клеймы и роль
  payload=$(printf '{"role":"%s","iat":%d,"exp":%d,"iss":"supabase","aud":"authenticated"}' "$role" "$iat" "$exp")
  header_b64="$(printf '%s' "$header" | b64url)"
  payload_b64="$(printf '%s' "$payload" | b64url)"
  sign="$(printf '%s' "${header_b64}.${payload_b64}" \
    | openssl dgst -binary -sha256 -hmac "$secret" | b64url)"
  printf '%s.%s.%s' "$header_b64" "$payload_b64" "$sign"
}

# Функция, которая ставит/обновляет строку VAR=VALUE в .env
set_env() {
  local var="$1" val="$2" esc
  # экранируем спецсимволы для sed
  esc="$(printf '%s' "$val" | sed -e 's/[&/\]/\\&/g')"
  if grep -qE "^${var}=" .env; then
    sed -i -E "s|^${var}=.*|${var}=${esc}|" .env
  else
    printf '%s=%s\n' "$var" "$val" >> .env
  fi
}

echo "[INFO] Генерирую секреты и ключи..."

# Обязательные значения по доке (пароль БД, JWT secret, публичные URL, basic-auth для дашборда)
# https://supabase.com/docs/guides/self-hosting/docker
POSTGRES_PASSWORD="$(rand_b64url 32)"
JWT_SECRET="$(rand_hex 32)"                    # >= 32 байт, 64 hex символа (~32 байта)
# Срок жизни для anon/service токенов: 5 лет
ANON_KEY="$(make_jwt "anon" "$JWT_SECRET" $((60*60*24*365*5)))"
SERVICE_ROLE_KEY="$(make_jwt "service_role" "$JWT_SECRET" $((60*60*24*365*5)))"

DASHBOARD_USERNAME="admin"
DASHBOARD_PASSWORD="$(rand_b64url 24)"

SUPABASE_URL_EXTERNAL="https://${DASHBOARD_FQDN}"

# Необязательные, но полезные
POOLER_TENANT_ID="tenant-$(rand_hex 4)"
SECRET_KEY_BASE="$(rand_hex 32)"               # для Realtime
LOGFLARE_PRIVATE_ACCESS_TOKEN="$(rand_hex 16)" # аналитика (пригодится, можно заменить позже)

# Запишем значения в .env (если в .env.example переменная уже есть — перезатрём, иначе добавим)
set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
set_env "JWT_SECRET" "$JWT_SECRET"
set_env "ANON_KEY" "$ANON_KEY"
set_env "SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY"

# Внешние URL (Studio/шлюз и сайт для ссылок в письмах)
set_env "SUPABASE_PUBLIC_URL" "$SUPABASE_URL_EXTERNAL"
set_env "API_EXTERNAL_URL" "$SUPABASE_URL_EXTERNAL"
set_env "SITE_URL" "$SUPABASE_URL_EXTERNAL"

# Базовая аутентификация дашборда через Kong
set_env "DASHBOARD_USERNAME" "$DASHBOARD_USERNAME"
set_env "DASHBOARD_PASSWORD" "$DASHBOARD_PASSWORD"

# Прочее
set_env "POOLER_TENANT_ID" "$POOLER_TENANT_ID"
set_env "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
set_env "LOGFLARE_PRIVATE_ACCESS_TOKEN" "$LOGFLARE_PRIVATE_ACCESS_TOKEN"

# Порты Kong по умолчанию (для внутреннего использования). Публиковать на хост не будем — за нас это делает Traefik.
set_env "KONG_HTTP_PORT" "$KONG_HTTP_PORT_DEFAULT"
set_env "KONG_HTTPS_PORT" "$KONG_HTTPS_PORT_DEFAULT"

# Если используете rootless docker — можно предзадать DOCKER_SOCKET_LOCATION (см. оф. доку)
# set_env "DOCKER_SOCKET_LOCATION" "/run/user/1000/docker.sock"

### ========= Traefik override =========
# Мы убираем публикацию портов у kong и вешаем traefik-лейблы + подключаем внешнюю сеть 'proxy'
cat > docker-compose.traefik.yml <<YAML
services:
  kong:
    ports: []   # отключаем хостовые публикации 8000/8443 (Traefik терминирует снаружи)
    networks:
      - default
      - ${TRAEFIK_NETWORK}
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${TRAEFIK_NETWORK}"

      - "traefik.http.routers.${ROUTER_NAME}.rule=Host(\`${DASHBOARD_FQDN}\`)"
      - "traefik.http.routers.${ROUTER_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${ROUTER_NAME}.tls=true"
      - "traefik.http.services.${ROUTER_NAME}.loadbalancer.server.port=${KONG_HTTP_PORT_DEFAULT}"
YAML

# Добавим certresolver, если указан
if [[ -n "${TRAEFIK_CERT_RESOLVER// }" ]]; then
  sed -i "/tls=true/a \ \ \ \ \ \ - \"traefik.http.routers.${ROUTER_NAME}.tls.certresolver=${TRAEFIK_CERT_RESOLVER}\"" docker-compose.traefik.yml
fi

# Подключим внешнюю сеть
cat >> docker-compose.traefik.yml <<YAML

networks:
  ${TRAEFIK_NETWORK}:
    external: true
YAML

### ========= Запуск =========
echo "[INFO] Тяну образы..."
docker compose pull

echo "[INFO] Запускаю Supabase стек (через Traefik override)..."
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
echo "Postgres:"
echo "  роль:          postgres"
echo "  пароль:        ${POSTGRES_PASSWORD}"
echo "  доступ:        только из docker-сети (по умолчанию). Внешнюю публикацию БД не включаем."
echo
echo "Файлы:"
echo "  compose:       ${PROJECT_DIR}/docker-compose.yml (+ docker-compose.traefik.yml)"
echo "  env:           ${PROJECT_DIR}/.env"
echo
echo "Подсказки:"
echo "  - Убедитесь, что в Traefik настроены entrypoint=websecure и ACME (certresolver), а DNS домена '${DASHBOARD_FQDN}' указывает на сервер."
echo "  - Список обязательных секретов и настройка Studio за пределами localhost — см. оф. доку Supabase."
echo "=========================================="
