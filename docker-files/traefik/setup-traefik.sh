#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BASE_DIR="$HOME/traefik"
ENV_FILE="$BASE_DIR/.env"
SECRETS_DIR="$BASE_DIR/secrets"

mkdir -p "$BASE_DIR"/{secrets,logs}

# ──────────────────────────────────────────────────────────────
# 1. Проверяем существующий .env
if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}Найден существующий .env:${NC}"
    cat "$ENV_FILE"
    echo
    read -rp "Использовать текущие данные? [Y/n]: " USE_OLD
    if [[ ! $USE_OLD =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Оставляем текущие данные и перезапускаем…${NC}"
        cd "$BASE_DIR"
        docker compose pull
        docker compose up -d
        exit 0
    fi
fi

# ──────────────────────────────────────────────────────────────
# 2. Запрашиваем новые данные
read -rp "E-mail для Let's Encrypt: " ACME_EMAIL
read -rp "Домен для дашборда Traefik: " TRAEFIK_DOMAIN

BASIC_AUTH_USER="admin"
BASIC_AUTH_PASS=$(openssl rand -base64 16)
echo -e "${GREEN}Сгенерированный пароль для ${BASIC_AUTH_USER}: ${BASIC_AUTH_PASS}${NC}"

# ──────────────────────────────────────────────────────────────
# 3. Перезаписываем .env
cat > "$ENV_FILE" <<EOF
ACME_EMAIL=$ACME_EMAIL
TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN
BASIC_AUTH_USER=$BASIC_AUTH_USER
BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF

# ──────────────────────────────────────────────────────────────
# 4. Скачиваем/обновляем compose и traefik.yml без перезаписи volumes
COMPOSE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/docker-compose.yml"
TRAEFIK_YML_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/traefik.yml"

curl -sSL "$COMPOSE_URL" -o "$BASE_DIR/docker-compose.yml"
curl -sSL "$TRAEFIK_YML_URL" -o "$BASE_DIR/traefik.yml"

# ──────────────────────────────────────────────────────────────
# 5. Создаём htpasswd только если его нет или данные изменились
docker run --rm -v "$SECRETS_DIR:/out" \
  httpd:alpine \
  htpasswd -nbB "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS" | cut -d: -f2 | \
  sed "s/^/${BASIC_AUTH_USER}:/" > "$SECRETS_DIR/dashboard.htpasswd"

# ──────────────────────────────────────────────────────────────
# 6. Запуск / перезапуск
cd "$BASE_DIR"
docker compose pull
docker compose up -d

echo -e "${GREEN}Traefik запущён! Дашборд: https://${TRAEFIK_DOMAIN}${NC}"
