#!/usr/bin/env bash
# install-wp.sh — установка WordPress-стэка за Traefik в сети proxy
# Требования: Docker Engine + docker compose plugin, запущенный Traefik с внешней сетью "proxy".
# ОС: Ubuntu 22.04+ (подойдёт и любая Linux с Docker)

set -Eeuo pipefail

# ---------- функции утилиты ----------
log()   { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
fail()  { printf "[%s] [ERROR] %s\n" "$(date +'%F %T')" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Команда '$1' не найдена. Установите её и повторите."
}

gen_secret() { # base64 без спецсимволов проблемных для env
  openssl rand -base64 48 | tr -d '\n'
}

ensure_proxy_network() {
  if ! docker network inspect proxy >/dev/null 2>&1; then
    read -r -p "Внешняя сеть 'proxy' не найдена. Создать? [y/N]: " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      docker network create proxy || fail "Не удалось создать сеть 'proxy'"
      log "Создана сеть 'proxy'."
    else
      fail "Нужна внешняя сеть 'proxy'. Создайте её вручную: docker network create proxy"
    fi
  fi
}

# ---------- проверки окружения ----------
need_cmd docker
need_cmd openssl
if ! docker compose version >/dev/null 2>&1; then
  fail "Плагин 'docker compose' не найден. Установите Docker Compose v2."
fi

ensure_proxy_network

# ---------- ввод домена ----------
read -r -p "Введите домен для WordPress (например, example.com): " WP_DOMAIN
[[ -n "${WP_DOMAIN}" ]] || fail "Домен не может быть пустым."
# быстрое примитивное правило
if ! [[ "${WP_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  fail "Некорректный домен: ${WP_DOMAIN}"
fi

# ---------- подготовка директории ----------
WORKDIR="wp"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# ---------- создаём .env с безопасными значениями ----------
DB_NAME="wordpress"
DB_USER="wp_user"
DB_PASSWORD="$(gen_secret)"
DB_ROOT_PASSWORD="$(gen_secret)"

TRAEFIK_CERT_RESOLVER="letsencrypt"   # измените при необходимости
PMA_HOSTNAME="pma.${WP_DOMAIN}"

# Ключи/соли WordPress
WP_AUTH_KEY="$(gen_secret)"
WP_SECURE_AUTH_KEY="$(gen_secret)"
WP_LOGGED_IN_KEY="$(gen_secret)"
WP_NONCE_KEY="$(gen_secret)"
WP_AUTH_SALT="$(gen_secret)"
WP_SECURE_AUTH_SALT="$(gen_secret)"
WP_LOGGED_IN_SALT="$(gen_secret)"
WP_NONCE_SALT="$(gen_secret)"

cat > .env <<EOF
# --- Базовые переменные ---
WP_DOMAIN=${WP_DOMAIN}
TRAEFIK_CERT_RESOLVER=${TRAEFIK_CERT_RESOLVER}

# --- База данных ---
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}

# --- WP Keys & Salts ---
WP_AUTH_KEY=${WP_AUTH_KEY}
WP_SECURE_AUTH_KEY=${WP_SECURE_AUTH_KEY}
WP_LOGGED_IN_KEY=${WP_LOGGED_IN_KEY}
WP_NONCE_KEY=${WP_NONCE_KEY}
WP_AUTH_SALT=${WP_AUTH_SALT}
WP_SECURE_AUTH_SALT=${WP_SECURE_AUTH_SALT}
WP_LOGGED_IN_SALT=${WP_LOGGED_IN_SALT}
WP_NONCE_SALT=${WP_NONCE_SALT}
EOF

log "Создан .env с сгенерированными паролями и ключами."

# ---------- кладём docker-compose.yml ----------
# Если файл уже существует, не перезаписываем без согласия.
if [[ -f docker-compose.yml ]]; then
  read -r -p "Найден существующий docker-compose.yml. Перезаписать? [y/N]: " ow
  if [[ "${ow:-N}" =~ ^[Yy]$ ]]; then
    :
  else
    log "Оставляем существующий docker-compose.yml без изменений."
    EXISTING_COMPOSE=true
  fi
fi

if [[ "${EXISTING_COMPOSE:-false}" != "true" ]]; then
  cat > docker-compose.yml <<'YAML'

name: wp-stack

services:
  db:
    image: mariadb:11.4
    container_name: wp-db
    restart: unless-stopped
    environment:
      - MARIADB_DATABASE=${DB_NAME}
      - MARIADB_USER=${DB_USER}
      - MARIADB_PASSWORD=${DB_PASSWORD}
      - MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -u root -p\"${DB_ROOT_PASSWORD}\" || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - backend

  wordpress:
    image: wordpress:latest
    container_name: wp-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - WORDPRESS_DB_HOST=db:3306
      - WORDPRESS_DB_NAME=${DB_NAME}
      - WORDPRESS_DB_USER=${DB_USER}
      - WORDPRESS_DB_PASSWORD=${DB_PASSWORD}
      - WORDPRESS_CONFIG_EXTRA=define('FS_METHOD','direct');
      - AUTH_KEY=${WP_AUTH_KEY}
      - SECURE_AUTH_KEY=${WP_SECURE_AUTH_KEY}
      - LOGGED_IN_KEY=${WP_LOGGED_IN_KEY}
      - NONCE_KEY=${WP_NONCE_KEY}
      - AUTH_SALT=${WP_AUTH_SALT}
      - SECURE_AUTH_SALT=${WP_SECURE_AUTH_SALT}
      - LOGGED_IN_SALT=${WP_LOGGED_IN_SALT}
      - NONCE_SALT=${WP_NONCE_SALT}
    volumes:
      - wp_data:/var/www/html
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"

      - "traefik.http.routers.wp.rule=Host(`${WP_DOMAIN}`)"
      - "traefik.http.routers.wp.entrypoints=websecure"
      - "traefik.http.routers.wp.tls=true"
      - "traefik.http.routers.wp.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"

      - "traefik.http.routers.wp-www.rule=Host(`www.${WP_DOMAIN}`)"
      - "traefik.http.routers.wp-www.entrypoints=websecure"
      - "traefik.http.routers.wp-www.tls=true"
      - "traefik.http.routers.wp-www.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"
      - "traefik.http.middlewares.wp-www-redirect.redirectregex.regex=^https://www\\.(.*)"
      - "traefik.http.middlewares.wp-www-redirect.redirectregex.replacement=https://$1"
      - "traefik.http.middlewares.wp-www-redirect.redirectregex.permanent=true"
      - "traefik.http.routers.wp-www.middlewares=wp-www-redirect@docker"

    networks:
      - backend
      - proxy

  phpmyadmin:
    image: phpmyadmin:latest
    container_name: wp-pma
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PMA_HOST=db
      - PMA_ARBITRARY=0           # запрещает подключение к произвольным хостам
      - UPLOAD_LIMIT=64M
      # (опц.) жёстко задаём абсолютный URL, полезно для прокси:
      - PMA_ABSOLUTE_URI=https://pma.${WP_DOMAIN}/
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.pma.rule=Host(`pma.${WP_DOMAIN}`)"
      - "traefik.http.routers.pma.entrypoints=websecure"
      - "traefik.http.routers.pma.tls=true"
      - "traefik.http.routers.pma.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"

      # --- Basic Auth ---
      - "traefik.http.middlewares.pma-auth.basicauth.users=${PMA_BASIC_AUTH_USERS}"
      - "traefik.http.routers.pma.middlewares=pma-auth@docker"

    networks:
      - backend
      - proxy

YAML
  log "Создан docker-compose.yml."
fi

# ---------- запуск стэка ----------
log "Выполняю: docker compose pull ..."
docker compose pull

log "Выполняю: docker compose up -d ..."
docker compose up -d

log "Готово!"
echo
echo "WordPress:  https://${WP_DOMAIN}"
echo "phpMyAdmin: https://pma.${WP_DOMAIN}"
echo
echo "Если DNS уже указывает на ваш сервер и в Traefik настроен резолвер '${TRAEFIK_CERT_RESOLVER}',"
echo "сертификаты будут выпущены автоматически."
