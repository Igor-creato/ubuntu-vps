#!/usr/bin/env bash
# install-xray.sh
# Автоматически разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray и СОЗДАЁТ все нужные файлы:
#   - ./xray/config.json         (конфиг Xray)
#   - ./docker-compose.yml       (стек Docker)
#   - ./env.example              (шаблон переменных)
#
# Особенности:
# - Поднимает HTTP-прокси (3128) и SOCKS5 (1080), доступные ТОЛЬКО внутри внешней docker-сети 'proxy' (ports: не публикуются).
# - Жёсткая маршрутизация: весь трафик с http-in/socks-in идёт в vless-out. НЕТ fallback на direct/freedom → исключён обход VPN.
# - Поддерживает транспорты tcp|ws и защиты tls|reality|none.
# - Идемпотентен: перезапись файлов с бэкапом, подробные логи, проверки окружения.
#
# Документация:
#   Docker:   https://docs.docker.com/
#   Compose:  https://docs.docker.com/compose/
#   Xray:     https://xtls.github.io/
#
# Требования: docker, "docker compose" (plugin), существующая внешняя сеть Docker 'proxy'
# Рекомендация: запускать от пользователя с правами docker.

set -Eeuo pipefail

########################################
# Глобальные настройки по умолчанию
########################################
XRAY_DIR="${HOME}/xray"           # каталог проекта
EXT_NET="proxy"                   # внешняя сеть Docker
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:1.8.23" # фиксируем версию для воспроизводимости
HTTP_PORT=3128
SOCKS_PORT=1080

# Параметры подключения к серверу (можно указать флагами или через переменные окружения)
SERVER_HOST="${SERVER_HOST:-}"
SERVER_PORT="${SERVER_PORT:-443}"
VLESS_UUID="${VLESS_UUID:-}"
TRANSPORT="${TRANSPORT:-tcp}"     # tcp|ws
SECURITY="${SECURITY:-tls}"       # tls|reality|none
WS_PATH="${WS_PATH:-/vless}"      # для ws
SNI="${SNI:-}"                    # serverName для tls/reality; по умолчанию = SERVER_HOST
ALPN="${ALPN:-http/1.1}"          # http/1.1|h2 — под сервер
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}" # для reality
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"     # для reality

########################################
# Вспомогательные функции
########################################

# log: печатает информационное сообщение с меткой времени.
log() { echo -e "[\e[34mINFO\e[0m] $(date +'%F %T')  $*"; }

# warn: печатает предупреждение.
warn() { echo -e "[\e[33mWARN\e[0m] $(date +'%F %T')  $*" >&2; }

# err: печатает ошибку и выходит.
err() { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T') $*" >&2; exit 1; }

# usage: показывает справку по скрипту.
usage() {
  cat <<'USAGE'
Установка Xray-клиента в Docker Compose и автогенерация файлов.

Флаги (можно также задать одноимёнными переменными окружения):
  --dir PATH              Каталог проекта (по умолчанию: ~/xray)
  --net NAME              Имя внешней docker-сети (по умолчанию: proxy)
  --image NAME:TAG        Образ Xray (по умолчанию: teddysun/xray:1.8.23)

  --server-host HOST      Домен/IP VLESS-сервера (обязательно)
  --server-port N         Порт сервера (по умолчанию: 443)
  --uuid UUID             UUID пользователя VLESS (обязательно, формат xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
  --transport tcp|ws      Транспорт (по умолчанию: tcp)
  --security tls|reality|none  Защита (по умолчанию: tls)
  --ws-path PATH          Путь для WebSocket (по умолчанию: /vless, при transport=ws)
  --sni NAME              SNI/ServerName для tls/reality (по умолчанию = server-host)
  --alpn STR              ALPN (по умолчанию: http/1.1; например h2)
  --reality-pubkey KEY    Reality public key (обязательно при --security reality)
  --reality-shortid ID    Reality shortId (желательно при --security reality)

Примеры:
  ./install-xray.sh --server-host my.server.com --uuid 123e4567-e89b-12d3-a456-426614174000
  ./install-xray.sh --server-host my.server.com --uuid <UUID> --transport ws --security tls --ws-path /ws
  ./install-xray.sh --server-host my.server.com --uuid <UUID> --security reality --reality-pubkey XYZ --reality-shortid abc123
USAGE
}

# backup_if_exists: делает .bak, если файл существует и отличается.
backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    log "Бэкап: $f -> $f.bak.*"
  fi
}

# ensure_cmd: проверка наличия команды.
ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Не найдена команда '$1'. Установка: см. официальную документацию."
}

# validate_uuid: проверяет формат UUID.
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
# Проверки окружения и входных параметров
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. См.: https://docs.docker.com/compose/install/"

docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте её:  docker network create $EXT_NET"

[[ -n "$SERVER_HOST" ]] || err "Не указан --server-host"
[[ -n "$VLESS_UUID" ]] || err "Не указан --uuid"
validate_uuid "$VLESS_UUID" || err "Неверный формат UUID: $VLESS_UUID"

[[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "ws" ]] || err "--transport должен быть tcp|ws"
[[ "$SECURITY" == "tls" || "$SECURITY" == "reality" || "$SECURITY" == "none" ]] || err "--security должен быть tls|reality|none"

if [[ "$SECURITY" == "reality" ]]; then
  [[ -n "$REALITY_PUBLIC_KEY" ]] || err "--reality-pubkey обязателен при --security reality"
  [[ -n "$REALITY_SHORT_ID" ]] || warn "Reality shortId не задан (--reality-shortid). Это не всегда критично, но рекомендуется."
fi

[[ -n "$SNI" ]] || SNI="$SERVER_HOST"

########################################
# Подготовка каталогов и файлов
########################################
log "Подготовка каталогов в: $XRAY_DIR"
mkdir -p "$XRAY_DIR/xray" "$XRAY_DIR/logs"

# env.example: создаём для наглядности и повторного использования
backup_if_exists "$XRAY_DIR/env.example"
cat > "$XRAY_DIR/env.example" <<ENV
# Пример переменных для Xray-клиента
SERVER_HOST=$SERVER_HOST
SERVER_PORT=$SERVER_PORT
VLESS_UUID=$VLESS_UUID
TRANSPORT=$TRANSPORT
SECURITY=$SECURITY
WS_PATH=$WS_PATH
SNI=$SNI
ALPN=$ALPN
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
ENV

log "Создан файл: $XRAY_DIR/env.example"

########################################
# Формирование streamSettings
########################################
STREAM_SETTINGS=""
if [[ "$SECURITY" == "reality" ]]; then
  # Reality поверх TCP
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
  # WebSocket + (tls|none)
  if [[ "$SECURITY" == "tls" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "ws",
"security": "tls",
"tlsSettings": {
  "serverName": "$SNI",
  "alpn": ["$ALPN"],
  "allowInsecure": false
},
"wsSettings": {
  "path": "$WS_PATH"
}
JSON
)
  else
    STREAM_SETTINGS=$(cat <<JSON
"network": "ws",
"security": "none",
"wsSettings": {
  "path": "$WS_PATH"
}
JSON
)
  fi
else
  # TCP + (tls|none)
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
# Генерация xray/config.json
########################################
backup_if_exists "$XRAY_DIR/xray/config.json"
cat > "$XRAY_DIR/xray/config.json" <<JSON
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
      { "type": "field", "inboundTag": ["http-in", "socks-in"], "outboundTag": "vless-out" }
    ]
  }
}
JSON

log "Создан файл: $XRAY_DIR/xray/config.json"

########################################
# Генерация docker-compose.yml
########################################
backup_if_exists "$XRAY_DIR/docker-compose.yml"
cat > "$XRAY_DIR/docker-compose.yml" <<YAML
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
    # Ничего не публикуем наружу: доступ к 3128/1080 только из сети '${EXT_NET}'
    # ports: []
    healthcheck:
      test: ["CMD", "/usr/bin/xray", "-version"]
      interval: 30s
      timeout: 5s
      retries: 5

networks:
  ${EXT_NET}:
    external: true
YAML

log "Создан файл: $XRAY_DIR/docker-compose.yml"

########################################
# Запуск стека
########################################
log "Запуск docker compose в: $XRAY_DIR"
pushd "$XRAY_DIR" >/dev/null
docker compose pull
docker compose up -d
popd >/dev/null

########################################
# Быстрая диагностика
########################################
log "Проверка, что контейнер в сети '${EXT_NET}':"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

cat <<EOF

Готово ✅

Что дальше:

1) Прокси-доступ из контейнеров в сети '${EXT_NET}':
   - HTTP-прокси:  http://${SERVICE_NAME}:3128
   - SOCKS5:       socks5h://${SERVICE_NAME}:1080

2) Быстрая проверка из той же сети:
   docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \\
     -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org; echo

3) Логи Xray:
   docker compose -f ${XRAY_DIR}/docker-compose.yml logs --tail=100 ${SERVICE_NAME}
   docker compose -f ${XRAY_DIR}/docker-compose.yml exec ${SERVICE_NAME} sh -lc 'tail -n 50 /var/log/xray/access.log; echo; tail -n 50 /var/log/xray/error.log'

Подсказки:
- Если используете n8n: в его контейнере держите NO_PROXY максимально узким (только localhost/127.0.0.1/::1),
  чтобы избежать «петли» обращения к прокси через прокси.
- Если HTTPS-запросы через прокси висят, проверьте SNI/ALPN/параметры Reality на соответствие серверу.

EOF
