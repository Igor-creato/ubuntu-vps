#!/usr/bin/env bash
# install-xray-docker.sh
# Установка Xray (VLESS-клиент) в Docker Compose для исходящего прокси (HTTP/HTTPS/SOCKS) ТОЛЬКО для контейнеров в сети 'proxy'.
# НИЧЕГО не публикует наружу на хост (без ports:), доступ к прокси из других контейнеров по имени сервиса 'xray-client' в сети 'proxy'.
#
# Док-ция:
# - Docker Engine/Compose: https://docs.docker.com/
# - Xray (VLESS): https://xtls.github.io/
#
# Использование (интерактивно):  bash install-xray-docker.sh
# Использование (флаги):
#   --server nl.example.com       # домен/IP VLESS-сервера (Нидерланды)
#   --port 443                    # порт VLESS
#   --uuid <UUID>                 # UUID пользователя VLESS
#   --transport ws|tcp            # транспорт (по умолчанию ws)
#   --tls true|false              # TLS (по умолчанию true)
#   --ws-path /vless              # путь для ws (по умолчанию /vless)
#   --dir  ~/xray                 # каталог установки (по умолчанию ~/xray)
#   --ext-net proxy               # внешняя сеть docker (по умолчанию proxy)
#
# Пример:
#   bash install-xray-docker.sh \
#     --server nl.example.com --port 443 --uuid "$(uuidgen)" \
#     --transport ws --tls true --ws-path /vless \
#     --dir ~/xray --ext-net proxy

set -Eeuo pipefail

# ---------- Конфиг по умолчанию ----------
XRAY_DIR="${HOME}/xray"
EXT_NET="proxy"          # внешняя сеть, куда подключены Traefik и n8n
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:latest"
HTTP_PORT=3128           # будут слушаться ВНУТРИ docker-сети (не публикуются наружу)
SOCKS_PORT=1080

SERVER_ADDR=""
SERVER_PORT="443"
VLESS_UUID=""
TRANSPORT="ws"           # ws | tcp
TLS_ENABLE="true"        # true | false
WS_PATH="/vless"

LOG_FILE="/tmp/install-xray-$(date +%Y%m%d-%H%M%S).log"

# ---------- Утилиты ----------
log()  { echo -e "[\e[34mINFO\e[0m] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "[\e[31mERROR\e[0m] $*" | tee -a "$LOG_FILE" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Не найдена команда: $1"; return 1; }; }

# ---------- Парсер флагов ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)   SERVER_ADDR="${2:-}"; shift 2;;
    --port)     SERVER_PORT="${2:-}"; shift 2;;
    --uuid)     VLESS_UUID="${2:-}"; shift 2;;
    --transport) TRANSPORT="${2:-}"; shift 2;;
    --tls)      TLS_ENABLE="${2:-}"; shift 2;;
    --ws-path)  WS_PATH="${2:-}"; shift 2;;
    --dir)      XRAY_DIR="${2:-}"; shift 2;;
    --ext-net)  EXT_NET="${2:-}"; shift 2;;
    *) err "Неизвестный аргумент: $1"; exit 2;;
  esac
done

# ---------- Проверки окружения ----------
log "Логи: $LOG_FILE"
need_cmd docker
# Проверяем docker compose (plugin)
if ! docker compose version >/dev/null 2>&1; then
  err "'docker compose' недоступен. Установи плагин: https://docs.docker.com/compose/install/linux/"
  exit 1
fi

# Проверим, что сеть EXT_NET существует
if ! docker network inspect "$EXT_NET" >/dev/null 2>&1; then
  err "Не найдена внешняя сеть Docker '${EXT_NET}'. Твои сети: $(docker network ls --format '{{.Name}}' | tr '\n' ' ')"
  exit 1
fi

# ---------- Интерактивный ввод (если не передали флагами) ----------
if [[ -z "$SERVER_ADDR" ]]; then
  read -r -p "Домен/IP VLESS-сервера (Нидерланды): " SERVER_ADDR
fi
if [[ -z "$SERVER_PORT" ]]; then
  read -r -p "Порт VLESS [443]: " SERVER_PORT
  SERVER_PORT="${SERVER_PORT:-443}"
fi
if [[ -z "$VLESS_UUID" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    VLESS_UUID="$(uuidgen)"
    log "Сгенерирован UUID: $VLESS_UUID"
  else
    read -r -p "UUID пользователя VLESS: " VLESS_UUID
  fi
fi
if [[ -z "$TRANSPORT" ]]; then
  read -r -p "Транспорт (ws|tcp) [ws]: " TRANSPORT
  TRANSPORT="${TRANSPORT:-ws}"
fi
if [[ -z "$TLS_ENABLE" ]]; then
  read -r -p "TLS (true|false) [true]: " TLS_ENABLE
  TLS_ENABLE="${TLS_ENABLE:-true}"
fi
if [[ "${TRANSPORT,,}" == "ws" && -z "$WS_PATH" ]]; then
  read -r -p "WS path [/vless]: " WS_PATH
  WS_PATH="${WS_PATH:-/vless}"
fi

# ---------- Подготовка каталогов ----------
log "Создаю каталог ${XRAY_DIR}/xray"
mkdir -p "${XRAY_DIR}/xray"
cd "$XRAY_DIR"

# ---------- Генерация config.json ----------
log "Генерирую ${XRAY_DIR}/xray/config.json"

if [[ "${TRANSPORT,,}" == "ws" ]]; then
  if [[ "${TLS_ENABLE,,}" == "true" ]]; then
    read -r -d '' STREAM_SETTINGS <<EOF
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
  else
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "ws",
"security": "none",
"wsSettings": {
  "path": "${WS_PATH}"
}
EOF
  fi
else # tcp
  if [[ "${TLS_ENABLE,,}" == "true" ]]; then
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "tcp",
"security": "tls",
"tlsSettings": {
  "serverName": "${SERVER_ADDR}",
  "allowInsecure": false
}
EOF
  else
    read -r -d '' STREAM_SETTINGS <<EOF
"network": "tcp",
"security": "none"
EOF
  fi
fi

cat > "${XRAY_DIR}/xray/config.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "http-in",  "port": ${HTTP_PORT}, "listen": "0.0.0.0", "protocol": "http" },
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
            "users": [ { "id": "${VLESS_UUID}", "encryption": "none", "flow": "" } ]
          }
        ]
      },
      "streamSettings": { ${STREAM_SETTINGS} }
    },
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["http-in","socks-in"], "outboundTag": "vless-out" }
    ]
  }
}
JSON

# ---------- Генерация docker-compose.yml ----------
log "Генерирую ${XRAY_DIR}/docker-compose.yml"

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
    # Порты не публикуем! Прокси доступны только из сети '${EXT_NET}' по имени сервиса '${SERVICE_NAME}'
    # ports:
    #   - "${HTTP_PORT}:${HTTP_PORT}"
    #   - "${SOCKS_PORT}:${SOCKS_PORT}"

networks:
  default:
    name: ${EXT_NET}
    external: true
YAML

# ---------- Запуск ----------
log "Подтягиваю образ и запускаю контейнер..."
docker compose pull | tee -a "$LOG_FILE"
docker compose up -d | tee -a "$LOG_FILE"

log "Статус контейнера:"
docker compose ps

log "Готово. Прокси доступны контейнерам в сети '${EXT_NET}':"
echo "  HTTP  → http://${SERVICE_NAME}:${HTTP_PORT}"
echo "  SOCKS5→ socks5://${SERVICE_NAME}:${SOCKS_PORT}"

cat <<'NOTE'

Дальше: подключи только n8n к этому прокси через переменные окружения:

  HTTP_PROXY=http://xray-client:3128
  HTTPS_PROXY=http://xray-client:3128
  NO_PROXY=localhost,127.0.0.1,::1,n8n,n8n-n8n-1,traefik,traefik-traefik-1,postgres,n8n-postgres-1,wp-app,wp-db,wp-pma,\
supabase-db,supabase-pooler,supabase-auth,supabase-rest,supabase-realtime,supabase-storage,supabase-studio,supabase-meta,\
supabase-edge-functions,supabase-analytics,supabase-imgproxy,supabase-vector,supabase-kong,realtime-dev.supabase-realtime

(Список NO_PROXY можно укоротить/уточнить под твои реальные имена сервисов.)
NOTE
