#!/usr/bin/env bash
set -euo pipefail

# --- Проверки окружения ---
if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root (sudo -i или sudo ./script.sh)." >&2
  exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
  echo "OpenSSH не установлен. Установите: apt update && apt install -y openssh-server" >&2
  exit 1
fi

# --- Ввод параметров ---
read -rp "Укажите имя нового пользователя (например, deploy): " NEW_USER
if [[ -z "$NEW_USER" ]]; then
  echo "Имя пользователя не может быть пустым." >&2
  exit 1
fi

# Сначала проверяем, есть ли у root ключи
ROOT_AUTH_KEYS_FILE="/root/.ssh/authorized_keys"
ROOT_KEYS_FOUND=0
ROOT_KEYS_CONTENT=""
if [[ -s "$ROOT_AUTH_KEYS_FILE" ]]; then
  ROOT_KEYS_CONTENT="$(cat "$ROOT_AUTH_KEYS_FILE")"
  ROOT_KEYS_FOUND=1
  echo "Найдены SSH-ключи у root — будут перенесены пользователю ${NEW_USER}."
else
  # Если у root нет ключей, только тогда спрашиваем ключ для нового пользователя
  read -rp "Вставьте публичный SSH-ключ для пользователя ${NEW_USER} (одной строкой): " PUBKEY
  if [[ -z "$PUBKEY" ]]; then
    echo "Публичный ключ не может быть пустым." >&2
    exit 1
  fi
fi

# Запрос порта и валидация
while true; do
  read -rp "Введите новый порт SSH (1-65535, не 22): " SSH_PORT
  if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) && [[ "$SSH_PORT" != "22" ]]; then
    break
  fi
  echo "Некорректный порт. Повторите ввод."
done

# --- Создание пользователя и настройка ключа ---
if id "$NEW_USER" >/dev/null 2>&1; then
  echo "Пользователь ${NEW_USER} уже существует — пропускаю создание."
else
  adduser --disabled-password --gecos "" "$NEW_USER"
  echo "Пользователь ${NEW_USER} создан."
fi

# Добавить в sudo
usermod -aG sudo "$NEW_USER"
echo "Пользователь ${NEW_USER} добавлен в группу sudo."

# Настроить SSH ключи
USER_HOME="$(eval echo ~${NEW_USER})"
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "${USER_HOME}/.ssh"

if [[ "$ROOT_KEYS_FOUND" -eq 1 ]]; then
  # Переносим ключи root
  printf "%s\n" "$ROOT_KEYS_CONTENT" > "${USER_HOME}/.ssh/authorized_keys"
  echo "Перенесены ключи из ${ROOT_AUTH_KEYS_FILE} в ${USER_HOME}/.ssh/authorized_keys."
else
  # Используем введённый пользователем ключ
  printf "%s\n" "$PUBKEY" > "${USER_HOME}/.ssh/authorized_keys"
  echo "Ключ добавлен в ${USER_HOME}/.ssh/authorized_keys."
fi

chown "$NEW_USER:$NEW_USER" "${USER_HOME}/.ssh/authorized_keys"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"

# --- Резервная копия и drop-in конфиг SSH ---
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROP_DIR="/etc/ssh/sshd_config.d"
SSHD_DROP_FILE="${SSHD_DROP_DIR}/99-hardening.conf"

if [[ -f "$SSHD_MAIN" && ! -f "${SSHD_MAIN}.bak" ]]; then
  cp -a "$SSHD_MAIN" "${SSHD_MAIN}.bak"
  echo "Создана резервная копия ${SSHD_MAIN}.bak"
fi

mkdir -p "$SSHD_DROP_DIR"

cat > "$SSHD_DROP_FILE" <<EOF
# Настроено secure_ssh_setup.sh
Port ${SSH_PORT}
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
# (Необязательно) Можно ограничить вход конкретным пользователем:
# AllowUsers ${NEW_USER}
EOF

chmod 644 "$SSHD_DROP_FILE"
echo "Записан drop-in конфиг: ${SSHD_DROP_FILE}"

# --- Удаляем SSH-ключи у root (если были) ---
if [[ -f "$ROOT_AUTH_KEYS_FILE" ]]; then
  rm -f "$ROOT_AUTH_KEYS_FILE"
  echo "Удалён ${ROOT_AUTH_KEYS_FILE}."
fi

# --- Брандмауэр (UFW), если активен ---
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -n1 || true)
  if echo "$UFW_STATUS" | grep -qi "active"; then
    echo "UFW активен — настраиваю правила."
    ufw allow "${SSH_PORT}/tcp" || true
    UFW_WAS_ACTIVE=1
  else
    UFW_WAS_ACTIVE=0
  fi
else
  UFW_WAS_ACTIVE=0
fi

# --- Проверка синтаксиса и перезапуск SSH ---
if sshd -t; then
  systemctl restart ssh || systemctl restart sshd
  echo "Сервис SSH перезапущен."
else
  echo "Ошибка проверки конфигурации sshd. Откатываю изменения."
  mv -f "${SSHD_DROP_FILE}" "${SSHD_DROP_FILE}.bad.$(date +%s)"
  exit 1
fi

# Теперь можно удалить старое правило 22/tcp, если UFW активен
if [[ "${UFW_WAS_ACTIVE}" -eq 1 ]]; then
  ufw delete allow 22/tcp || true
  echo "Из UFW удалено правило для порта 22/tcp."
fi

# --- Итоговая информация ---
echo
echo "Готово! Итоги:"
echo " • Пользователь:        ${NEW_USER} (в группе sudo)"
echo " • SSH-порт:            ${SSH_PORT}"
echo " • SSH вход паролем:    отключён (PasswordAuthentication no)"
echo " • Root вход паролем:   запрещён (PermitRootLogin prohibit-password)"
echo " • Ключ root:           перенесён новому пользователю (если был) и удалён у root"
echo " • Ключ пользователя:   ${USER_HOME}/.ssh/authorized_keys"

echo
echo "Проверьте подключение в НОВОЙ сессии перед разрывом текущей:"
echo "   ssh -p ${SSH_PORT} ${NEW_USER}@<IP-адрес>"
echo
echo "Если sudo запрашивает пароль, задайте его командой:"
echo "   sudo passwd ${NEW_USER}"
