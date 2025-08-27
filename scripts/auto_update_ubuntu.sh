#!/usr/bin/env bash
# setup.sh – установка автообновлений + Telegram-уведомлений
set -euo pipefail

# --- функция для отправки сообщения в Telegram ---
send_tg() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
         -d chat_id="${CHAT_ID}" \
         -d text="$msg" >/dev/null
}

# --- запрос Telegram-данных ---
read -rp "Введите Telegram Bot Token: " BOT_TOKEN
read -rp "Введите Telegram Chat ID:   " CHAT_ID

# --- тестовое сообщение ---
echo "[*] Отправляем тестовое сообщение..."
send_tg "✅ Скрипт установки автообновлений запущен на $(hostname)."

# --- обновление системы и установка пакетов ---
echo "[*] Обновление списков пакетов..."
apt-get update -qq
echo "[*] Установка unattended-upgrades curl..."
apt-get install -y -qq unattended-upgrades curl

# --- включение автообновлений ---
echo "[*] Включение unattended-upgrades..."
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- скрипт, который cron будет запускать ---
SCRIPT_PATH="/usr/local/bin/check_reboot_and_notify.sh"
cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
if [ -f /var/run/reboot-required ]; then
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
         -d chat_id="\${CHAT_ID}" \
         -d text="🔁 Сервер \$(hostname) требует перезагрузки после обновлений." >/dev/null
fi
EOF
chmod +x "$SCRIPT_PATH"

# --- запрос интервала проверки ---
read -rp "Как часто проверять необходимость перезагрузки? (в формате cron, по умолчанию: 0 9 * * *) " CRON_TIME
CRON_TIME=${CRON_TIME:-0 9 * * *}   # по умолчанию в 9:00 каждый день

# --- добавление в cron (без дублирования) ---
CRON_JOB="${CRON_TIME} ${SCRIPT_PATH}"
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -

# --- первая проверка ---
echo "[*] Проверка необходимости перезагрузки..."
"$SCRIPT_PATH"

echo "[✅] Готово!"
echo "   • Тестовое сообщение отправлено."
echo "   • Проверка перезагрузки: «${CRON_TIME} ${SCRIPT_PATH}»"
echo "   • Чтобы изменить интервал: sudo crontab -e"
