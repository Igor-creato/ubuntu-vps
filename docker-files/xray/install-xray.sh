#!/usr/bin/env bash
# install-xray.sh — Разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray.
# - Поднимает HTTP-прокси (3128) и SOCKS5 (1080) ДОСТУПНЫЕ ТОЛЬКО внутри docker-сети 'proxy'
# - Ничего не публикует на хост (без ports:)
# Документация: https://docs.docker.com/ , https://xtls.github.io/
set -Eeuo pipefail

# ===== Настройки по умолчанию =====
XRAY_DIR="${HOME}/xray"
EXT_NET="proxy"                 # внешняя сеть Docker (у тебя уже есть)
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:latest"
HTTP_PORT=3128                  # ВНУТРИ сети docker (без публикации)
SOCKS_PORT=1080

# Будут ЗАПРОШЕНЫ интерактивно:
SERVER_ADDR=""                  # домен/IP VLESS-сервера (NL)
SERVER_PORT="443"               # порт VLESS
VLESS_UUID=""                   # UUID (обязательно вручную)
TRANSPORT="ws"                  # ws | tcp
TLS_ENABLE="true"               # true | false
WS_PATH="/vless"                # только для ws

log(){ echo -e "[\e[34mINFO\e[0m] $*"; }
err(){ echo -e "[\e[31mERROR\e[0m] $*" >&2; }

# ===== Проверки окружения =====
command -v docker >/dev/null 2>&1 || { err "Не найден docker. См. установку: https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' недоступен. См.: https://docs.docker.com/compose/install/linux/"; exit 1; }
docker network inspect "$EXT_NET" >/dev/null 2>&1 || { err "Сеть '$EXT_NET' не найдена. Доступные: $(docker network ls --format '{{.Name}}' | tr '\n' ' ')"; exit 1; }

# ===== Сбор параметров =====
read -rp "Домен/IP VLESS-сервера (Нидерланды): " SERVER_ADDR
while [[ -z "$SERVER_ADDR" ]]; do read -rp "Пусто. Введи домен/IP: " SERVER_ADDR; done

read -rp "Порт VLESS [${SERVER_PORT}]: " _p || true; SERVER_PORT="${_p:-$SERVER_PORT}"

# UUID запрашиваем и валидируем (формат 8-4-4-4-12 hex)
uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
read -rp "UUID пользователя VLESS (формат xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " VLESS_UUID
while [[ ! "$VLESS_UUID" =~ $uuid_re ]]; do
  echo "Неверный формат UUID. Пример: 123e4567-e89b-12d3-a456-426614174000"
  read -rp "UUID: " VLESS_UUID
done

read -rp "Транспорт (ws|tcp) [${TRANSPORT}]: " _t || true; TRANSPORT="${_t:-$TRANSPORT}"
while [[ "$TRANSPORT" != "ws" && "$TRANSPORT" != "tcp" ]]; do
  read -rp "Допустимо 'ws' или 'tcp': " TRANSPORT
done

read -rp "TLS (true|false) [${TLS_ENABLE}]: " _tls || true; TLS_ENABLE="${_tls:-$TLS_ENABLE}"
while [[ "${TLS_ENABLE}" != "true" && "${TLS_ENABLE}" != "false" ]]; do
  read -rp "Введи 'true' или 'false': " TLS_ENABLE
done

if [[ "${TRANSPORT}" == "ws" ]]; then
  read -rp "WS path [${WS_PATH}]: " _w || true; WS_PATH="${_w:-$WS_PATH}"
fi

# ===== Подготовка каталогов =====
log "Готовлю каталог: ${XRAY_DIR}/xray"
mkdir -p "${XRAY_DIR}/xray"

# ===== Формируем streamSettings =====
if [[ "${TRANSPORT}" == "ws" ]]; then
  if [[ "${TLS_ENABLE}" == "true" ]]; then
    STREAM_SETTINGS=$(cat <<EOF
"network": "ws",
"security": "tls",
"tlsSettings": {
  "serverName": "${SERVER_ADDR}",
  "allowInsecure": false
},
"wsSettings": {
  "path": "${WS_PATH}"
}
EOF
)
  else
    STREAM_SETTINGS=$(cat <<EOF
"network": "ws",
"security": "none",
"wsSettings": {
  "path": "${WS_PATH}"
}
EOF
)
  fi
else # tcp
  if [[ "${TLS_ENABLE}" == "true" ]]; then
    STREAM_SETTINGS=$(cat <<EOF
"network": "tcp",
"security": "tls",
"tlsSettings": {
  "serverName": "${SERVER_ADDR}",
  "allowInsecure": false
}
EOF
)
  else
    STREAM_SETTINGS=$(cat <<EOF
"network": "tcp",
"security": "none"
EOF
)
  fi
fi

# ===== Пишем config.json =====
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
      "streamSettings": {
        ${STREAM_SETTINGS}
      }
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

# ===== Пишем docker-compose.yml =====
cat > "${XRAY_DIR}/docker-compose.yml" <<YAML
version: "3.9"

services:
  ${SERVICE_NAME}:
    image: ${XRAY_IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    command: ["-config", "/etc/xray/config.json"]
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
    # Порты наружу НЕ публикуем. Прокси доступны контейнерам в сети '${EXT_NET}' по имени '${SERVICE_NAME}'.
    # ports:
    #   - "${HTTP_PORT}:${HTTP_PORT}"
    #   - "${SOCKS_PORT}:${SOCKS_PORT}"

networks:
  default:
    name: ${EXT_NET}
    external: true
YAML

# ===== Запуск =====
log "Запускаю стек в ${XRAY_DIR} ..."
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
docker compose ps
popd >/dev/null

log "Проверка: контейнер должен быть в сети '${EXT_NET}'"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

cat <<'NEXT'

Готово ✅

Подключение ТОЛЬКО для n8n (в его docker-compose):
  environment:
    HTTP_PROXY:  "http://xray-client:3128"
    HTTPS_PROXY: "http://xray-client:3128"
    NO_PROXY:    "localhost,127.0.0.1,::1,n8n,postgres,traefik,wp-app,wp-db,wp-pma,supabase-db,supabase-pooler,supabase-auth,supabase-rest,supabase-realtime,supabase-storage,supabase-studio,supabase-meta,supabase-edge-functions,supabase-analytics,supabase-imgproxy,supabase-vector,supabase-kong,realtime-dev.supabase-realtime"

Проверка из n8n (в контейнере, у n8n обычно /bin/sh, а не bash):
  cd ~/n8n
  docker compose exec n8n sh -lc 'env | grep -E "HTTP_PROXY|HTTPS_PROXY|NO_PROXY"'
  docker compose exec n8n sh -lc 'wget -qO- https://ifconfig.io || curl -s https://ifconfig.io'
  # принудительно через прокси:
  docker compose exec n8n sh -lc 'wget -qO- --proxy=http://xray-client:3128 https://ifconfig.io || curl -x http://xray-client:3128 -s https://ifconfig.io'

Если имя xray-client не резолвится внутри n8n — проверь, что ОБА контейнера в сети 'proxy':
  docker inspect xray-client --format '{{json .NetworkSettings.Networks}}'
  docker inspect <имя-контейнера-n8n> --format '{{json .NetworkSettings.Networks}}'
NEXT
