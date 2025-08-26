#!/usr/bin/env bash
set -euo pipefail

# Цвета
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 1. Создаём структуру каталогов
BASE_DIR="$HOME/traefik"
mkdir -p "$BASE_DIR"/{secrets,logs}

# 2. Запрашиваем данные
read -rp "E-mail для Let's Encrypt: " ACME_EMAIL
read -rp "Домен для дашборда Traefik: " TRAEFIK_DOMAIN

# Генерируем пароль
BASIC_AUTH_USER="admin"
BASIC_AUTH_PASS=$(openssl rand -base64 16)
echo -e "${GREEN}Сгенерированный пароль для ${BASIC_AUTH_USER}: ${BASIC_AUTH_PASS}${NC}"

# 3. Создаём .env
cat > "$BASE_DIR/.env" <<EOF
ACME_EMAIL=$ACME_EMAIL
TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN
BASIC_AUTH_USER=$BASIC_AUTH_USER
BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF

# 4. Скачиваем docker-compose.yml и traefik.yml
COMPOSE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/docker-compose.yml"
TRAEFIK_YML_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/traefik.yml"

curl -sSL "$COMPOSE_URL" -o "$BASE_DIR/docker-compose.yml"
curl -sSL "$TRAEFIK_YML_URL" -o "$BASE_DIR/traefik.yml"

# 5. Создаём htpasswd-файл
docker run --rm -v "$BASE_DIR/secrets:/out" \
  httpd:alpine \
  htpasswd -nbB "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS" | cut -d: -f2 | \
  sed 's/^/admin:/' > "$BASE_DIR/secrets/dashboard.htpasswd"

# 6. Запускаем
cd "$BASE_DIR"
docker compose pull
docker compose up -d

echo -e "${GREEN}Traefik запущён! Дашборд: https://${TRAEFIK_DOMAIN}${NC}"
