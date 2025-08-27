#!/usr/bin/env bash
set -euo pipefail

# === Функция: найти последнего добавленного обычного пользователя ===
get_last_user() {
    # UID ≥ 1000, не nobody, shell = /bin/bash, выбираем последнего
    getent passwd \
        | awk -F: '$3>=1000 && $3<65534 && $1!="nobody" && $7=="/bin/bash" {print $1}' \
        | tail -n 1
}

echo "[INFO] Устанавливаю Docker и Docker Compose..."

# === Установка Docker Engine ===
echo "[INFO] Обновляю список пакетов..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

echo "[INFO] Добавляю официальный GPG ключ Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "[INFO] Добавляю репозиторий Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[INFO] Устанавливаю Docker Engine..."
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# === Установка Docker Compose (последний релиз с GitHub) ===
echo "[INFO] Скачиваю последнюю версию Docker Compose..."
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
                   | grep '"tag_name":' \
                   | sed -E 's/.*"v?([^"]+)".*/\1/')
sudo curl -L "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# === Добавляем последнего созданного пользователя в группу docker ===
TARGET_USER="$(get_last_user)"
if [[ -n "$TARGET_USER" ]]; then
    if ! groups "$TARGET_USER" | grep -qw docker; then
        echo "[INFO] Добавляю пользователя $TARGET_USER в группу docker..."
        sudo usermod -aG docker "$TARGET_USER"
        echo "[WARN] Чтобы изменения вступили в силу, выполните: newgrp docker или перезайдите в систему."
    else
        echo "[INFO] Пользователь $TARGET_USER уже состоит в группе docker."
    fi
else
    echo "[WARN] Не удалось определить последнего добавленного пользователя. Пропускаю добавление в группу docker."
fi

# === Проверка установки ===
echo "[INFO] Проверяю версии..."
docker --version
docker-compose --version

echo "[INFO] Установка завершена успешно!"
