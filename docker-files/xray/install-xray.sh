#!/usr/bin/env bash
# install-xray.sh
# Автоматически разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray
# и СОЗДАЁТ все нужные файлы:
#   - ./xray/config.json
#   - ./docker-compose.yml
#   - ./env.example
#
# Режимы:
#   - Интерактивный: просто запусти без аргументов — скрипт задаст вопросы.
#   - Неинтерактивный: передай флаги (--server-host, --uuid, и т.д.) или экспортируй переменные.
#
# Особенности:
#   - HTTP-прокси (3128) и SOCKS5 (1080) доступны ТОЛЬКО внутри внешней docker-сети 'proxy' (ports: не публикуем).
#   - Жёсткая маршрутизация: любой трафик с http-in/socks-in → только vless-out (без freedom/direct).
#   - Поддержка транспортов tcp|ws и защит tls|reality|none.
#   - Подробные логи, валидация, бэкапы при перезаписи.
#
# Документация:
#   Docker:   https://docs.docker.com/
#   Compose:  https://docs.docker.com/compose/
#   Xray:     https://xtls.github.io/

set -Eeuo pipefail

########################################
# Значения по умолчанию
########################################
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"    # каталог проекта
EXT_NET="${EXT_NET:-proxy}"           # внешняя сеть Docker
SERVICE_NAME="${SERVICE_NAME:-xray-client}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:1.8.23}"
HTTP_PORT="${HTTP_PORT:-3128}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

# Параметры (могут прийти аргументами/переменными; если пусто — спросим интерактивно)
SERVER_HOST="${SERVER_HOST:-}"
SERVER_PORT="${SERVER_PORT:-443}"
VLESS_UUID="${VLESS_UUID:-}"
TRANSPORT="${TRANSPORT:-tcp}"         # tcp|ws
SECURITY="${SECURITY:-tls}"           # tls|reality|none
WS_PATH="${WS_PATH:-/vless}"          # если transport=ws
SNI="${SNI:-}"                        # SNI/ServerName для tls|reality (по умолчанию = SERVER_HOST)
ALPN="${ALPN:-http/1.1}"              # http/1.1|h2
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"

########################################
# Утилиты логирования
########################################
log()  { echo -e "[\e[34mINFO\e[0m]  $(date +'%F %T')  $*"; }
warn() { echo -e "[\e[33mWARN\e[0m]  $(date +'%F %T')  $*" >&2; }
err()  { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T')  $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Использование:
  Интерактивно (рекомендуется):
    ./install-xray.sh

  Неинтерактивно (все параметры флагами):
    ./install-xray.sh --server-host my.server.com --server-port 443 \
      --uuid 123e4567-e89b-12d3-a456-426614174000 \
      --transport ws --security tls --ws-path /ws --sni my.server.com --alpn http/1.1

Поддерживаемые флаги (можно также задать одноимёнными переменными окружения):
  --dir PATH              Каталог проекта (по умолчанию: ~/xray)
  --net NAME              Имя внешней docker-сети (по умолчанию: proxy)
  --image NAME:TAG        Образ Xray (по умолчанию: teddysun/xray:1.8.23)

  --server-host HOST      Домен/IP VLESS-сервера
  --server-port N         Порт сервера (по умолчанию: 443)
  --uuid UUID             UUID пользователя VLESS
  --transport tcp|ws      Транспорт (по умолчанию: tcp)
  --security tls|reality|none  Защита (по умолчанию: tls)
  --ws-path PATH          Путь для WebSocket (по умолчанию: /vless)
  --sni NAME              SNI/ServerName (по умолчанию = server-host)
  --alpn STR              ALPN (по умолчанию: http/1.1; например h2)
  --reality-pubkey KEY    Reality public key (обязательно при security=reality)
  --reality-shortid ID    Reality shortId (желательно при security=reality)
USAGE
}

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    log "Бэкап: $f -> $f.bak.*"
  fi
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Команда '$1' не найдена. Установка: см. официальную документацию."
}

validate_uuid() {
  local u="$1"
  [[ "$u" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

########################################
# Парсинг аргументов
########################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir) XRAY_DIR="$2"; shift 2 ;;
    --net) EXT_NET="$2"; shift 2 ;;
    --image) XRAY_IMAGE="$2"; shift 2 ;;
    --server-host) SERVER_HOST="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --uuid) VLESS_UUID="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --security) SECURITY="$2"; shift 2 ;;
    --ws-path) WS_PATH="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --alpn) ALPN="$2"; shift 2 ;;
    --reality-pubkey) REALITY_PUBLIC_KEY="$2"; shift 2 ;;
    --reality-shortid) REALITY_SHORT_ID="$2"; shift 2 ;;
    *) err "Неизвестный аргумент: $1 (см. --help)";;
  esac
done

########################################
# Проверки окружения
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. См.: https://docs.docker.com/compose/install/"
docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте:  docker network create $EXT_NET"

########################################
# Интерактивные запросы, если что-то не задано
########################################
if [[ -z "${SERVER_HOST}" ]]; then
  read -rp "Домен/IP VLESS-сервера: " SERVER_HOST
  while [[ -z "$SERVER_HOST" ]]; do read -rp "Пусто. Введи домен/IP: " SERVER_HOST; done
fi

if [[ -z "${SERVER_PORT}" ]]; then
  read -rp "Порт VLESS [443]: " _p || true; SERVER_PORT="${_p:-443}"
fi

if [[ -z "${VLESS_UUID}" ]]; then
  read -rp "UUID пользователя VLESS (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " VLESS_UUID
  until validate_uuid "$VLESS_UUID"; do
    echo "Неверный формат UUID. Пример: 123e4567-e89b-12d3-a456-426614174000"
    read -rp "UUID: " VLESS_UUID
  done
else
  validate_uuid "$VLESS_UUID" || err "Неверный формат UUID: $VLESS_UUID"
fi

case "${TRANSPORT}" in
  tcp|ws) ;; *)
    read -rp "Транспорт (tcp|ws) [tcp]: " _t || true; TRANSPORT="${_t:-tcp}"
    while [[ "$TRANSPORT" != "tcp" && "$TRANSPORT" != "ws" ]]; do
      read -rp "Допустимо 'tcp' или 'ws': " TRANSPORT
    done
  ;;
esac

case "${SECURITY}" in
  tls|reality|none) ;; *)
    read -rp "Защита (tls|reality|none) [tls]: " _s || true; SECURITY="${_s:-tls}"
    while [[ "$SECURITY" != "tls" && "$SECURITY" != "reality" && "$SECURITY" != "none" ]]; do
      read -rp "Допустимо 'tls'|'reality'|'none': " SECURITY
    done
  ;;
esac

if [[ "$TRANSPORT" == "ws" ]]; then
  if [[ -z "$WS_PATH" ]]; then
    read -rp "WS path [/vless]: " _w || true; WS_PATH="${_w:-/vless}"
  fi
fi

if [[ -z "$SNI" ]]; then
  read -rp "SNI/ServerName [${SERVER_HOST}]: " _sni || true; SNI="${_sni:-$SERVER_HOST}"
fi

if [[ -z "$ALPN" ]]; then
  read -rp "ALPN [http/1.1]: " _alpn || true; ALPN="${_alpn:-http/1.1}"
fi

if [[ "$SECURITY" == "reality" ]]; then
  if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
    read -rp "Reality publicKey: " REALITY_PUBLIC_KEY
    [[ -n "$REALITY_PUBLIC_KEY" ]] || err "publicKey обязателен для reality"
  fi
  if [[ -z "$REALITY_SHORT_ID" ]]; then
    read -rp "Reality shortId (можно пусто): " REALITY_SHORT_ID || true
  fi
fi

########################################
# Подготовка каталогов
########################################
log "Готовлю каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

########################################
# Генерация env.example
########################################
backup_if_exists "${XRAY_DIR}/env.example"
cat > "${XRAY_DIR}/env.example" <<ENV
# Пример переменных для Xray-клиента
SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
VLESS_UUID=${VLESS_UUID}
TRANSPORT=${TRANSPORT}
SECURITY=${SECURITY}
WS_PATH=${WS_PATH}
SNI=${SNI}
ALPN=${ALPN}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
ENV
log "Создан: ${XRAY_DIR}/env.example"

########################################
# Формируем streamSettings
########################################
STREAM_SETTINGS=""
if [[ "$SECURITY" == "reality" ]]; then
  STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "reality",
"realitySettings": {
  "serverName": "$SNI",
  "fingerprint": "chrome",
  "show": false,
  "publicKey": "$REALITY_PUBLIC_KEY",
  "shortId": "$REALITY_SHORT_ID"
}
JSON
)
elif [[ "$TRANSPORT" == "ws" ]]; then
  if [[ "$SECURITY" == "tls" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "ws",
"security": "tls",
"tlsSettings": {
  "serverName": "$SNI",
  "alpn": ["$ALPN"],
  "allowInsecure": false
},
"wsSettings": { "path": "$WS_PATH" }
JSON
)
  else
    STREAM_SETTINGS=$(cat <<JSON
"network": "ws",
"security": "none",
"wsSettings": { "path": "$WS_PATH" }
JSON
)
  fi
else
  if [[ "$SECURITY" == "tls" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "tls",
"tlsSettings": {
  "serverName": "$SNI",
  "alpn": ["$ALPN"],
  "allowInsecure": false
}
JSON
)
  else
    STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "none"
JSON
)
  fi
fi

########################################
# Генерация xray/config.json (жёстко: без direct/freedom)
########################################
backup_if_exists "${XRAY_DIR}/xray/config.json"
cat > "${XRAY_DIR}/xray/config.json" <<JSON
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
    { "tag": "http-in",  "listen": "0.0.0.0", "port": $HTTP_PORT,  "protocol": "http" },
    { "tag": "socks-in", "listen": "0.0.0.0", "port": $SOCKS_PORT, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_HOST",
            "port": $SERVER_PORT,
            "users": [
              { "id": "$VLESS_UUID", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": { $STREAM_SETTINGS }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["http-in","socks-in"], "outboundTag": "vless-out" }
    ]
  }
}
JSON
log "Создан: ${XRAY_DIR}/xray/config.json"

########################################
# Генерация docker-compose.yml
########################################
backup_if_exists "${XRAY_DIR}/docker-compose.yml"
cat > "${XRAY_DIR}/docker-compose.yml" <<YAML
version: "3.9"
services:
  ${SERVICE_NAME}:
    image: ${XRAY_IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
      - ./logs:/var/log/xray
    networks:
      - ${EXT_NET}
    # Порты наружу НЕ публикуются — доступ только из сети '${EXT_NET}'
    healthcheck:
      test: ["CMD", "/usr/bin/xray", "-version"]
      interval: 30s
      timeout: 5s
      retries: 5

networks:
  ${EXT_NET}:
    external: true
YAML
log "Создан: ${XRAY_DIR}/docker-compose.yml"

########################################
# Запуск и мини-диагностика
########################################
log "Запуск docker compose в: ${XRAY_DIR}"
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
popd >/dev/null

log "Проверка, что контейнер в сети '${EXT_NET}':"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

cat <<EOF

Готово ✅

Проверь работу прокси из этой же сети:
  docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \\
    -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org; echo

Логи Xray:
  docker compose -f ${XRAY_DIR}/docker-compose.yml logs --tail=100 ${SERVICE_NAME}
  docker compose -f ${XRAY_DIR}/docker-compose.yml exec ${SERVICE_NAME} sh -lc 'tail -n 50 /var/log/xray/access.log; echo; tail -n 50 /var/log/xray/error.log'

Подсказки:
- В контейнерах-клиентах (например, n8n) держите NO_PROXY узким: "localhost,127.0.0.1,::1".
- Прокси-адрес для HTTP(S):  http://${SERVICE_NAME}:3128    (в сети ${EXT_NET})
- SOCKS5 при необходимости:  socks5h://${SERVICE_NAME}:1080
EOF
