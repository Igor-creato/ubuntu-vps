#!/usr/bin/env bash
# install-xray.sh
# Разворачивает Xray (VLESS TCP + Reality) в Docker Compose в ~/xray.
# Создаёт/перезаписывает файлы:
#   - ./xray/config.json
#   - ./docker-compose.yml
#   - ./env.example
#
# Особенности:
# - HTTP (3128) и SOCKS5 (1080) доступны только внутри docker-сети EXT_NET (по умолчанию 'vpn').
# - Весь трафик inbounds → vless-out (жёсткая маршрутизация).
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
EXT_NET="${EXT_NET:-vpn}"                   # внешняя docker-сеть для n8n + xray (создадим, если её нет)
SERVICE_NAME="${SERVICE_NAME:-xray-client}" # имя контейнера
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:25.8.29}"

HTTP_PORT="${HTTP_PORT:-3128}"              # внутренний HTTP-прокси порт в контейнере
SOCKS_PORT="${SOCKS_PORT:-1080}"            # внутренний SOCKS5 порт в контейнере

# Поля VLESS TCP + Reality (будут спрошены)
SERVER_HOST="${SERVER_HOST:-}"              # хост сервера (без порта!)
SERVER_PORT="${SERVER_PORT:-}"              # порт сервера
VLESS_UUID="${VLESS_UUID:-}"                # UUID пользователя

SNI="${SNI:-}"                              # reality serverName (маскировка)
REALITY_PBK="${REALITY_PBK:-}"              # reality publicKey (pbk)
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"    # reality shortId (sid) — можно пусто
FINGERPRINT="${FINGERPRINT:-chrome}"        # fp (по умолчанию chrome)
SPIDERX="${SPIDERX:-/}"                     # spx (по умолчанию "/")
FLOW="${FLOW:-xtls-rprx-vision}"            # flow (по умолчанию xtls-rprx-vision)

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
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_host_no_port() {
  # запрещаем двоеточие (порт) — нужно только имя/домен/IPv4/IPv6 без []
  [[ "$1" != *:* ]]
}

# URL-decode для значений query (?a=b&spx=%2F ...)
urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# Получить значение параметра key из QUERY-строки (без '?'), без декодирования
qget() {
  local key="$1" q="$2"
  printf '%s\n' "$q" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n1
}

# Создать docker-сеть, если её нет
ensure_network() {
  local net="$1"
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    log "Сеть '$net' не найдена — создаю..."
    docker network create "$net"
    log "Сеть '$net' создана."
  else
    log "Сеть '$net' уже существует."
  fi
}

########################################
# Проверки окружения
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. Установите Docker Compose."

# ВАЖНО: вместо жёсткой проверки — создаём сеть EXT_NET (по умолчанию 'vpn')
ensure_network "$EXT_NET"

########################################
# Ввод VLESS URL (опционально). Если введён — парсим и отключаем ручной ввод.
########################################
DO_INTERACTIVE=1
read -rp "Вставьте VLESS URL (Enter — ручной ввод): " VLESS_URL || true
if [[ -n "${VLESS_URL}" ]]; then
  # Пример: vless://<UUID>@host:port?type=tcp&security=reality&pbk=...&fp=chrome&sni=...&sid=...&spx=%2F&flow=...#TAG
  if [[ ! "$VLESS_URL" =~ ^vless:// ]]; then
    err "Неверная схема ссылки. Ожидается vless://"
  fi

  local_noscheme="${VLESS_URL#vless://}"

  # userinfo@rest
  local_userinfo="${local_noscheme%%@*}"
  local_rest="${local_noscheme#*@}"

  # UUID
  VLESS_UUID="$local_userinfo"

  # rest -> hostport[?query][#frag]
  local_hostport_qfrag="$local_rest"
  local_hostport="${local_hostport_qfrag%%\?*}"
  local_qfrag="${local_hostport_qfrag#*\?}"
  local_query="$local_qfrag"
  if [[ "$local_hostport_qfrag" == "$local_hostport" ]]; then
    local_query=""
  else
    local_query="${local_query%%\#*}"
  fi

  # Разбор host и port (IPv6 может быть в [])
  if [[ "$local_hostport" =~ ^\[(.+)\]:([0-9]{1,5})$ ]]; then
    SERVER_HOST="${BASH_REMATCH[1]}"
    SERVER_PORT="${BASH_REMATCH[2]}"
  else
    SERVER_HOST="${local_hostport%:*}"
    SERVER_PORT="${local_hostport##*:}"
  fi

  # Параметры из query
  local_type="$(qget type "$local_query")"
  local_sec="$(qget security "$local_query")"
  local_pbk="$(qget pbk "$local_query")"
  local_fp="$(qget fp "$local_query")"
  local_sni="$(qget sni "$local_query")"
  local_sid="$(qget sid "$local_query")"
  local_spx="$(qget spx "$local_query")"
  local_flow="$(qget flow "$local_query")"

  # Присваиваем (с декодированием где нужно)
  [[ -n "$local_pbk" ]] && REALITY_PBK="$local_pbk"
  [[ -n "$local_fp"  ]] && FINGERPRINT="$local_fp"
  [[ -n "$local_sni" ]] && SNI="$(urldecode "$local_sni")"
  [[ -n "$local_sid" ]] && REALITY_SHORT_ID="$(urldecode "$local_sid")"
  if [[ -n "$local_spx" ]]; then
    SPIDERX="$(urldecode "$local_spx")"
  fi
  [[ -n "$local_flow" ]] && FLOW="$local_flow"

  # Лёгкая валидация
  validate_uuid "$VLESS_UUID" || err "UUID из ссылки некорректен."
  validate_port "${SERVER_PORT:-0}" || err "Порт из ссылки некорректен."
  [[ -n "${SERVER_HOST}" ]] || err "Хост в ссылке пустой."
  [[ "${local_sec:-}" == "reality" ]] || log "Предупреждение: security='${local_sec:-}' (ожидалось 'reality')."
  [[ "${local_type:-}" == "tcp" ]] || log "Предупреждение: type='${local_type:-}' (ожидалось 'tcp')."

  DO_INTERACTIVE=0
  log "Параметры успешно получены из VLESS URL. Ручной ввод пропущен."
fi

########################################
# Интерактивные вопросы (минимально необходимое)
########################################
if [[ "${DO_INTERACTIVE}" -eq 1 ]]; then
  # Host
  if [[ -z "${SERVER_HOST}" ]] || ! validate_host_no_port "${SERVER_HOST}"; then
    while true; do
      read -rp "1) SERVER_HOST (домен/IP сервера, БЕЗ порта): " SERVER_HOST
      [[ -n "${SERVER_HOST}" ]] && validate_host_no_port "${SERVER_HOST}" && break
      echo "   Неверно. Укажите домен/IP БЕЗ :порт"
    done
  fi

  # Port
  if ! validate_port "${SERVER_PORT:-}"; then
    while true; do
      read -rp "2) SERVER_PORT: " SERVER_PORT
      validate_port "${SERVER_PORT}" && break
      echo "   Порт должен быть от 1 до 65535."
    done
  fi

  # UUID
  if ! validate_uuid "${VLESS_UUID:-}"; then
    while true; do
      read -rp "3) VLESS UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " VLESS_UUID
      validate_uuid "${VLESS_UUID}" && break
      echo "   Неверный формат UUID."
    done
  fi

  # Reality: SNI
  if [[ -z "${SNI}" ]]; then
    while true; do
      read -rp "4) Reality SNI/ServerName (напр. creativecommons.org): " SNI
      [[ -n "${SNI}" ]] && break
    done
  fi

  # Reality: pbk
  if [[ -z "${REALITY_PBK}" ]]; then
    while true; do
      read -rp "5) Reality publicKey (pbk=): " REALITY_PBK
      [[ -n "${REALITY_PBK}" ]] && break
    done
  fi

  # Reality: sid (можно пусто)
  if [[ -z "${REALITY_SHORT_ID}" ]]; then
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
fi

########################################
# Каталоги
########################################
log "Каталоги: ${XRAY_DIR} и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}" "${XRAY_DIR}/logs"

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
# Генерация xray/config.json (только VLESS TCP + Reality)
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
  SHORTID_JSON=",
          \"shortId\": \"${REALITY_SHORT_ID}\""
fi

cat > "${XRAY_DIR}/config.json" <<JSON
{
  "log": { "access": "/dev/stdout", "error": "/dev/stderr", "loglevel": "debug" },

  "inbounds": [
    { "tag": "http-in",  "listen": "0.0.0.0", "port": ${HTTP_PORT},  "protocol": "http" },
    { "tag": "socks-in", "listen": "0.0.0.0", "port": ${SOCKS_PORT}, "protocol": "socks", "settings": { "udp": true } }
  ],

  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${SERVER_HOST}",
          "port": ${SERVER_PORT},
          "users": [{ ${USER_JSON} }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "publicKey": "${REALITY_PBK}"${SHORTID_JSON},
          "spiderX": "${SPIDERX}",
          "fingerprint": "${FINGERPRINT}"
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
services:
  ${SERVICE_NAME}:
    image: ${XRAY_IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    environment:
      - TZ=Europe/Amsterdam
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    # - ./logs:/var/log/xray
    command: ["run", "-c", "/etc/xray/config.json"]
    networks:
      - ${EXT_NET}
    # Порты наружу НЕ публикуем: доступ к 3128/1080 только из сети '${EXT_NET}'
    healthcheck:
      test: ["CMD", "/usr/local/bin/xray", "-test", "-config", "/etc/xray/config.json"]
      interval: 30s
      timeout: 5s
      retries: 5
    # Немного безопасности и чистоты логов Docker
    security_opt:
      - no-new-privileges:true
    cap_drop: ["ALL"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

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

cat <<EOF

Готово ✅

Проверка из сети '${EXT_NET}':
  docker run --rm --network ${EXT_NET} curlimages/curl:8.11.1 \\
    -sS -x http://${SERVICE_NAME}:3128 https://api.ipify.org; echo

Подключение n8n к VPN:
  # в проекте ~/n8n создайте docker-compose.override.yml:
  #
  # services:
  #   n8n:
  #     networks:
  #       - proxy   # для Traefik
  #       - vpn     # доступ к xray-client
  #     environment:
  #       HTTP_PROXY:  http://${SERVICE_NAME}:3128
  #       HTTPS_PROXY: http://${SERVICE_NAME}:3128
  #       NO_PROXY: >-
  #         localhost,127.0.0.1,::1,n8n,n8n-n8n-1,postgres,n8n-postgres-1,traefik,traefik-traefik-1,*.local,*.lan
  #
  # networks:
  #   vpn:
  #     external: true
  #   proxy:
  #     external: true

Подсказки:
- Xray изолирован в сети '${EXT_NET}' (по умолчанию 'vpn'), доступ извне не требуется.
- Traefik НЕ должен проксировать xray; проксируйте только n8n по сети 'proxy'.
EOF
