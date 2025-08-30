#!/usr/bin/env bash
# install-xray.sh — VLESS TCP + Reality в Docker Compose (~/xray)
# Вставьте VLESS URL вида:
# vless://UUID@HOST:PORT?type=tcp&security=reality&pbk=...&fp=...&sni=...&sid=...&spx=%2F&flow=xtls-rprx-vision

set -eE -o pipefail
set -o errtrace
trap 'echo -e "[\e[31mERROR\e[0m] $(date +%F\ %T) На строке $LINENO произошла ошибка. См. вывод выше." >&2' ERR

# ====== дефолты (можно переопределить ENV) ======
XRAY_DIR="${XRAY_DIR:-$HOME/xray}"
EXT_NET="${EXT_NET:-proxy}"
SERVICE_NAME="${SERVICE_NAME:-xray-client}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:1.8.23}"
HTTP_PORT="${HTTP_PORT:-3128}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

# Заполняются из ссылки/ручного ввода
SERVER_HOST="${SERVER_HOST:-}"
SERVER_PORT="${SERVER_PORT:-}"
VLESS_UUID="${VLESS_UUID:-}"
SNI="${SNI:-}"
REALITY_PBK="${REALITY_PBK:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"   # опционально
FINGERPRINT="${FINGERPRINT:-chrome}"
SPIDERX="${SPIDERX:-/}"
FLOW="${FLOW:-xtls-rprx-vision}"

# ====== утилиты ======
log() { echo -e "[\e[34mINFO\e[0m]  $(date +'%F %T')  $*"; }
err() { echo -e "[\e[31mERROR\e[0m] $(date +'%F %T')  $*" >&2; exit 1; }
backup_if_exists(){ local f="$1"; [[ -f "$f" ]] && cp -f "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)" && log "Бэкап: $f -> $f.bak.*"; }
ensure_cmd(){ command -v "$1" >/dev/null 2>&1 || err "Не найдена команда '$1'."; }
validate_uuid(){ [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
validate_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1>=1 && $1<=65535 )); }
validate_host_no_port(){ [[ "$1" != *:* ]]; }
urldecode(){ local data="${1//+/ }"; printf '%b' "${data//%/\\x}"; }

parse_vless_url() {
  local url="$1"
  [[ "$url" == vless://* ]] || err "Ссылка должна начинаться с vless://"

  local rest="${url#vless://}"               # UUID@host:port?query#tag
  local uuid="${rest%%@*}"                   # до @
  local after_at="${rest#*@}"
  [[ "$after_at" == "$rest" ]] && err "Некорректная ссылка: отсутствует '@'"

  local hostport="${after_at%%\?*}"          # до ?
  local host="${hostport%%:*}"
  local port="${hostport##*:}"

  local query="${after_at#*\?}"; query="${query%%#*}"

  # разбираем query без ассоц. массивов
  local type="" security="" pbk="" fp="" sni="" sid="" spx="" flow=""
  if [[ -n "$query" ]]; then
    IFS='&' read -r -a _pairs <<< "$query"
    for pair in "${_pairs[@]}"; do
      [[ -z "$pair" ]] && continue
      local k="${pair%%=*}"
      local v=""; [[ "$pair" == *"="* ]] && v="${pair#*=}"
      v="$(urldecode "$v")"
      case "$k" in
        type) type="$v" ;;
        security) security="$v" ;;
        pbk) pbk="$v" ;;
        fp) fp="$v" ;;
        sni) sni="$v" ;;
        sid) sid="$v" ;;
        spx) spx="$v" ;;
        flow) flow="$v" ;;
      esac
    done
  fi

  # присваиваем
  VLESS_UUID="$uuid"
  SERVER_HOST="$host"
  SERVER_PORT="$port"
  [[ -n "$fp" ]]  && FINGERPRINT="$fp"
  [[ -n "$sni" ]] && SNI="$sni"
  [[ -n "$pbk" ]] && REALITY_PBK="$pbk"
  [[ -n "$sid" ]] && REALITY_SHORT_ID="$sid"
  [[ -n "$spx" ]] && SPIDERX="$spx"
  [[ -n "$flow" ]]&& FLOW="$flow"

  # sanity
  validate_uuid "$VLESS_UUID"          || err "UUID неверного формата: $VLESS_UUID"
  validate_host_no_port "$SERVER_HOST" || err "HOST должен быть без порта/скобок: $SERVER_HOST"
  validate_port "$SERVER_PORT"         || err "PORT некорректен: $SERVER_PORT"
  [[ -n "$SNI" ]]                      || err "В ссылке не указан sni="
  [[ -n "$REALITY_PBK" ]]              || err "В ссылке не указан pbk="

  # предупреждения
  [[ "${type:-tcp}" == "tcp" ]] || log "WARN: type=${type:-<пусто>} (скрипт рассчитан на TCP)"
  [[ "${security:-reality}" == "reality" ]] || log "WARN: security=${security:-<пусто>} (скрипт рассчитан на Reality)"
}

# ====== проверки окружения ======
ensure_cmd docker
docker compose version >/dev/null 2>&1 || err "'docker compose' недоступен. Установите Docker Compose."
docker network inspect "$EXT_NET" >/dev/null 2>&1 || err "Внешняя сеть '$EXT_NET' не найдена. Создайте:  docker network create $EXT_NET"

# ====== запрос ссылки (или ручной ввод) ======
read -rp "Вставьте VLESS URL (Enter — ручной ввод): " VLESS_URL || true
if [[ -n "${VLESS_URL:-}" ]]; then
  parse_vless_url "$VLESS_URL"
else
  # минимальный ручной ввод
  if [[ -z "$SERVER_HOST" ]]; then
    read -rp "SERVER_HOST (без порта): " SERVER_HOST
    until validate_host_no_port "$SERVER_HOST" && [[ -n "$SERVER_HOST" ]]; do read -rp "   SERVER_HOST: " SERVER_HOST; done
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
  read -rp "flow [${FLOW}]: " _flow || true; FLOW="${_flow:-$FLOW}"
fi

# Кратко покажем, что распарсили (для отладки)
log "Параметры: host=${SERVER_HOST} port=${SERVER_PORT} uuid=${VLESS_UUID}"
log "Reality: sni=${SNI} pbk=${REALITY_PBK} sid=${REALITY_SHORT_ID:-<пусто>} fp=${FINGERPRINT} spx=${SPIDERX} flow=${FLOW:-<пусто>}"

# ====== каталоги и env ======
log "Каталоги: ${XRAY_DIR}/xray и ${XRAY_DIR}/logs"
mkdir -p "${XRAY_DIR}/xray" "${XRAY_DIR}/logs"

backup_if_exists "${XRAY_DIR}/env.example"
cat > "${XRAY_DIR}/env.example" <<EOF
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
EOF
log "Создан: ${XRAY_DIR}/env.example"

# ====== config.json ======
backup_if_exists "${XRAY_DIR}/xray/config.json"
USER_JSON="\"id\": \"${VLESS_UUID}\", \"encryption\": \"none\""
[[ -n "${FLOW}" ]] && USER_JSON="${USER_JSON}, \"flow\": \"${FLOW}\""
SHORTID_JSON=""
[[ -n "${REALITY_SHORT_ID}" ]] && SHORTID_JSON=$',\n          "shortId": '"'"$REALITY_SHORT_ID"'"''

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
      { "type": "field", "inboundTag": ["http-in","socks-in"], "outboundTag": "vless-out" }
    ]
  }
}
JSON
log "Создан: ${XRAY_DIR}/xray/config.json"

# ====== docker-compose.yml ======
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

# ====== запуск и автопроверка ======
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
- NO_PROXY держите минимальным: NO_PROXY=localhost,127.0.0.1,::1
- Если HTTPS не ходит — перепроверьте sni/pbk/sid/fingerprint/spiderX и flow.
EOF
