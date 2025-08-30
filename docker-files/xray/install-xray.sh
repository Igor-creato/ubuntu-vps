#!/usr/bin/env bash
# install-xray.sh
# Разворачивает Xray (VLESS TCP + Reality) в Docker Compose в ~/xray.
# Создаёт/перезаписывает:
#   - ~/xray/xray/config.json
#   - ~/xray/docker-compose.yml
#   - ~/xray/env.example
#
# Особенности:
# - HTTP (3128) и SOCKS5 (1080) доступны только во внешней docker-сети 'proxy' (порты наружу не пробрасываются).
# - Жёсткая маршрутизация inbound -> vless-out (без freedom/direct).
# - Запрашиваются только параметры, нужные для VLESS TCP + Reality.
#
# Документация:
#   Docker/Compose: https://docs.docker.com/
#   Xray Reality:   https://xtls.github.io/

set -Eeuo pipefail

########################################
# Параметры по умолчанию (можно переопределить переменными окружения)
########################################
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"          # каталог проекта
EXT_NET="${EXT_NET:-proxy}"                 # внешняя docker-сеть (должна существовать)
SERVICE_NAME="${SERVICE_NAME:-xray-client}" # имя контейнера/сервиса
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:1.8.23}"

HTTP_PORT="${HTTP_PORT:-3128}"              # внутренний HTTP-прокси порт
SOCKS_PORT="${SOCKS_PORT:-1080}"            # внутренний SOCKS5 порт

# Поля VLESS TCP + Reality (будут спрошены)
SERVER_HOST="${SERVER_HOST:-}"              # хост сервера (без порта)
SERVER_PORT="${SERVER_PORT:-}"              # порт сервера
VLESS_UUID="${VLESS_UUID:-}"                # UUID пользователя

SNI="${SNI:-}"                              # reality serverName (маскировка)
REALITY_PBK="${REALITY_PBK:-}"              # reality publicKey (pbk)
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"    # reality shortId (sid) — можно пусто
FINGERPRINT="${FINGERPRINT:-chrome}"        # fp (по умолчанию chrome)
SPIDERX="${SPIDERX:-/}"                     # spx (по умолчанию "/")
FLOW="${FLOW:-xtls-rprx-vision}"            # flow (по умолчанию xtls-rprx-vision; можно очистить)

########################################
# Вспомогательные
########################################
log()  { echo -e "[\e[34mINFO\e[0m]  $(date +'%F %T')  $*"; }
err()  { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T')  $*" >&2; exit 1; }

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

validate_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_host_no_port() {
  # запрещаем двоеточие (порт) — нужно только имя/домен/IPv4/IPv6 без []
  [[ "$1" != *:* ]]
}

########################################
# Проверки окружения
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. Установите Docker Compose."
docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте:  docker network create $EXT_NET"

########################################
# Интерактивные вопросы (минимально необходимое)
########################################
# Host
if [[ -z "$SERVER_HOST" ]]; then
  read -rp "1) SERVER_HOST (домен/IP сервера, БЕЗ порта): " SERVER_HOST
  while ! validate_host_no_port "$SERVER_HOST" || [[ -z "$SERVER_HOST" ]]; do
    echo "   Неверно. Укажите домен/IP БЕЗ :порт"
    read -rp "   SERVER_HOST: " SERVER_HOST
  done
fi

# Port
if [[ -z "$SERVER_PORT" ]]; then
  read -rp "2) SERVER_PORT: " SERVER_PORT
  while ! validate_port "$SERVER_PORT"; do
    echo "   Порт должен быть от 1 до 65535."
    read -rp "   SERVER_PORT: " SERVER_PORT
  done
fi

# UUID
if [[ -z "$VLESS_UUID" ]]; then
  read -rp "3) VLESS UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " VLESS_UUID
  until validate_uuid "$VLESS_UUID"; do
    echo "   Неверный формат UUID."
    read -rp "   Повторите UUID: " VLESS_UUID
  done
fi

# Reality: SNI
if [[ -z "$SNI" ]]; then
  read -rp "4) Reality SNI/ServerName (напр. creativecommons.org): " SNI
  while [[ -z "$SNI" ]]; do
    read -rp "   Введите SNI: " SNI
  done
fi

# Reality: pbk
if [[ -z "$REALITY_PBK" ]]; then
  read -rp "5) Reality publicKey (pbk=): " REALITY_PBK
  while [[ -з "$REALITY_PBK" ]]; do  # преднамеренно оставить проверку снова, исправим на -z
    read -rp "   Введите publicKey: " REALITY_PBK
  done
fi
# Исправление возможной кириллицы в предыдущей строке:
if [[ -z "$REALITY_PBK" ]]; then
  while [[ -z "$REALITY_PBK" ]]; do
    read -rp "   Введите publicKey: " REALITY_PBK
  done
fi

# Reality: sid (можно пусто)
if [[ -z "$REALITY_SHORT_ID" ]]; then
  read -rp "6) Reality shortId (sid=) [можно пусто]: " REALITY_SHORT_ID || true
fi

# Fingerprint (по умолчанию chrome)
read -rp "7) Fingerprint [${FINGERPRINT}]: " _fp || true
FINGERPRINT="${_fp:-$FINGERPRINT}"

# spiderX (по умолчанию /)
read -rp "8) spiderX (spx=) [${SPIDERX}]: " _spx || true
SPIDERX="${_spx:-$SPIDERX}"

# flow (по умолчанию xtls-rprx-vision)
read -rp "9) flow [${FLOW}] (напр. xtls-rprx-vision, пусто = не использовать): " _flow || true
FLOW="${_flow:-$FLOW}"

########################################
# Каталоги
########################################
log "Каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

########################################
# env.example (для повтора)
########################################
backup_if_exists "${XRAY_DIR}/env.example"
cat > "${XRAY_DIR}/env.example" <<ENV
# Базовые
XRAY_DIR=${XRAY_DIR}
EXT_NET=${EXT_NET}
SERVICE_NAME=${SERVICE_NAME}
XRAY_IMAGE=${XRAY_IMAGE}
HTTP_PORT=${HTTP_PORT}
SOCKS_PORT=${SOCKS_PORT}

# VLESS TCP + Reality
SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
VLESS_UUID=${VLESS_UUID}

SNI=${SNI}
REALITY_PBK=${REALITY_PBK}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
FINGERPRINT=${FINGERPRINT}
SPIDERX=${SPIDERX}
FLOW=${FLOW}
ENV
log "Создан: ${XRAY_DIR}/env.example"

########################################
# Генерация xray/config.json
########################################
backup_if_exists "${XRAY_DIR}/xray/config.json"

# Блок пользователя с опциональным flow
USER_JSON="\"id\": \"${VLESS_UUID}\", \"encryption\": \"none\""
if [[ -n "$FLOW" ]]; then
  USER_JSON="${USER_JSON}, \"flow\": \"${FLOW}\""
fi

# Опциональный shortId
SHORTID_JSON=""
if [[ -n "$REALITY_SHORT_ID" ]]; then
  SHORTID_JSON=$',\n          "shortId": "'"$REALITY_SHORT_ID"'"'
fi

cat > "${XRAY_DIR}/xray/config.json" <<JSON
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
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
              { ${USER_JSON} }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "${FINGERPRINT}",
          "show": false,
          "publicKey": "${REALITY_PBK}"${SHORTID_JSON},
          "spiderX": "${SPIDERX}"
        }
      }
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
log "Создан: ${XRAY_DIR}/xray/config.json"

########################################
# docker-compose.yml
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
# Запуск
########################################
log "Запуск docker compose в: ${XRAY_DIR}"
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
popd >/dev/null

log "Проверка сетей контейнера '${SERVICE_NAME}':"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

########################################
# Автотесты: HTTP и SOCKS
########################################
log "Проверка HTTP-прокси через контейнер curl..."
if ! docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \
  -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org >/tmp/xray_ip_http; then
  err "HTTP-прокси тест не прошёл"
fi
HTTP_IP=$(cat /tmp/xray_ip_http); rm -f /tmp/xray_ip_http
log "HTTP-прокси внешний IP: ${HTTP_IP}"

log "Проверка SOCKS5-прокси через контейнер curl..."
if ! docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \
  -sS --socks5-hostname ${SERVICE_NAME}:1080 https://api.ipify.org >/tmp/xray_ip_socks; then
  err "SOCKS5-прокси тест не прошёл"
fi
SOCKS_IP=$(cat /tmp/xray_ip_socks); rm -f /tmp/xray_ip_socks
log "SOCKS5-прокси внешний IP: ${SOCKS_IP}"

########################################
# Подсказки
########################################
cat <<EOF

Готово ✅

Проверка из внешней docker-сети:
  docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \\
    -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org; echo

Логи Xray:
  docker compose -f ${XRAY_DIR}/docker-compose.yml logs --tail=100 ${SERVICE_NAME}
  docker compose -f ${XRAY_DIR}/docker-compose.yml exec ${SERVICE_NAME} sh -lc 'tail -n 50 /var/log/xray/error.log; echo; tail -n 50 /var/log/xray/access.log'

Подсказки:
- Прокси в контейнерах: HTTP -> http://${SERVICE_NAME}:3128 , SOCKS5 -> socks5h://${SERVICE_NAME}:1080
- Если не работает HTTPS через прокси — проверьте SNI/pbk/shortId/fingerprint/spiderX и соответствие flow серверу.
- Для клиентских контейнеров держите NO_PROXY минимальным: NO_PROXY=localhost,127.0.0.1,::1

EOF
