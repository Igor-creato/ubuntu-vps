#!/usr/bin/env bash
# install-xray.sh — Разворачивает Xray (VLESS-клиент) в Docker Compose в ~/xray.
# - Поднимает HTTP-прокси (3128) и SOCKS5 (1080) ДОСТУПНЫЕ ТОЛЬКО внутри docker-сети 'proxy'
# - Ничего не публикует наружу (без ports:)
# - Добавлен корректный healthcheck (проверка бинаря xray), включён access-лог
# Документация: https://docs.docker.com/ , https://xtls.github.io/
# Требования: docker, "docker compose" (plugin), существующая внешняя сеть Docker 'proxy'

set -Eeuo pipefail

# ===== Настройки =====
XRAY_DIR="${HOME}/xray"
EXT_NET="proxy"                  # внешняя сеть Docker
SERVICE_NAME="xray-client"
XRAY_IMAGE="teddysun/xray:latest"
HTTP_PORT=3128
SOCKS_PORT=1080

# Будут запрошены интерактивно:
SERVER_ADDR=""
SERVER_PORT="443"
VLESS_UUID=""
TRANSPORT="ws"                   # ws | tcp
TLS_ENABLE="true"                # true | false
WS_PATH="/vless"

log() { echo -e "[\e[34mINFO\e[0m] $*"; }
err() { echo -e "[\e[31mERROR\e[0m] $*" >&2; }

# ===== Проверки окружения =====
command -v docker >/dev/null 2>&1 || { err "Не найден docker. Установка: https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "'docker compose' недоступен. См.: https://docs.docker.com/compose/install/linux/"; exit 1; }
docker network inspect "$EXT_NET" >/dev/null 2>&1 || { err "Сеть '$EXT_NET' не найдена. Доступные: $(docker network ls --format '{{.Name}}' | tr '\n' ' ')"; exit 1; }

# ===== Сбор параметров =====
read -rp "Домен/IP VLESS-сервера (например, NL): " SERVER_ADDR
while [[ -z "$SERVER_ADDR" ]]; do read -rp "Пусто. Введи домен/IP: " SERVER_ADDR; done

read -rp "Порт VLESS [${SERVER_PORT}]: " _p || true; SERVER_PORT="${_p:-$SERVER_PORT}"

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
log "Создаю каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

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
  "log": {
    "access": "/var/log/xray/access.log",
    "loglevel": "warning"
  },
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

# ===== Пишем docker-compose.yml =====
cat > "${XRAY_DIR}/docker-compose.yml" <<YAML
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
    healthcheck:
      test: ["CMD", "/usr/bin/xray", "-version"]
      interval: 30s
      timeout: 5s
      retries: 3

networks:
  ${EXT_NET}:
    external: true
YAML

# ===== Запуск =====
log "Запускаю стек в ${XRAY_DIR} ..."
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
docker compose ps
popd >/dev/null

log "Проверка: контейнер '${SERVICE_NAME}' должен быть в сети '${EXT_NET}'"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

cat <<'NEXT'

Готово ✅

Дальше:
1) Убедись, что n8n подключён к сети 'proxy' и использует прокси в переменных окружения:
   - верхний регистр:  HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY
   - нижний регистр:   http_proxy / https_proxy / all_proxy / no_proxy
   Значение прокси:    http://xray-client:3128

2) Диагностика трафика через прокси:
   # окно 1 — следим за логом Xray
   docker compose -f ~/xray/docker-compose.yml exec xray-client sh -lc 'tail -f /var/log/xray/access.log'

   # окно 2 — из контейнера n8n отправляем запрос строго через прокси
   docker compose -f ~/n8n/docker-compose.yml exec n8n sh -lc \
     'apk add --no-cache curl 2>/dev/null || true; curl -s -x http://xray-client:3128 https://api.ipify.org && echo'

   В access.log должны появиться записи от inbound http-in → outbound vless-out.
   Вернувшийся IP должен быть IP со стороны VLESS-провайдера, а не IP хоста.

3) Если некоторая нода в n8n всё равно обходит прокси — укажи
   прокси явно в параметрах узла (HTTP Request → Proxy = http://xray-client:3128).

NEXT
