#!/bin/bash
# setup.sh – полностью интерактивный, не требует параметров
set -e

# --- Запрос Telegram-данных ---
read -rp "Введите Telegram Bot Token: " BOT_TOKEN
read -rp "Введите Telegram Chat ID:   " CHAT_ID
[[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && { echo "Оба параметра обязательны!"; exit 1; }

# --- Обновление системы и установка пакетов ---
echo "[*] Обновление списков пакетов..."
apt-get update -qq
echo "[*] Установка unattended-upgrades curl..."
apt-get install -y -qq unattended-upgrades curl

# --- Включение автообновлений ---
echo "[*] Включение unattended-upgrades..."
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' \
  | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- Скрипт проверки перезагрузки ---
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

# --- Добавление в cron (без дублирования) ---
CRON_JOB="*/30 * * * * $SCRIPT_PATH"
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -

# --- Первая проверка ---
echo "[*] Проверка необходимости перезагрузки..."
"$SCRIPT_PATH"

echo "[✅] Готово! Проверка будет выполняться каждые 30 минут."
