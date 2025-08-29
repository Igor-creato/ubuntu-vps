cat > ~/bootstrap-xray.sh <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail

# --- Настройки по умолчанию (можно оставить пустыми — спросим интерактивно) ---
XRAY_DIR="${HOME}/xray"
EXT_NET="proxy"                 # внешняя сеть docker (у тебя уже есть)
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:latest"
HTTP_PORT=3128                  # слушаются ВНУТРИ docker-сети
SOCKS_PORT=1080

SERVER_ADDR=""                  # домен/IP VLESS-сервера (Нидерланды)
SERVER_PORT="443"
VLESS_UUID=""                   # UUID пользователя
TRANSPORT="ws"                  # ws|tcp
TLS_ENABLE="true"               # true|false
WS_PATH="/vless"                # путь для ws

log(){ echo -e "[INFO] $*"; }
err(){ echo -e "[ERROR] $*" >&2; }

# --- Проверки зависимостей ---
command -v docker >/dev/null || { err "docker не установлен"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' недоступен"; exit 1; }
docker network inspect "$EXT_NET" >/dev/null 2>&1 || { err "сеть '$EXT_NET' не найдена"; exit 1; }

# --- Интерактив ---
[[ -n "$SERVER_ADDR" ]] || read -rp "Домен/IP VLESS-сервера (NL): " SERVER_ADDR
read -rp "Порт VLESS [${SERVER_PORT}]: " _p || true; SERVER_PORT="${_p:-$SERVER_PORT}"

if command -v uuidgen >/dev/null 2>&1; then
  [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(uuidgen)"
  log "UUID: $VLESS_UUID"
else
  [[ -n "$VLESS_UUID" ]] || read -rp "UUID пользователя VLESS: " VLESS_UUID
fi

read -rp "Транспорт (ws|tcp) [${TRANSPORT}]: " _t || true; TRANSPORT="${_t:-$TRANSPORT}"
read -rp "TLS (true|false) [${TLS_ENABLE}]: " _tls || true; TLS_ENABLE="${_tls:-$TLS_ENABLE}"
if [[ "${TRANSPORT,,}" == "ws" ]]; then
  read -rp "WS path [${WS_PATH}]: " _w || true; WS_PATH="${_w:-$WS_PATH}"
fi

# --- Каталоги ---
mkdir -p "${XRAY_DIR}/xray"

# --- streamSettings ---
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
else
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

# --- config.json ---
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
          { "address": "${SERVER_ADDR}", "port": ${SERVER_PORT},
            "users": [ { "id": "${VLESS_UUID}", "encryption": "none", "flow": "" } ] }
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

# --- docker-compose.yml ---
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
    # ВАЖНО: порты не публикуем. Прокси доступны ТОЛЬКО контейнерам в сети '${EXT_NET}' по имени '${SERVICE_NAME}'.
    # ports:
    #   - "${HTTP_PORT}:${HTTP_PORT}"
    #   - "${SOCKS_PORT}:${SOCKS_PORT}"

networks:
  default:
    name: ${EXT_NET}
    external: true
YAML

# --- Запуск ---
cd "${XRAY_DIR}"
log "Запускаю стек xray..."
docker compose pull
docker compose up -d
docker compose ps

log "Проверка: контейнер должен быть в сети '${EXT_NET}'"
docker inspect ${SERVICE_NAME} --format '{{json .NetworkSettings.Networks}}' || true

log "ГОТОВО.
Используй в стеке n8n:
  HTTP_PROXY=http://${SERVICE_NAME}:${HTTP_PORT}
  HTTPS_PROXY=http://${SERVICE_NAME}:${HTTP_PORT}
  NO_PROXY=localhost,127.0.0.1,::1,n8n,postgres,traefik,wp-app,wp-db,wp-pma,supabase-db,supabase-pooler,supabase-auth,supabase-rest,supabase-realtime,supabase-storage,supabase-studio,supabase-meta,supabase-edge-functions,supabase-analytics,supabase-imgproxy,supabase-vector,supabase-kong,realtime-dev.supabase-realtime"
BASH

chmod +x ~/bootstrap-xray.sh
