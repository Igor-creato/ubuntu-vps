#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BASE_DIR="$HOME/traefik"
ENV_FILE="$BASE_DIR/.env"
SECRETS_DIR="$BASE_DIR/secrets"

mkdir -p "$BASE_DIR"/{secrets,logs}

# ------------------------------------------------------------------
# 1. Загружаем переменные, если файл уже существует
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# 2. Если переменные не заданы — спрашиваем/генерируем
if [[ -z "${ACME_EMAIL:-}" ]] || [[ -z "${TRAEFIK_DOMAIN:-}" ]]; then
    echo -e "${YELLOW}Заполняем/обновляем конфигурацию.${NC}"

    read -rp "E-mail для Let's Encrypt: " ACME_EMAIL_INPUT
    read -rp "Домен для дашборда Traefik: " TRAEFIK_DOMAIN_INPUT

    # используем введённые значения
    ACME_EMAIL="${ACME_EMAIL_INPUT:-${ACME_EMAIL:-}}"
    TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN_INPUT:-${TRAEFIK_DOMAIN:-}}"

    BASIC_AUTH_USER="admin"
    BASIC_AUTH_PASS=$(openssl rand -base64 16)
    echo -e "${GREEN}Сгенерированный пароль для ${BASIC_AUTH_USER}: ${BASIC_AUTH_PASS}${NC}"

    # перезаписываем .env
    cat > "$ENV_FILE" <<EOF
ACME_EMAIL=$ACME_EMAIL
TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN
BASIC_AUTH_USER=$BASIC_AUTH_USER
BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF
else
    echo -e "${YELLOW}Используем существующие данные из .env${NC}"
fi
# создаём внешнюю сеть, если её ещё нет
docker network create traefik-public 2>/dev/null || true

# ------------------------------------------------------------------
# 3. Скачиваем/обновляем compose и traefik.yml
COMPOSE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/docker-compose.yml"
TRAEFIK_YML_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/traefik.yml"

curl -sSL "$COMPOSE_URL" -o "$BASE_DIR/docker-compose.yml"
curl -sSL "$TRAEFIK_YML_URL" -o "$BASE_DIR/traefik.yml"

# ------------------------------------------------------------------
# 4. Создаём htpasswd
docker run --rm -v "$SECRETS_DIR:/out" \
  httpd:alpine \
  htpasswd -nbB "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" | \
  sed "s/^/${BASIC_AUTH_USER}:/" > "$SECRETS_DIR/dashboard.htpasswd"

# ------------------------------------------------------------------
# 5. Запуск / перезапуск
cd "$BASE_DIR"
docker compose pull
docker compose up -d

echo -e "${GREEN}Traefik запущён! Дашборд: https://${TRAEFIK_DOMAIN}${NC}"
