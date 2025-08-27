#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BASE_DIR="$HOME/traefik"
ENV_FILE="$BASE_DIR/.env"
SECRETS_DIR="$BASE_DIR/secrets"

# Создаём директории
mkdir -p "$BASE_DIR"/{secrets,logs}

# Проверяем права на запись
if [[ ! -w "$BASE_DIR" ]]; then
    echo "Ошибка: Нет прав на запись в каталог $BASE_DIR"
    exit 1
fi

# ------------------------------------------------------------------
# 1. Загружаем переменные, если файл уже существует
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    echo -e "${YELLOW}Используем существующие данные из .env${NC}"
else
    echo -e "${YELLOW}Файл .env не найден. Инициализируем конфигурацию.${NC}"
fi

# ------------------------------------------------------------------
# 2. Если переменные не заданы — запрашиваем у пользователя
if [[ -z "${ACME_EMAIL:-}" ]] || [[ -z "${TRAEFIK_DOMAIN:-}" ]]; then
    echo -e "${YELLOW}Заполняем обязательные параметры.${NC}"

    # Запрашиваем email с проверкой
    read -rp "E-mail для Let's Encrypt: " ACME_EMAIL_INPUT
    while [[ -z "${ACME_EMAIL_INPUT:-}" ]] && [[ -z "${ACME_EMAIL:-}" ]]; do
        echo -e "${YELLOW}E-mail обязателен для получения сертификатов!${NC}"
        read -rp "E-mail для Let's Encrypt: " ACME_EMAIL_INPUT
    done

    # Запрашиваем домен с проверкой
    read -rp "Домен для дашборда Traefik: " TRAEFIK_DOMAIN_INPUT
    while [[ -z "${TRAEFIK_DOMAIN_INPUT:-}" ]] && [[ -z "${TRAEFIK_DOMAIN:-}" ]]; do
        echo -e "${YELLOW}Домен обязателен!${NC}"
        read -rp "Домен для дашборда Traefik: " TRAEFIK_DOMAIN_INPUT
    done

    # Применяем значения: приоритет — введённые, иначе старые
    ACME_EMAIL="${ACME_EMAIL_INPUT:-$ACME_EMAIL}"
    TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN_INPUT:-$TRAEFIK_DOMAIN}"

    # Генерируем учётные данные
    BASIC_AUTH_USER="admin"
    BASIC_AUTH_PASS=$(openssl rand -base64 16)
    echo -e "${GREEN}Сгенерированный пароль для ${BASIC_AUTH_USER}: ${BASIC_AUTH_PASS}${NC}"

    # Записываем .env (heredoc с поддержкой отступов через <<-EOF)
    cat > "$ENV_FILE" <<-EOF
ACME_EMAIL=$ACME_EMAIL
TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN
BASIC_AUTH_USER=$BASIC_AUTH_USER
BASIC_AUTH_PASS=$BASIC_AUTH_PASS
EOF

    echo -e "${GREEN}.env файл успешно создан.${NC}"
else
    # Убедимся, что BASIC_AUTH_PASS существует
    if [[ -z "${BASIC_AUTH_USER:-}" ]] || [[ -z "${BASIC_AUTH_PASS:-}" ]]; then
        echo "Ошибка: BASIC_AUTH_USER или BASIC_AUTH_PASS отсутствуют в .env"
        exit 1
    fi
    echo -e "${YELLOW}Используем существующие данные из .env${NC}"
fi

# ------------------------------------------------------------------
# 3. Создаём внешнюю сеть, если её нет
if ! docker network inspect traefik-public >/dev/null 2>&1; then
    echo -e "${YELLOW}Создаём сеть traefik-public...${NC}"
    docker network create traefik-public
else
    echo -e "${GREEN}Сеть traefik-public уже существует.${NC}"
fi

# ------------------------------------------------------------------
# 4. Скачиваем/обновляем конфигурационные файлы
COMPOSE_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/docker-compose.yml"
TRAEFIK_YML_URL="https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/traefik.yml"

echo -e "${YELLOW}Скачиваем конфигурационные файлы...${NC}"

if ! curl -sSL --fail "$COMPOSE_URL" -o "$BASE_DIR/docker-compose.yml"; then
    echo -e "${YELLOW}Ошибка: Не удалось скачать docker-compose.yml${NC}"
    exit 1
fi

if ! curl -sSL --fail "$TRAEFIK_YML_URL" -o "$BASE_DIR/traefik.yml"; then
    echo -e "${YELLOW}Ошибка: Не удалось скачать traefik.yml${NC}"
    exit 1
fi

echo -e "${GREEN}Конфигурационные файлы успешно обновлены.${NC}"

# ------------------------------------------------------------------
# ------------------------------------------------------------------
# 5. Проверка .env и создание/обновление dashboard.htpasswd
echo -e "${YELLOW}Проверяем конфигурацию для Basic Auth...${NC}"

# Проверяем, что переменные заданы
if [[ -z "${BASIC_AUTH_USER:-}" ]] || [[ -z "${BASIC_AUTH_PASS:-}" ]]; then
    echo -e "${RED}Ошибка: BASIC_AUTH_USER или BASIC_AUTH_PASS не заданы в .env${NC}"
    exit 1
fi

HTPASSWD_FILE="$SECRETS_DIR/dashboard.htpasswd"

# Если файл существует — спрашиваем, пересоздать ли
if [[ -f "$HTPASSWD_FILE" ]]; then
    echo -e "${YELLOW}Файл $HTPASSWD_FILE уже существует.${NC}"
    read -rp "Пересоздать его? [y/N]: " RECREATE_HTPASSWD
    if [[ ! "$RECREATE_HTPASSWD" =~ ^[yY](es|es)?$ ]]; then
        echo -e "${GREEN}Оставлен существующий файл htpasswd.${NC}"
    else
        echo -e "${YELLOW}Создаём новый файл htpasswd...${NC}"
        docker run --rm -v "$SECRETS_DIR:/out" \
          httpd:alpine \
          htpasswd -nbB "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" > "$HTPASSWD_FILE"
        echo -e "${GREEN}Новый файл $HTPASSWD_FILE успешно создан.${NC}"
    fi
else
    echo -e "${YELLOW}Создаём новый файл $HTPASSWD_FILE...${NC}"
    docker run --rm -v "$SECRETS_DIR:/out" \
      httpd:alpine \
      htpasswd -nbB "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASS}" > "$HTPASSWD_FILE"
    echo -e "${GREEN}Файл $HTPASSWD_FILE успешно создан.${NC}"
fi

# Финальная проверка: убедимся, что файл содержит логин и хэш
if [[ -f "$HTPASSWD_FILE" ]]; then
    if ! grep -q "^${BASIC_AUTH_USER}:" "$HTPASSWD_FILE"; then
        echo -e "${RED}Ошибка: Файл $HTPASSWD_FILE не содержит логин ${BASIC_AUTH_USER}!${NC}"
        echo -e "${RED}Возможно, произошла ошибка при генерации.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Ошибка: Файл $HTPASSWD_FILE не был создан!${NC}"
    exit 1
fi
chmod 600 "$HTPASSWD_FILE"
# ------------------------------------------------------------------
# 6. Запуск / перезапуск Traefik
cd "$BASE_DIR"
echo -e "${YELLOW}Обновляем и запускаем контейнеры...${NC}"

docker compose pull
docker compose up -d

# ------------------------------------------------------------------
# 7. Финальное сообщение
echo -e "${GREEN}"
echo "========================================"
echo "Traefik успешно запущен!"
echo "Дашборд: https://$TRAEFIK_DOMAIN"
echo "Логин: $BASIC_AUTH_USER"
echo "Пароль: $BASIC_AUTH_PASS"
echo "========================================"
echo -e "${NC}"
