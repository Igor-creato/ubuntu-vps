#!/usr/bin/env bash
set -e

BASE_DIR="/opt"
declare -A REPOS=(
    [traefik]="https://github.com/traefik/traefik.git"
    [supabase]="https://github.com/supabase/supabase.git"
    [n8n]="https://github.com/n8n-io/n8n.git"
    [website]="https://github.com/example/your-website-starter.git"   # поменяйте на свой
)

SERVICES=("traefik" "supabase" "n8n" "website")

# 1. Домен
read -rp "Введите ваш домен (например, example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "❌  Домен не может быть пустым."; exit 1; }
export DOMAIN

# 2. Выбор сервисов
CHOICES=()
for i in "${!SERVICES[@]}"; do CHOICES+=("false"); done

select_services() {
    for i in "${!SERVICES[@]}"; do
        local c=$([ "${CHOICES[$i]}" == "true" ] && echo "[x]" || echo "[ ]")
        echo "$((i+1))) $c ${SERVICES[$i]}"
    done
}

while true; do
    select_services
    read -rp "Выберите пункт (1-${#SERVICES[@]}), 'd' — далее: " REPLY
    [[ "$REPLY" == "d" ]] && break
    [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#SERVICES[@]} )) || continue
    idx=$((REPLY-1))
    CHOICES[$idx]=$([ "${CHOICES[$idx]}" == "true" ] && echo "false" || echo "true")
done

SELECTED=()
for i in "${!SERVICES[@]}"; do [[ "${CHOICES[$i]}" == "true" ]] && SELECTED+=("${SERVICES[$i]}"); done
[[ ${#SELECTED[@]} -eq 0 ]] && { echo "❌  Ничего не выбрано."; exit 0; }

# 3. Создаём папки и клонируем репозитории
for SERVICE in "${SELECTED[@]}"; do
    DIR="$BASE_DIR/$SERVICE"
    mkdir -p "$DIR"
    if [[ -z "$(ls -A "$DIR")" ]]; then
        echo "▶️  Клонируем ${REPOS[$SERVICE]} в $DIR ..."
        git clone "${REPOS[$SERVICE]}" "$DIR"
    else
        echo "⚠️  Папка $DIR не пуста — пропускаем клонирование."
    fi
done

# 4. Общая сеть
docker network create proxy 2>/dev/null || true

# 5. Запуск в правильном порядке
declare -A ORDER=( [traefik]=1 [supabase]=2 [n8n]=3 [website]=4 )
IFS=$'\n' SELECTED=($(printf '%s\n' "${SELECTED[@]}" | sort -n -k1,1 <(printf '%s\n' "${!ORDER[@]}" | sort -k2,2)))
unset IFS

for SERVICE in "${SELECTED[@]}"; do
    COMPOSE_FILE="$BASE_DIR/$SERVICE/docker-compose.yml"
    ENV_FILE="$BASE_DIR/$SERVICE/.env"

    [[ ! -f "$COMPOSE_FILE" ]] && { echo "❌  $COMPOSE_FILE не найден, пропускаем $SERVICE"; continue; }

    echo "▶️  Запуск $SERVICE ..."
    [[ -f "$ENV_FILE" ]] && sed -i "s|^DOMAIN=.*|DOMAIN=$DOMAIN|g" "$ENV_FILE"

    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans
done

echo "✅  Всё готово!"
