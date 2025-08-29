#!/usr/bin/env bash
# install-xray.sh — Разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray,
# подключает к внешней сети 'proxy' и поднимает локальные прокси HTTP(3128)/SOCKS5(1080) ДЛЯ КОНТЕЙНЕРОВ.
# Порты наружу (на хост) не публикуются.
#
# Документация:
# - Docker / Compose: https://docs.docker.com/
# - Xray (VLESS):     https://xtls.github.io/

set -Eeuo pipefail

# ---------- Константы/дефолты ----------
XRAY_DIR="${HOME}/xray"
EXT_NET="proxy"                  # внешняя сеть docker
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:latest"
HTTP_PORT=3128                   # внутри docker-сети
SOCKS_PORT=1080

# Будут запрошены интерактивно (можно передать через переменные окружения)
SERVER_ADDR="${SERVER_ADDR:-}"
SERVER_PORT="${SERVER_PORT:-443}"
VLESS_UUID="${VLESS_UUID:-}"
TRANSPORT="${TRANSPORT:-ws}"     # ws|tcp
TLS_ENABLE="${TLS_ENABLE:-true}" # true|false
WS_PATH="${WS_PATH:-/vless}"

log(){ echo -e "[\e[34mINFO\e[0m] $*"; }
err(){ echo -e "[\e[31mERROR\e[0m] $*" >&2; }

# ---------- Проверки окружения ----------
command -v docker >/dev/null 2>&1 || { err "Не найден docker. Установка: https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' недоступен. Инструкция: https://docs.docker.com/compose/install/linux/"; exit 1; }
docker network inspect "$EXT_NET" >/dev/null 2>&1 || { err "Сеть '$EXT_NET' не найдена. Текущие сети: $(docker network ls --format '{{.Name}}' | tr '\n' ' ')"; exit 1; }

# ---------- Сбор параметров ----------
[[ -n "$SERVER_ADDR" ]] || read -rp "Домен/IP VLESS-сервера (Нидерланды): " SERVER_ADDR
read -rp "Порт VLESS [${SERVER_PORT}]: " _p || true; SERVER_PORT="${_p:-$SERVER_PORT}"

if [[ -z "$VLESS_UUID" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    VLESS_UUID="$(uuidgen)"
    log "Сгенерирован UUID: $VLESS_UUID"
  else
    read -rp "UUID пользователя VLESS: " VLESS_UUID
  fi
fi

read -rp "Транспорт (ws|tcp) [${TRANSPORT}]: " _t || true; TRANSPORT="${_t:-$TRANSPORT}"
read -rp "TLS (true|false) [${TLS_ENABLE}]: " _tls || true; TLS_ENABLE="${_tls:-$TLS_ENABLE}"
if [[ "${TRANSPORT,,}" == "ws" ]]; then
  read -rp "WS path [${WS_PATH}]: " _w || true; WS_PATH="${_w:-$WS_PATH}"
fi

# ---------- Подготовка каталогов ----------
log "Создаю каталог: ${XRAY_DIR}/xray"
mkdir -p "${XRAY_DIR}/xray"

# ---------- Формируем streamSettings ----------
if [[ "${TRANSPORT,,}" == "ws" ]]; then
  if [[ "${TLS_ENABLE,,}" == "true" ]]; then
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "ws",
"security": "tls",
"tlsSettings": { "serverName": "${SERVER_ADDR}", "allowInsecure": false },
"wsSettings": { "path": "${WS_PATH}" }
EOF
  else
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "ws",
"security": "none",
"wsSettings": { "path": "${WS_PATH}" }
EOF
  fi
else # tcp
  if [[ "${TLS_ENABLE,,}" == "true" ]]; then
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "tcp",
"security": "tls",
"tlsSettings": { "serverName": "${SERVER_ADDR}", "allowInsecure": false }
EOF
  else
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "tcp",
"security": "none"
EOF
  fi
fi

# ---------- Пишем config.json ----------
cat > "${XRAY_DIR}/xray/config.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "http-in",  "port": ${HTTP_PORT},  "listen": "0.0.0.0", "protocol": "http" },
    { "tag": "socks-in", "port": ${SOCKS_PORT}, "listen": "0.0.0.0", "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_ADDR}",
            "port": ${SERVER_PORT},
            "users": [
              { "id": "${VLESS_UUID}", "encryption": "none", "flow": "" }
            ]
          }
        ]
      },
      "streamSettings": { ${STREAM_SETTINGS} }
    },
    { "protocol": "freedom",  "tag": "direct" },
    { "protocol": "blackhole","tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["http-in","socks-in"], "outboundTag": "vless-out" }
    ]
  }
}
JSON

# ---------- Пишем docker-compose.yml ----------
cat > "${XRAY_DIR}/docker-compose.yml" <<YAML

services:
  ${SERVICE_NAME}:
    image: ${XRAY_IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    command: ["-config", "/etc/xray/config.json"]
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
    # ВАЖНО: порты наружу не открываем. Прокси доступны ТОЛЬКО контейнерам в сети '${EXT_NET}' по имени '${SERVICE_NAME}'.
    # ports:
    #   - "${HTTP_PORT}:${HTTP_PORT}"
    #   - "${SOCKS_PORT}:${SOCKS_PORT}"

networks:
  default:
    name: ${EXT_NET}
    external: true
YAML

# ---------- Запуск ----------
log "Запускаю стек в ${XRAY_DIR} ..."
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
docker compose ps
popd >/dev/null

log "Проверка сети контейнера '${SERVICE_NAME}':"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

cat <<'TIP'

Готово ✅

Подключи ТОЛЬКО n8n к прокси, добавив в его docker-compose:

  environment:
    HTTP_PROXY:  "http://xray-client:3128"
    HTTPS_PROXY: "http://xray-client:3128"
    NO_PROXY:    "localhost,127.0.0.1,::1,n8n,postgres,traefik,wp-app,wp-db,wp-pma,supabase-db,supabase-pooler,supabase-auth,supabase-rest,supabase-realtime,supabase-storage,supabase-studio,supabase-meta,supabase-edge-functions,supabase-analytics,supabase-imgproxy,supabase-vector,supabase-kong,realtime-dev.supabase-realtime"

Требования:
- и n8n, и xray-client должны быть в сети 'proxy'.
- Проверить из n8n (внутри контейнера, команды с шела):
    wget -qO- https://ifconfig.io || curl -s https://ifconfig.io
    # принудительно через прокси:
    wget -qO- --proxy=http://xray-client:3128 https://ifconfig.io || curl -x http://xray-client:3128 -s https://ifconfig.io

Если имя xray-client не резолвится внутри n8n — проверь, что оба контейнера в сети 'proxy':
  docker inspect xray-client --format '{{json .NetworkSettings.Networks}}'
  docker inspect <имя-контейнера-n8n> --format '{{json .NetworkSettings.Networks}}'

TIP
