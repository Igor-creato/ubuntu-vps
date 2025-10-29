#!/bin/bash
set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Установка Webhook Proxy для n8n ===${NC}"

# Параметры
PROJECT_DIR="$HOME/webhook-proxy"
WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
N8N_WEBHOOK_URL="https://hook.autmatization-bot.ru/webhook-test/14c9dd84-9c66-46d6-9961-14470a01bcd1"
EXTERNAL_NETWORK="proxy"
DOMAIN="webhook-proxy.autmatization-bot.ru"

echo -e "${YELLOW}Создание директорий...${NC}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo -e "${YELLOW}Создание Dockerfile...${NC}"
cat > Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

CMD ["python", "app.py"]
EOF

echo -e "${YELLOW}Создание requirements.txt...${NC}"
cat > requirements.txt << 'EOF'
flask==3.0.0
requests==2.31.0
werkzeug==3.0.1
EOF

echo -e "${YELLOW}Создание app.py...${NC}"
cat > app.py << 'EOF'
import os
import hmac
import hashlib
from flask import Flask, request, jsonify, abort
import requests

N8N_WEBHOOK_URL = os.environ.get('N8N_WEBHOOK_URL')
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', 'default-secret')

app = Flask(__name__)

def verify_signature(data, signature):
    """Проверка HMAC подписи (опционально для партнеров, поддерживающих HMAC)"""
    if not signature:
        return False
    expected = hmac.new(
        WEBHOOK_SECRET.encode('utf-8'),
        data,
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(signature, expected)

@app.route('/webhook/<secret>', methods=['GET', 'POST'])
def handle_webhook(secret):
    # Проверка секрета в URL
    if secret != WEBHOOK_SECRET:
        app.logger.warning(f"Invalid secret attempt: {secret}")
        abort(403, 'Invalid secret')
    
    # Опционально: проверка HMAC подписи в заголовке
    signature = request.headers.get('X-Webhook-Signature')
    if signature:
        if not verify_signature(request.get_data(), signature):
            app.logger.warning("Invalid HMAC signature")
            abort(401, 'Invalid signature')
    
    try:
        if request.method == 'GET':
            # Преобразовать GET в POST (query параметры -> JSON body)
            data = request.args.to_dict()
            app.logger.info(f"Converting GET to POST: {data}")
            headers = {'Content-Type': 'application/json'}
            response = requests.post(N8N_WEBHOOK_URL, json=data, headers=headers, timeout=30)
            return (response.text, response.status_code, response.headers.items())
        else:
            # Переслать POST как есть
            app.logger.info(f"Forwarding POST request to n8n")
            content_type = request.headers.get('Content-Type', '')
            
            if 'application/json' in content_type:
                resp = requests.post(
                    N8N_WEBHOOK_URL,
                    json=request.get_json(silent=True),
                    headers={k:v for k,v in request.headers if k.lower() not in ['host', 'content-length']},
                    timeout=30
                )
            else:
                resp = requests.post(
                    N8N_WEBHOOK_URL,
                    data=request.get_data(),
                    headers={k:v for k,v in request.headers if k.lower() not in ['host', 'content-length']},
                    timeout=30
                )
            return (resp.text, resp.status_code, resp.headers.items())
    except Exception as e:
        app.logger.error(f"Error forwarding webhook: {str(e)}")
        abort(500, f'Error forwarding webhook: {str(e)}')

@app.route('/health')
def health():
    return jsonify({"status": "ok", "service": "webhook-proxy"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
EOF

echo -e "${YELLOW}Создание docker-compose.yml...${NC}"
cat > docker-compose.yml << EOF
version: '3.8'

services:
  webhook-proxy:
    build: .
    container_name: webhook-proxy
    restart: unless-stopped
    environment:
      - N8N_WEBHOOK_URL=${N8N_WEBHOOK_URL}
      - WEBHOOK_SECRET=${WEBHOOK_SECRET}
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.webhook-proxy.rule=Host(\`${DOMAIN}\`)"
      - "traefik.http.routers.webhook-proxy.entrypoints=websecure"
      - "traefik.http.routers.webhook-proxy.tls.certresolver=letsencrypt"
      - "traefik.http.services.webhook-proxy.loadbalancer.server.port=5000"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  proxy:
    external: true
    name: proxy
EOF

echo -e "${YELLOW}Создание .env файла...${NC}"
cat > .env << EOF
N8N_WEBHOOK_URL=${N8N_WEBHOOK_URL}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
DOMAIN=${DOMAIN}
EOF

# Проверка существования сети
echo -e "${YELLOW}Проверка сети Docker 'proxy'...${NC}"
if ! docker network inspect "$EXTERNAL_NETWORK" &> /dev/null; then
    echo -e "${YELLOW}⚠ Сеть '$EXTERNAL_NETWORK' не найдена!${NC}"
    echo -e "${YELLOW}Убедитесь, что сеть создана (обычно создается Traefik)${NC}"
    exit 1
fi

# Сборка и запуск
echo -e "${YELLOW}Сборка и запуск контейнера...${NC}"
docker-compose up -d --build

# Проверка статуса
sleep 3
if docker ps --filter "name=webhook-proxy" --format "{{.Status}}" | grep -q "Up"; then
    echo -e "${GREEN}✓ Webhook Proxy успешно запущен!${NC}"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ ПАРТНЕРСКИХ СЕРВИСОВ         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Webhook URL для EPN.bz и других партнеров:${NC}"
    echo -e "${GREEN}https://${DOMAIN}/webhook/${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${YELLOW}Секретный ключ (сохраните в безопасном месте):${NC}"
    echo -e "${GREEN}${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${YELLOW}Домен прокси:${NC} ${DOMAIN}"
    echo -e "${YELLOW}Целевой n8n webhook:${NC} ${N8N_WEBHOOK_URL}"
    echo -e "${YELLOW}Сеть Docker:${NC} proxy"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ПОЛЕЗНЫЕ КОМАНДЫ                             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Просмотр логов:${NC}"
    echo "  docker logs -f webhook-proxy"
    echo ""
    echo -e "${YELLOW}Перезапуск:${NC}"
    echo "  cd $PROJECT_DIR && docker-compose restart"
    echo ""
    echo -e "${YELLOW}Остановка:${NC}"
    echo "  cd $PROJECT_DIR && docker-compose down"
    echo ""
    echo -e "${YELLOW}Тест работы (health check):${NC}"
    echo "  curl https://${DOMAIN}/health"
    echo ""
else
    echo -e "${YELLOW}⚠ Ошибка запуска. Проверьте логи:${NC}"
    docker-compose logs
    exit 1
fi

# Сохранение конфигурации в файл
cat > webhook-info.txt << EOF
=== WEBHOOK PROXY CONFIGURATION ===
Дата установки: $(date)

Webhook URL: https://${DOMAIN}/webhook/${WEBHOOK_SECRET}
Секретный ключ: ${WEBHOOK_SECRET}
Домен: ${DOMAIN}
Целевой n8n webhook: ${N8N_WEBHOOK_URL}
Проект директория: ${PROJECT_DIR}

Команды управления:
- Логи: docker logs -f webhook-proxy
- Перезапуск: cd ${PROJECT_DIR} && docker-compose restart
- Остановка: cd ${PROJECT_DIR} && docker-compose down
EOF

echo -e "${GREEN}✓ Конфигурация сохранена в: ${PROJECT_DIR}/webhook-info.txt${NC}"
