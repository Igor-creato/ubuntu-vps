#!/usr/bin/env bash
# Определение CHAT_ID по BOT_TOKEN через Telegram Bot API (long polling)
# Совместим с актуальными практиками Bash/Ubuntu на сегодня.

set -Eeuo pipefail
IFS=$'\n\t'

# ---- общие настройки ----
TIMEOUT=60   # сколько секунд ждать новое сообщение (можно переопределить флагом -t)
API_BASE="https://api.telegram.org"

usage() {
  printf 'Использование: %s [-t SECONDS]\n' "${0##*/}"
  exit 2
}

while getopts ":t:" opt; do
  case "$opt" in
    t) [[ "$OPTARG" =~ ^[0-9]+$ ]] || { echo "Некорректное число секунд: $OPTARG" >&2; exit 2; }
       TIMEOUT="$OPTARG" ;;
    *) usage ;;
  esac
done

cleanup() {
  # очистка чувствительных переменных из окружения
  unset BOT_TOKEN API LAST_UPDATE_ID
}
trap cleanup EXIT

# ---- проверка зависимостей (jq, curl) ----
need_pkgs=()
command -v jq >/dev/null 2>&1 || need_pkgs+=(jq)
command -v curl >/dev/null 2>&1 || need_pkgs+=(curl ca-certificates)

if ((${#need_pkgs[@]})); then
  echo "[*] Устанавливаю пакеты: ${need_pkgs[*]}"
  if (( EUID != 0 )); then
    # избегаем интерактива: DEBIAN_FRONTEND=noninteractive + sudo -n
    if ! sudo -n true 2>/dev/null; then
      echo "Требуются права администратора (sudo без запроса пароля). Запустите как root или настройте sudo." >&2
      exit 1
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_pkgs[@]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_pkgs[@]}"
  fi
fi

# ---- ввод токена ----
printf "Введите Telegram Bot Token: "
# скрываем ввод (секрет), но позволяем правки строки
stty -echo
IFS= read -r BOT_TOKEN
stty echo
printf "\n"

# быстрая валидация формата токена (типичный вид, но не гарантия)
if [[ -z "${BOT_TOKEN:-}" ]] || ! [[ "$BOT_TOKEN" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]]; then
  echo "Токен пустой или имеет неверный формат." >&2
  exit 1
fi

API="${API_BASE}/bot${BOT_TOKEN}"

# ---- если ранее был webhook, getUpdates не будет работать: удалим ----
# (webhook и getUpdates взаимоисключаемы)
curl --silent --show-error --fail --max-time 15 \
  "${API}/deleteWebhook" >/dev/null || true

# ---- получим последний update_id, чтобы не печатать устаревшие события ----
echo "[*] Проверяю существующие обновления…"
LAST_UPDATE_ID=$(
  curl --silent --show-error --fail --max-time 15 \
    "${API}/getUpdates?timeout=0&limit=1" \
  | jq -r '(.result | last | .update_id) // empty'
)

# ---- подсказка пользователю ----
echo "[*] Отправьте вашему боту любое сообщение в Telegram."
printf "    (ждём %d секунд, Ctrl+C — выход)\n" "$TIMEOUT"

# ---- длинное опросивание (long polling) с учётом offset и timeout ----
# Будем делать один длинный запрос (до 50 сек), затем при необходимости ещё.
SECONDS_LEFT=$TIMEOUT
while (( SECONDS_LEFT > 0 )); do
  # выставляем серверный timeout для long polling: min(50, оставшееся время)
  lp_timeout=$(( SECONDS_LEFT > 50 ? 50 : SECONDS_LEFT ))

  # формируем offset: следующий после последнего увиденного update_id
  offset_param=""
  if [[ -n "${LAST_UPDATE_ID:-}" ]]; then
    offset_param="&offset=$((LAST_UPDATE_ID + 1))"
  fi

  START_TS=$(date +%s)
  RESP_JSON=$(
    curl --silent --show-error --fail-with-body --max-time $((lp_timeout + 5)) \
         "${API}/getUpdates?timeout=${lp_timeout}${offset_param}&limit=1"
  ) || {
    # сеть могла глюкнуть: попробуем ещё, не падаем
    # уменьшаем оставшееся время и повторяем
    NOW_TS=$(date +%s)
    spent=$(( NOW_TS - START_TS ))
    (( spent > 0 )) || spent=1
    (( SECONDS_LEFT -= spent ))
    continue
  }

  # вытянем нужные поля из разных типов апдейтов (message/channel_post/edited_message/edited_channel_post)
  CHAT_ID=$(jq -r '
    .result
    | last
    | (.message // .edited_message // .channel_post // .edited_channel_post // empty)
    | .chat.id // empty
  ' <<<"$RESP_JSON")

  # обновим LAST_UPDATE_ID, чтобы не крутиться на одном апдейте
  NEW_LAST=$(jq -r '.result | last | .update_id // empty' <<<"$RESP_JSON")
  if [[ -n "$NEW_LAST" ]]; then
    LAST_UPDATE_ID="$NEW_LAST"
  fi

  if [[ -n "$CHAT_ID" ]]; then
    echo
    echo "Ваш CHAT_ID: $CHAT_ID"
    exit 0
  fi

  NOW_TS=$(date +%s)
  spent=$(( NOW_TS - START_TS ))
  (( spent > 0 )) || spent=1
  (( SECONDS_LEFT -= spent ))
done

echo
echo "❌ Сообщение не получено за ${TIMEOUT} секунд."
exit 1
