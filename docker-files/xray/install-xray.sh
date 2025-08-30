#!/usr/bin/env bash
# install-xray.sh
# Разворачивает Xray (VLESS TCP + Reality) в Docker Compose в ~/xray.
# Теперь умеет разбирать VLESS-ссылку: --vless-url 'vless://...'
#
# Создаёт/перезаписывает:
#   - ~/xray/xray/config.json
#   - ~/xray/docker-compose.yml
#   - ~/xray/env.example
#
# Поддерживаемые флаги/ENV:
#   --vless-url 'vless://...'      # разбор всех параметров из ссылки
#   --image NAME:TAG               # версия образа (по умолчанию teddysun/xray:1.8.23)
#   --dir PATH                     # куда ставить (по умолчанию ~/xray)
#   --net proxy                    # внешняя docker-сеть
#   --service xray-client          # имя контейнера
#
# Также можно задать ENV переменные: XRAY_DIR, EXT_NET, SERVICE_NAME, XRAY_IMAGE
#
# Документация:
#   Docker/Compose: https://docs.docker.com/
#   Xray Reality:   https://xtls.github.io/

set -Eeuo pipefail

########################################
# Значения по умолчанию
########################################
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"
EXT_NET="${EXT_NET:-proxy}"
SERVICE_NAME="${SERVICE_NAME:-xray-client}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:1.8.23}"

HTTP_PORT="${HTTP_PORT:-3128}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

# Параметры соединения (заполнятся из ссылки или интерактивно)
SERVER_HOST="${SERVER_HOST:-}"
SERVER_PORT="${SERVER_PORT:-}"
VLESS_UUID="${VLESS_UUID:-}"
SNI="${SNI:-}"
REALITY_PBK="${REALITY_PBK:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"    # опционально
FINGERPRINT="${FINGERPRINT:-chrome}"        # по умолчанию
SPIDERX="${SPIDERX:-/}"                     # по умолчанию
FLOW="${FLOW:-xtls-rprx-vision}"            # по умолчанию

VLESS_URL="${VLESS_URL:-}"

########################################
# Парсер аргументов
########################################
usage() {
  cat <<'USAGE'
Использование: ./install-xray.sh [опции]

Опции:
  --vless-url "vless://UUID@HOST:PORT?type=tcp&security=reality&pbk=...&fp=...&sni=...&sid=...&spx=...&flow=..."
  --image NAME:TAG           Образ Xray (по умолчанию: teddysun/xray:1.8.23)
  --dir PATH                 Каталог установки (по умолчанию: ~/xray)
  --net NAME                 Внешняя docker-сеть (по умолчанию: proxy)
  --service NAME             Имя контейнера/сервиса (по умолчанию: xray-client)
  -h, --help                 Показать помощь
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vless-url) VLESS_URL="$2"; shift 2 ;;
    --image) XRAY_IMAGE="$2"; shift 2 ;;
    --dir) XRAY_DIR="$2"; shift 2 ;;
    --net) EXT_NET="$2"; shift 2 ;;
    --service) SERVICE_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
  esac
done

########################################
# Утилиты
########################################
log() { echo -e "[\e[34mINFO\e[0m]  $(date +'%F %T')  $*"; }
err() { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T')  $*" >&2; exit 1; }

backup_if_exists() {
  local f="$1"
  [[ -f "$f" ]] && cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)" && log "Бэкап: $f -> $f.bak.*"
}

ensure_cmd() { command -v "$1" >/dev/null 2>&1 || err "Не найдена команда '$1'."; }

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}
validate_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
validate_host_no_port() { [[ "$1" != *:* ]]; }

urldecode() {
  # URL-decode без внешних зависимостей
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

parse_vless_url() {
  local url="$1"
  [[ "$url" == vless://* ]] || err "Ссылка должна начинаться с vless://"

  local rest="${url#vless://}"              # UUID@host:port?query#tag
  local uuid="${rest%%@*}"                  # до @
  local after_at="${rest#*@}"

  local hostport="${after_at%%\?*}"         # до ?
  local host="${hostport%%:*}"
  local port="${hostport##*:}"

  local query="${after_at#*\?}"             # после ?
  query="${query%%#*}"                      # до #

  # разобрать query
  declare -A q; local kv k v
  IFS='&' read -r -a kv <<< "$query"
  for pair in "${kv[@]:-}"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    v="$(urldecode "$v")"
    [[ -n "$k" ]] && q["$k"]="$v"
  done

  # валидация и присваивание
  VLESS_UUID="$uuid"
  SERVER_HOST="$host"
  SERVER_PORT="$port"

  local type="${q[type]:-}"
  local security="${q[security]:-}"
  [[ "$type" == "tcp" ]] || warn_msg+="[WARN] type != tcp (type=${type}) — скрипт рассчитан на TCP.\n"
  [[ "$security" == "reality" ]] || warn_msg+="[WARN] security != reality (security=${security}) — скрипт рассчитан на Reality.\n"

  REALITY_PBK="${q[pbk]:-}"
  FINGERPRINT="${q[fp]:-chrome}"
  SNI="${q[sni]:-}"
  REALITY_SHORT_ID="${q[sid]:-}"
  SPIDERX="${q[spx]:-"/"}"
  FLOW="${q[flow]:-xtls-rprx-vision}"

  # sanity checks
  validate_uuid "$VLESS_UUID" || err "UUID в ссылке неверного формата: $VLESS_UUID"
  validate_host_no_port "$SERVER_HOST" || err "Хост в ссылке содержит порт/скобки: $SERVER_HOST"
  validate_port "$SERVER_PORT" || err "Порт в ссылке некорректен: $SERVER_PORT"
  [[ -n "$SNI" ]] || err "В ссылке не указан sni= (обязательно для Reality)"
  [[ -n "$REALITY_PBK" ]] || err "В ссылке не указан pbk= (publicKey обязательно для Reality)"

  # вывести предупреждения, если есть
  if [[ -n "${warn_msg:-}" ]]; then
    echo -e "$warn_msg" >&2
  fi
}

########################################
# Проверки окружения
########################################
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. Установите Docker Compose."
docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте:  docker network create $EXT_NET"

########################################
# Разбор ссылки (если передана) или интерактив
########################################
if [[ -n "$VLESS_URL" ]]; then
  parse_vless_url "$VLESS_URL"
else
  # Минимальный интерактив
  if [[ -z "$SERVER_HOST" ]]; then
    read -rp "SERVER_HOST (без порта): " SERVER_HOST
    until validate_host_no_port "$SERVER_HOST" && [[ -n "$SERVER_HOST" ]]; do
      read -rp "   SERVER_HOST (без :порт): " SERVER_HOST
    done
  fi
  if [[ -z "$SERVER_PORT" ]]; then
    read -rp "SERVER_PORT: " SERVER_PORT
    until validate_port "$SERVER_PORT"; do read -rp "   SERVER_PORT: " SERVER_PORT; done
  fi
  if [[ -z "$VLESS_UUID" ]]; then
    read -rp "VLESS UUID: " VLESS_UUID
    until validate_uuid "$VLESS_UUID"; do read -rp "   UUID: " VLESS_UUID; done
  fi
  if [[ -z "$SNI" ]]; then
    read -rp "SNI (напр. creativecommons.org): " SNI
    while [[ -z "$SNI" ]]; do read -rp "   SNI: " SNI; done
  fi
  if [[ -z "$REALITY_PBK" ]]; then
    read -rp "Reality publicKey (pbk): " REALITY_PBK
    while [[ -z "$REALITY_PBK" ]]; do read -rp "   pbk: " REALITY_PBK; done
  fi
  read -rp "Reality shortId (sid) [пусто]: " REALITY_SHORT_ID || true
  read -rp "Fingerprint [${FINGERPRINT}]: " _fp || true; FINGERPRINT="${_fp:-$FINGERPRINT}"
  read -rp "spiderX (spx) [${SPIDERX}]: " _spx || true; SPIDERX="${_spx:-$SPIDERX}"
  read -rp "flow [${FLOW}] (напр. xtls-rprx-vision, пусто = не использовать): " _flow || true; FLOW="${_flow:-$FLOW}"
fi

########################################
# Каталоги и env.example
########################################
log "Каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

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

SNI=${SNI}
REALITY_PBK=${REALITY_PBK}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
FINGERPRINT=${FINGERPRINT}
SPIDERX=${SPIDERX}
FLOW=${FLOW}
ENV
log "Создан: ${XRAY_DIR}/env.example"

########################################
# Генерация config.json
########################################
backup_if_exists "${XRAY_DIR}/xray/config.json"

USER_JSON="\"id\": \"${VLESS_UUID}\", \"encryption\": \"none\""
[[ -n "$FLOW" ]] && USER_JSON="${USER_JSON}, \"flow\": \"${FLOW}\""

SHORTID_JSON=""
[[ -n "$REALITY_SHORT_ID" ]] && SHORTID_JSON=$',\n          "shortId": "'"$REALITY_SHORT_ID"'"'

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
# Запуск и автопроверка
########################################
log "Запуск docker compose в: ${XRAY_DIR}"
pushd "${XRAY_DIR}" >/dev/null
docker compose pull
docker compose up -d
popd >/dev/null

log "Проверка сетей контейнера '${SERVICE_NAME}':"
docker inspect "${SERVICE_NAME}" --format '{{json .NetworkSettings.Networks}}' || true

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
- Для клиентских контейнеров держите NO_PROXY минимальным: NO_PROXY=localhost,127.0.0.1,::1
- Если HTTPS не ходит — проверьте sni/pbk/sid/fingerprint/spiderX и flow.

EOF
