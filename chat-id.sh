#!/bin/bash
# Получение CHAT_ID по BOT_TOKEN
set -e

# --- проверка/установка jq ---
if ! command -v jq &>/dev/null; then
    echo "[*] Устанавливаем jq..."
    sudo apt-get update -qq && sudo apt-get install -y -qq jq curl
fi

# --- ввод токена ---
read -rp "Введите Telegram Bot Token: " BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && { echo "Токен не может быть пустым!"; exit 1; }

API="https://api.telegram.org/bot${BOT_TOKEN}"

echo "[*] Проверяем наличие старых обновлений..."
curl -s "${API}/getUpdates?offset=-1" | jq -r '.result[].message.chat.id' 2>/dev/null || true

echo "[*] Отправьте вашему боту любое сообщение в Telegram..."
echo "    (ждём 60 секунд или нажмите Ctrl+C для выхода)"

# цикл ожидания нового сообщения
for i in {1..60}; do
    RESP=$(curl -s "${API}/getUpdates" | jq -r '.result[-1].message.chat.id // empty')
    if [[ -n "$RESP" ]]; then
        echo
        echo "Ваш CHAT_ID: $RESP"
        exit 0
    fi
    sleep 1
done

echo
echo "❌ Сообщение не получено за 60 секунд."
exit 1
