#!/usr/bin/env bash
# install-wp.sh — Установка WordPress + MariaDB + phpMyAdmin за Traefik (external network: proxy)
# ОС: Ubuntu 22.04+ / Linux. Требуется Docker Engine и плагин docker compose v2.
# Особенности:
#  - Traefik уже запущен отдельно и использует внешнюю сеть "proxy".
#  - phpMyAdmin защищён Basic Auth через файл (/auth/.htpasswd) — без подстановок $, надёжно.
#  - Секреты (MariaDB, WP salts) и удобные поля (логин/пароль BasicAuth) пишутся в ./wp/.env.

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------ Утилиты вывода/ошибок ------------------------
log()  { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "[%s] [WARN] %s\n" "$(date +'%F %T')" "$*" >&2; }
fail() { printf "[%s] [ERROR] %s\n" "$(date +'%F %T')" "$*" >&2; exit 1; }

on_err() {
  local ec=$?
  fail "Скрипт завершился с ошибкой (код: ${ec}). Проверьте вывод выше."
}
trap on_err ERR

need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Не найдена команда '$1'. Установите и повторите."; }

# ------------------------ Проверки окружения ------------------------
need_cmd docker
need_cmd openssl
if ! docker compose version >/dev/null 2>&1; then
  fail "Плагин 'docker compose' не найден. Установите Docker Compose v2."
fi

# Тихо подтянем базовый образ (для генерации htpasswd внутри контейнера)
docker pull alpine:3 >/dev/null || warn "Не удалось заранее подтянуть alpine:3 — будет скачан на лету."

# ------------------------ Сеть proxy (Traefik) ------------------------
ensure_proxy_network() {
  if ! docker network inspect proxy >/dev/null 2>&1; then
    read -r -p "Внешняя сеть 'proxy' не найдена. Создать её? [y/N]: " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      docker network create proxy >/dev/null || fail "Не удалось создать сеть 'proxy'."
      log "Создана внешняя сеть 'proxy'."
    else
      fail "Нужна внешняя сеть 'proxy'. Создайте: docker network create proxy"
    fi
  fi
}
ensure_proxy_network

# ------------------------ Ввод домена ------------------------
read -r -p "Введите домен для WordPress (например, example.com): " WP_DOMAIN
[[ -n "${WP_DOMAIN}" ]] || fail "Домен не может быть пустым."
if ! [[ "${WP_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  fail "Некорректный домен: ${WP_DOMAIN}"
fi

# ------------------------ Подготовка рабочей директории ------------------------
WORKDIR="wp"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Защитный umask: секреты получат 600/700
umask 077

# ------------------------ Генерация значений ------------------------
gen_secret_b64() { openssl rand -base64 48 | tr -d '\n'; }
gen_secret_hex() { openssl rand -hex 16 | tr -d '\n'; }

# .env: если есть — дополним, если нет — создадим
touch .env

put_env_if_absent() {
  local key="$1" val="$2"
  if ! grep -qE "^${key}=" .env; then
    printf "%s=%s\n" "$key" "$val" >> .env
  fi
}

# Базовые переменные
put_env_if_absent "WP_DOMAIN"              "${WP_DOMAIN}"
put_env_if_absent "TRAEFIK_CERT_RESOLVER"  "letsencrypt"

# MariaDB
put_env_if_absent "DB_NAME"          "wordpress"
put_env_if_absent "DB_USER"          "wp_user"
put_env_if_absent "DB_PASSWORD"      "$(gen_secret_b64)"
put_env_if_absent "DB_ROOT_PASSWORD" "$(gen_secret_b64)"

# WordPress salts/keys
put_env_if_absent "WP_AUTH_KEY"          "$(gen_secret_b64)"
put_env_if_absent "WP_SECURE_AUTH_KEY"   "$(gen_secret_b64)"
put_env_if_absent "WP_LOGGED_IN_KEY"     "$(gen_secret_b64)"
put_env_if_absent "WP_NONCE_KEY"         "$(gen_secret_b64)"
put_env_if_absent "WP_AUTH_SALT"         "$(gen_secret_b64)"
put_env_if_absent "WP_SECURE_AUTH_SALT"  "$(gen_secret_b64)"
put_env_if_absent "WP_LOGGED_IN_SALT"    "$(gen_secret_b64)"
put_env_if_absent "WP_NONCE_SALT"        "$(gen_secret_b64)"

# ------------------------ Basic Auth через файл ------------------------
mkdir -p auth
# Сохраним user/pass в .env (для удобного вывода в конце)
put_env_if_absent "PMA_BASIC_AUTH_USER"  "admin"
put_env_if_absent "PMA_BASIC_AUTH_PASS"  "$(gen_secret_hex)"

# Поднимем переменные окружения из .env
# shellcheck disable=SC2046
set -a && source .env && set +a

# Сгенерируем файл auth/.htpasswd (bcrypt, cost=10) внутри контейнера Alpine
# Устанавливаем apache2-utils (в нём есть htpasswd) и генерируем файл.
docker run --rm -v "$PWD/auth:/work" alpine:3 sh -c \
  "apk add --no-cache apache2-utils >/dev/null && htpasswd -nbBC 10 '${PMA_BASIC_AUTH_USER}' '${PMA_BASIC_AUTH_PASS}' > /work/.htpasswd"

chmod 600 auth/.htpasswd
log "Файл auth/.htpasswd создан. Данные BasicAuth (логин/пароль) сохранены в .env."

# ------------------------ docker-compose.yml ------------------------
compose_needs_write=true
if [[ -f docker-compose.yml ]]; then
  read -r -p "Найден docker-compose.yml. Перезаписать свежей версией? [y/N]: " ow
  if [[ ! "${ow:-N}" =~ ^[Yy]$ ]]; then
    compose_needs_write=false
    log "Оставляем существующий docker-compose.yml без изменений."
  fi
fi

if [[ "${compose_needs_write}" == "true" ]]; then
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

      # www -> apex редирект
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
      - PMA_ARBITRARY=0
      - UPLOAD_LIMIT=64M
      - PMA_ABSOLUTE_URI=https://pma.${WP_DOMAIN}/
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"

      - "traefik.http.routers.pma.rule=Host(`pma.${WP_DOMAIN}`)"
      - "traefik.http.routers.pma.entrypoints=websecure"
      - "traefik.http.routers.pma.tls=true"
      - "traefik.http.routers.pma.tls.certresolver=${TRAEFIK_CERT_RESOLVER}"

      # Basic Auth через файл (устойчиво к '$')
      - "traefik.http.middlewares.pma-auth.basicauth.usersfile=/auth/.htpasswd"
      - "traefik.http.routers.pma.middlewares=pma-auth@docker"

    volumes:
      - wp_data:/var/www/html
      - ./auth:/auth:ro
    networks:
      - backend
      - proxy

volumes:
  db_data:
  wp_data:

networks:
  backend:
    name: wp-backend
    internal: true
  proxy:
    external: true
YAML
  log "Создан свежий docker-compose.yml."
fi

# ------------------------ Запуск стека ------------------------
log "Загрузка образов (docker compose pull)..."
docker compose pull

log "Старт стека (docker compose up -d)..."
docker compose up -d

# ------------------------ Вывод итогов ------------------------
# перечитаем .env для корректного вывода
# shellcheck disable=SC2046
set -a && source .env && set +a

echo
echo "================= ДАННЫЕ ДЛЯ ВХОДА ================="
echo "WordPress:"
echo "  URL: https://${WP_DOMAIN}"
echo "  DB_HOST: db"
echo "  DB_NAME: ${DB_NAME}"
echo "  DB_USER: ${DB_USER}"
echo "  DB_PASSWORD: ${DB_PASSWORD}"
echo
echo "phpMyAdmin:"
echo "  URL: https://pma.${WP_DOMAIN}"
echo "  BasicAuth Login: ${PMA_BASIC_AUTH_USER}"
echo "  BasicAuth Password: ${PMA_BASIC_AUTH_PASS}"
echo "  DB_USER: ${DB_USER}"
echo "  DB_PASSWORD: ${DB_PASSWORD}"
echo "===================================================="
echo
echo "Примечания:"
echo " - Убедитесь, что DNS для ${WP_DOMAIN} и pma.${WP_DOMAIN} указывает на этот сервер."
echo " - В Traefik должен быть entrypoint 'websecure' и certresolver '${TRAEFIK_CERT_RESOLVER}'."
echo " - Файл ./wp/.env содержит секреты; ./wp/auth/.htpasswd — файл хешей для BasicAuth (read-only в контейнере)."
