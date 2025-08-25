#!/bin/bash
set -euo pipefail

SSH_SCRIPT_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/ssh-setup.sh"
DOCKER_SCRIPT_URL="https://raw.githubusercontent.com/Igor-creato/docker-install/main/install-docker.sh"

echo "=== Запуск установки SSH ==="
bash <(curl -fsSL "$SSH_SCRIPT_URL")

echo "=== Запуск установки Docker ==="
bash <(curl -fsSL "$DOCKER_SCRIPT_URL")

echo "✅ Все скрипты выполнены успешно"
