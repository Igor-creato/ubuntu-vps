#!/usr/bin/env bash
# setup.sh – автообновления Ubuntu + уведомления в Telegram о необходимости перезагрузки
# Требования: Ubuntu 20.04/22.04/24.04+, systemd
# Документация:
# - Ubuntu | unattended-upgrades: man unattended-upgrades, /etc/apt/apt.conf.d/50unattended-upgrades
# - APT Periodic: /etc/apt/apt.conf.d/20auto-upgrades
# - systemd.unit(5), systemd.timer(5)

set -euo pipefail

# ---------------------------
# 0. Предварительные проверки
# ---------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERR] Запустите скрипт от root (sudo -i; ./setup.sh)" >&2
  exit 1
fi

command -v systemctl >/dev/null 2>&1 || {
  echo "[ERR] systemd не обнаружен. Этот скрипт рассчитан на Ubuntu с systemd." >&2
  exit 1
}

# ---------------------------
# 1. Ввод параметров Telegram
# ---------------------------
read -srp "Введите Telegram Bot Token: " BOT_TOKEN; echo
read -rp  "Введите Telegram Chat ID:   " CHAT_ID

# Базовая валидация ввода
if [[ -z "${BOT_TOKEN}" || -z "${CHAT_ID}" ]]; then
  echo "[ERR] BOT_TOKEN и CHAT_ID не должны быть пустыми." >&2
  exit 1
fi

# ---------------------------
# 2. Обновления и софт
# ---------------------------
export DEBIAN_FRONTEND=noninteractive

echo "[*] Обновление списка пакетов..."
apt-get update -qq

echo "[*] Установка необходимых пакетов: unattended-upgrades, curl"
apt-get install -y -qq unattended-upgrades curl

# ---------------------------
# 3. Включение автообновлений APT
# ---------------------------
# Настраиваем /etc/apt/apt.conf.d/20auto-upgrades (APT::Periodic)
# Эти параметры включают обновление списков, автоматическую установку security-обновлений,
# а также фоновую загрузку и чистку.
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
echo "[*] Настройка ${AUTO_UPGRADES_FILE}"

install -m 0644 /dev/null "${AUTO_UPGRADES_FILE}"
cat > "${AUTO_UPGRADES_FILE}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Дополнительно можно подстроить политику в /etc/apt/apt.conf.d/50unattended-upgrades
# Оставляем стандартные секции Ubuntu (Security, Updates). Если файл существует — не трогаем.
# Пользователь может позже настроить:
#   Unattended-Upgrade::Automatic-Reboot "true";
#   Unattended-Upgrade::Automatic-Reboot-Time "03:30";
# через /etc/apt/apt.conf.d/50unattended-upgrades
if [[ ! -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
  echo "[*] Файл 50unattended-upgrades отсутствует — создаю с дефолтами Ubuntu."
  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
        "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
fi

# ---------------------------
# 4. Файлы и юниты для уведомлений
# ---------------------------
ENV_FILE="/etc/telegram-notify"
SCRIPT_PATH="/usr/local/bin/check_reboot_and_notify.sh"
SERVICE_FILE="/etc/systemd/system/reboot-notify.service"
TIMER_FILE="/etc/systemd/system/reboot-notify.timer"

echo "[*] Сохраняю параметры в ${ENV_FILE} (только root)"
umask 077
cat > "${ENV_FILE}" <<EOF
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
EOF
chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}"

echo "[*] Создаю исполняемый скрипт проверки: ${SCRIPT_PATH}"
install -m 0755 /dev/null "${SCRIPT_PATH}"
cat > "${SCRIPT_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Загружаем переменные окружения
if [[ -f /etc/telegram-notify ]]; then
  # shellcheck disable=SC1091
  source /etc/telegram-notify
else
  echo "[ERR] Файл /etc/telegram-notify не найден." >&2
  exit 1
fi

send_tg() {
  local msg="$1"
  # Используем --data-urlencode на случай спецсимволов в тексте
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${CHAT_ID}" \
       --data-urlencode "text=${msg}" \
       >/dev/null
}

HOST="$(hostname)"

# Если по итогам обновлений требуется перезагрузка — пришлём сигнал
if [[ -f /var/run/reboot-required ]]; then
  send_tg "🔁 Сервер ${HOST} требует перезагрузки после обновлений."
fi
EOF

echo "[*] Создаю systemd service: ${SERVICE_FILE}"
cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Notify via Telegram if reboot is required
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/telegram-notify
ExecStart=/usr/local/bin/check_reboot_and_notify.sh
User=root
Group=root
Nice=10
RuntimeMaxSec=120
EOF

# Запросим у пользователя время в формате HH:MM для ежедневной проверки
read -rp "Во сколько ежедневно проверять? (HH:MM, по умолчанию 09:00): " CHECK_TIME
CHECK_TIME="${CHECK_TIME:-09:00}"

# Простейшая валидация HH:MM
if [[ ! "${CHECK_TIME}" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "[WARN] Неверный формат времени. Использую 09:00."
  CHECK_TIME="09:00"
fi

echo "[*] Создаю systemd timer: ${TIMER_FILE} (ежедневно в ${CHECK_TIME})"
cat > "${TIMER_FILE}" <<EOF
[Unit]
Description=Daily reboot-required check at ${CHECK_TIME}

[Timer]
OnCalendar=*-*-* ${CHECK_TIME}:00
Persistent=true
RandomizedDelaySec=180

[Install]
WantedBy=timers.target
EOF

# ---------------------------
# 5. Включение и первая проверка
# ---------------------------
echo "[*] Перезагружаю конфигурацию systemd, включаю и запускаю таймер..."
systemctl daemon-reload
systemctl enable --now reboot-notify.timer

# Тестовое сообщение (теперь curl точно установлен)
echo "[*] Отправляю тестовое сообщение в Telegram…"
if ! curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
     --data-urlencode "chat_id=${CHAT_ID}" \
     --data-urlencode "text=✅ Скрипт установки автообновлений запущен на $(hostname)." >/dev/null; then
  echo "[WARN] Не удалось отправить тестовое сообщение. Проверьте BOT_TOKEN/CHAT_ID и доступ в Интернет."
fi

# Первая проверка вручную
echo "[*] Выполняю первую проверку необходимости перезагрузки…"
systemctl start reboot-notify.service || true

echo
echo "[✅] Готово!"
echo "    • Автообновления APT включены (/etc/apt/apt.conf.d/20auto-upgrades)."
echo "    • Service: reboot-notify.service; Timer: reboot-notify.timer (ежедневно в ${CHECK_TIME})."
echo "    • Конфиг Telegram: ${ENV_FILE} (root:root, 600)."
echo "    • Скрипт проверки: ${SCRIPT_PATH}."
echo
echo "Полезные команды:"
echo "  systemctl status reboot-notify.timer"
echo "  journalctl -u reboot-notify.service -n 50 --no-pager"
echo "  sudoedit /etc/telegram-notify           # изменить токен/чат"
echo "  sudoedit /etc/systemd/system/reboot-notify.timer  # изменить график (OnCalendar)"
echo "  systemctl daemon-reload && systemctl restart reboot-notify.timer"
