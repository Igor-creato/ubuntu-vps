#!/bin/bash
set -euo pipefail

SSH_SCRIPT_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/ssh-setup.sh"
CHAT_ID_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/chat-id.sh"
AUTO_UPDATE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/auto_udate_ubuntu.sh"
DOCKER_SCRIPT_URL="https://raw.githubusercontent.com/Igor-creato/docker-install/main/install-docker.sh"

# парсим аргументы
INSTALL_SSH=false
CHAT_ID=false
AUTO_UPDATE=false
INSTALL_DOCKER=false

for arg in "$@"; do
    case "$arg" in
        --ssh) INSTALL_SSH=true ;;
        --chat) CHAT_ID=true ;;
        --update) AUTO_UPDATE=true ;;
        --docker) INSTALL_DOCKER=true ;;
        *) echo "Неизвестный флаг: $arg"; exit 1 ;;
    esac
done

# если флагов нет — ставим всё
if [[ "$#" -eq 0 ]]; then
    INSTALL_SSH=true
    CHAT_ID=true
    AUTO_UPDATE=true
    INSTALL_DOCKER=true
fi

# последовательно запускаем
if [[ "$INSTALL_SSH" == true ]]; then
    echo "=== Установка SSH ==="
    bash <(curl -fsSL "$SSH_SCRIPT_URL")
fi

if [[ "$CHAT_ID" == true ]]; then
    echo "=== Ваш chatid ==="
    bash <(curl -fsSL "$CHAT_ID_URL")
fi

if [[ "$AUTO_UPDATE" == true ]]; then
    echo "=== Включение автообновлений ==="
    bash <(curl -fsSL "$AUTO_UPDATE_URL")
fi

if [[ "$INSTALL_DOCKER" == true ]]; then
    echo "=== Установка Docker ==="
    bash <(curl -fsSL "$DOCKER_SCRIPT_URL")
fi

echo "✅ Готово"

