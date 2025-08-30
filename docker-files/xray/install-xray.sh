#!/usr/bin/env bash
# install-xray.sh
# Автоматически разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray
# и СОЗДАЁТ все файлы:
#   - ./xray/config.json
#   - ./docker-compose.yml
#   - ./env.example
#
# Особенности:
# - HTTP-прокси (3128) и SOCKS5 (1080) доступны ТОЛЬКО внутри внешней docker-сети 'proxy' (ports наружу не открываем).
# - Жёсткая маршрутизация: весь трафик http-in/socks-in → ТОЛЬКО vless-out (без freedom/direct).
# - Поддержаны транспорты: tcp | ws; защиты: tls | reality | none.
# - Все чувствительные параметры спрашиваются ОТДЕЛЬНО (UUID, SNI, Reality publicKey/shortId, fingerprint, flow и т.д.).
# - Идемпотентен: перезапись файлов с бэкапом .bak.<timestamp>, проверки окружения, подробные логи.
#
# Документация:
#   Docker/Compose: https://docs.docker.com/
#   Xray/Reality:  https://xtls.github.io/

set -Eeuo pipefail

########################################
# Значения по умолчанию / можно переопределить флагами или env
########################################
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"          # каталог проекта
EXT_NET="${EXT_NET:-proxy}"                 # внешняя docker-сеть
SERVICE_NAME="${SERVICE_NAME:-xray-client}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:1.8.23}"
HTTP_PORT="${HTTP_PORT:-3128}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

# Параметры соединения (всё спрашиваем отдельно, если не задано):
SERVER_HOST="${SERVER_HOST:-}"              # куда стучимся (домен/IP)
SERVER_PORT="${SERVER_PORT:-443}"
VLESS_UUID="${VLESS_UUID:-}"

TRANSPORT="${TRANSPORT:-tcp}"               # tcp | ws
SECURITY="${SECURITY:-tls}"                 # tls | reality | none

# TLS:
SNI="${SNI:-}"                              # serverName
ALPN="${ALPN:-http/1.1}"                    # http/1.1 | h2
ALLOW_INSECURE="${ALLOW_INSECURE:-false}"   # true|false

# WebSocket:
WS_PATH="${WS_PATH:-/vless}"                # для ws

# Reality:
REALITY_PBK="${REALITY_PBK:-}"              # publicKey (pbk=)
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"    # shortId (sid=)
FINGERPRINT="${FINGERPRINT:-chrome}"        # fp=
SPIDERX="${SPIDERX:-}"                      # spx= (опц.)

# Дополнительно:
FLOW="${FLOW:-}"                             # flow= (опц., напр. xtls-rprx-vision)

########################################
# Вспомогательные
########################################
log()  { echo -e "[\e[34mINFO\e[0m]  $(date +'%F %T')  $*"; }
warn() { echo -e "[\e[33mWARN\e[0m]  $(date +'%F %T')  $*" >&2; }
err()  { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T')  $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Флаги (аналогичны переменным окружения):
  --dir PATH                 Каталог проекта (по умолчанию: ~/xray)
  --net NAME                 Имя внешней docker-сети (по умолчанию: proxy)
  --image NAME:TAG           Образ Xray (по умолчанию: teddysun/xray:1.8.23)
  --http-port N              Внутренний порт HTTP-прокси (по умолчанию: 3128)
  --socks-port N             Внутренний порт SOCKS5 (по умолчанию: 1080)

  --server-host HOST         Домен/IP сервера (куда клиент подключается)
  --server-port N            Порт сервера (по умолчанию: 443)
  --uuid UUID                UUID пользователя VLESS

  --transport tcp|ws         Транспорт (по умолчанию: tcp)
  --security tls|reality|none Защита (по умолчанию: tls)

  # TLS:
  --sni NAME                 SNI/ServerName (по умолчанию = server-host)
  --alpn STR                 ALPN (http/1.1|h2; по умолчанию: http/1.1)
  --allow-insecure true|false allowInsecure в tlsSettings (по умолчанию: false)

  # WebSocket:
  --ws-path PATH             Путь для WebSocket (по умолчанию: /vless)

  # Reality:
  --reality-pbk KEY          Reality publicKey (pbk=)
  --reality-shortid ID       Reality shortId (sid=)
  --fingerprint STR          Fingerprint (по умолчанию: chrome)
  --spiderx PATH             Reality spiderX (опционально)

  # Дополнительно:
  --flow STR                 flow (например xtls-rprx-vision) — опционально
USAGE
}

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    log "Бэкап: $f -> $f.bak.*"
  fi
}

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || err "Не найдена команда '$1'."; }

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

########################################
# Аргументы
########################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir) XRAY_DIR="$2"; shift 2 ;;
    --net) EXT_NET="$2"; shift 2 ;;
    --image) XRAY_IMAGE="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --socks-port) SOCKS_PORT="$2"; shift 2 ;;
    --server-host) SERVER_HOST="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --uuid) VLESS_UUID="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --security) SECURITY="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --alpn) ALPN="$2"; shift 2 ;;
    --allow-insecure) ALLOW_INSECURE="$2"; shift 2 ;;
    --ws-path) WS_PATH="$2"; shift 2 ;;
    --reality-pbk) REALITY_PBK="$2"; shift 2 ;;
    --reality-shortid) REALITY_SHORT_ID="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --spiderx) SPIDERX="$2"; shift 2 ;;
    --flow) FLOW="$2"; shift 2 ;;
    *) err "Неизвестный аргумент: $1 (см. --help)";;
  esac
done

########################################
# Проверки окружения
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. См. установку Compose."
docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте:  docker network create $EXT_NET"

########################################
# Интерактивные вопросы (все параметры — отдельно)
########################################
if [[ -z "$SERVER_HOST" ]]; then
  read -rp "1) SERVER_HOST (домен/IP сервера): " SERVER_HOST
  while [[ -z "$SERVER_HOST" ]]; do read -rp "   Введи SERVER_HOST: " SERVER_HOST; done
fi

if [[ -z "$SERVER_PORT" ]]; then
  read -rp "2) SERVER_PORT [443]: " _sp || true; SERVER_PORT="${_sp:-443}"
fi

if [[ -z "$VLESS_UUID" ]]; then
  read -rp "3) VLESS UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " VLESS_UUID
  until validate_uuid "$VLESS_UUID"; do
    echo "   Неверный формат UUID."
    read -rp "   Повтори UUID: " VLESS_UUID
  done
fi

# transport
if [[ "$TRANSPORT" != "tcp" && "$TRANSPORT" != "ws" ]]; then
  read -rp "4) TRANSPORT (tcp|ws) [tcp]: " _tr || true; TRANSPORT="${_tr:-tcp}"
  while [[ "$TRANSPORT" != "tcp" && "$TRANSPORT" != "ws" ]]; do
    read -rp "   Допустимо 'tcp' или 'ws': " TRANSPORT
  done
fi

# security
if [[ "$SECURITY" != "tls" && "$SECURITY" != "reality" && "$SECURITY" != "none" ]]; then
  read -rp "5) SECURITY (tls|reality|none) [tls]: " _sec || true; SECURITY="${_sec:-tls}"
  while [[ "$SECURITY" != "tls" && "$SECURITY" != "reality" && "$SECURITY" != "none" ]]; do
    read -rp "   Допустимо 'tls'|'reality'|'none': " SECURITY
  done
fi

# ws options
if [[ "$TRANSPORT" == "ws" && -z "$WS_PATH" ]]; then
  read -rp "6) WS_PATH [/vless]: " _w || true; WS_PATH="${_w:-/vless}"
fi

# TLS options
if [[ "$SECURITY" == "tls" ]]; then
  if [[ -z "$SNI" ]]; then
    read -rp "7) SNI/ServerName [${SERVER_HOST}]: " _sni || true; SNI="${_sni:-$SERVER_HOST}"
  fi
  read -rp "8) ALPN [${ALPN}] (например h2|http/1.1): " _alpn || true; ALPN="${_alpn:-$ALPN}"
  read -rp "9) allowInsecure (true|false) [${ALLOW_INSECURE}]: " _ai || true; ALLOW_INSECURE="${_ai:-$ALLOW_INSECURE}"
fi

# Reality options
if [[ "$SECURITY" == "reality" ]]; then
  if [[ -z "$SNI" ]]; then
    read -rp "7) Reality SNI/ServerName (маскировка) [например creativecommons.org]: " SNI
    while [[ -z "$SNI" ]]; do read -rp "   Введи SNI: " SNI; done
  fi
  if [[ -z "$REALITY_PBK" ]]; then
    read -rp "8) Reality publicKey (pbk=): " REALITY_PBK
    while [[ -z "$REALITY_PBK" ]]; do read -rp "   Введи publicKey: " REALITY_PBK; done
  fi
  if [[ -z "$REALITY_SHORT_ID" ]]; then
    read -rp "9) Reality shortId (sid=) [можно пусто]: " REALITY_SHORT_ID || true
  fi
  read -rp "10) Reality fingerprint [${FINGERPRINT}] (chrome|firefox|...): " _fp || true; FINGERPRINT="${_fp:-$FINGERPRINT}"
  read -rp "11) Reality spiderX (spx=) [опц., например /]: " _spx || true; SPIDERX="${_spx:-$SPIDERX}"
  if [[ -z "$FLOW" ]]; then
    read -rp "12) flow (например xtls-rprx-vision) [пусто = не использовать]: " FLOW || true
  fi
fi

# Общее flow (если не задано)
if [[ -z "$FLOW" ]]; then
  read -rp "13) flow (опционально, пусто чтобы пропустить): " FLOW || true
fi

########################################
# Готовим каталоги
########################################
log "Каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

########################################
# env.example для повторного запуска
########################################
backup_if_exists "${XRAY_DIR}/env.example"
cat > "${XRAY_DIR}/env.example" <<ENV
XRAY_DIR=${XRAY_DIR}
EXT_NET=${EXT_NET}
SERVICE_NAME=${SERVICE_NAME}
XRAY_IMAGE=${XRAY_IMAGE}
HTTP_PORT=${HTTP_PORT}
SOCKS_PORT=${SOCKS_PORT}

SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
VLESS_UUID=${VLESS_UUID}

TRANSPORT=${TRANSPORT}
SECURITY=${SECURITY}

SNI=${SNI}
ALPN=${ALPN}
ALLOW_INSECURE=${ALLOW_INSECURE}

WS_PATH=${WS_PATH}

REALITY_PBK=${REALITY_PBK}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
FINGERPRINT=${FINGERPRINT}
SPIDERX=${SPIDERX}

FLOW=${FLOW}
ENV
log "Создан: ${XRAY_DIR}/env.example"

########################################
# streamSettings
########################################
STREAM_SETTINGS=""

if [[ "$SECURITY" == "reality" ]]; then
  # Опциональный фрагмент для spiderX
  SPIDERX_JSON=""
  if [[ -n "$SPIDERX" ]]; then
    SPIDERX_JSON=$',\n  "spiderX": "'"$SPIDERX"'"'
  fi

  # Формируем блок без лишних скобок
  STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "reality",
"realitySettings": {
  "serverName": "$SNI",
  "fingerprint": "$FINGERPRINT",
  "show": false,
  "publicKey": "$REALITY_PBK",
  "shortId": "$REALITY_SHORT_ID"$SPIDERX_JSON
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
  "allowInsecure": ${ALLOW_INSECURE}
},
"wsSettings": { "path": "$WS_PATH" }
JSON
)
  elif [[ "$SECURITY" == "none" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "ws",
"security": "none",
"wsSettings": { "path": "$WS_PATH" }
JSON
)
  else
    err "Комбинация transport=ws и security=$SECURITY не поддержана."
  fi
else
  if [[ "$SECURITY" == "tls" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "tls",
"tlsSettings": {
  "serverName": "$SNI",
  "alpn": ["$ALPN"],
  "allowInsecure": ${ALLOW_INSECURE}
}
JSON
)
  elif [[ "$SECURITY" == "none" ]]; then
    STREAM_SETTINGS=$(cat <<JSON
"network": "tcp",
"security": "none"
JSON
)
  else
    err "Комбинация transport=tcp и security=$SECURITY не поддержана."
  fi
fi

########################################
# Генерация xray/config.json
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
    { "tag": "http-in",  "listen": "0.0.0.0", "port": ${HTTP_PORT},  "protocol": "http" },
    { "tag": "socks-in", "listen": "0.0.0.0", "port": ${SOCKS_PORT}, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_HOST}",
            "port": ${SERVER_PORT},
            "users": [
              { "id": "${VLESS_UUID}", "encryption": "none"${FLOW:+, "flow": "${FLOW}"} }
            ]
          }
        ]
      },
      "streamSettings": { ${STREAM_SETTINGS} }
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
    # Порты наружу НЕ публикуем: доступ к 3128/1080 только из сети '${EXT_NET}'
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
# Запуск и быстрая диагностика
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

Проверка из сети '${EXT_NET}':
  docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \\
    -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org; echo

Логи Xray:
  docker compose -f ${XRAY_DIR}/docker-compose.yml logs --tail=100 ${SERVICE_NAME}
  docker compose -f ${XRAY_DIR}/docker-compose.yml exec ${SERVICE_NAME} sh -lc 'tail -n 50 /var/log/xray/access.log; echo; tail -n 50 /var/log/xray/error.log'

Подсказки:
- Для n8n держите NO_PROXY узким: "localhost,127.0.0.1,::1".
- Прокси в контейнерах: HTTP -> http://${SERVICE_NAME}:3128 , SOCKS5 -> socks5h://${SERVICE_NAME}:1080
- Если HTTPS через прокси висит — проверьте SNI/ALPN/Reality (pbk/shortId/fingerprint/spiderX) и согласованность flow.
EOF
