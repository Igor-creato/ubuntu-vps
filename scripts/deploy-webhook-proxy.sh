#!/bin/bash
set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           УСТАНОВКА WEBHOOK PROXY ДЛЯ N8N + REDIS             ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Параметры по умолчанию
PROJECT_DIR="$HOME/webhook-proxy"
EXTERNAL_NETWORK="proxy"
DEFAULT_DOMAIN="webhook-proxy.autmatization-bot.ru"

# Запрос URL вебхука n8n
echo -e "${BLUE}Введите URL вебхука n8n для проксирования:${NC}"
echo -e "${YELLOW}Пример: https://hook.autmatization-bot.ru/webhook-test/14c9dd84-9c66-46d6-9961-14470a01bcd1${NC}"
echo -n "URL: "
read N8N_WEBHOOK_URL

# Проверка что URL введен
if [ -z "$N8N_WEBHOOK_URL" ]; then
    echo -e "${RED}✗ Ошибка: URL не может быть пустым!${NC}"
    exit 1
fi

# Проверка формата URL
if [[ ! "$N8N_WEBHOOK_URL" =~ ^https?:// ]]; then
    echo -e "${RED}✗ Ошибка: URL должен начинаться с http:// или https://${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Введите домен для webhook-proxy (Enter для значения по умолчанию):${NC}"
echo -e "${YELLOW}По умолчанию: ${DEFAULT_DOMAIN}${NC}"
echo -n "Домен: "
read DOMAIN

# Использовать значение по умолчанию если не введено
if [ -z "$DOMAIN" ]; then
    DOMAIN="$DEFAULT_DOMAIN"
fi

echo ""
echo -e "${YELLOW}Генерация секретного ключа...${NC}"
WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32 | tr -d "=+/" | cut -c1-43)

echo ""
echo -e "${GREEN}Конфигурация:${NC}"
echo -e "  ${YELLOW}Целевой n8n webhook:${NC} $N8N_WEBHOOK_URL"
echo -e "  ${YELLOW}Домен прокси:${NC} $DOMAIN"
echo -e "  ${YELLOW}Директория проекта:${NC} $PROJECT_DIR"
echo -e "  ${YELLOW}Сеть Docker:${NC} $EXTERNAL_NETWORK"
echo ""
echo -n -e "${BLUE}Продолжить установку? (y/n): ${NC}"
read CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Установка отменена${NC}"
    exit 0
fi

echo ""
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
from datetime import datetime

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
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    # Проверка секрета в URL
    if secret != WEBHOOK_SECRET:
        app.logger.warning(f"[{timestamp}] Invalid secret attempt: {secret}")
        abort(403, 'Invalid secret')
    
    # Опционально: проверка HMAC подписи в заголовке
    signature = request.headers.get('X-Webhook-Signature')
    if signature:
        if not verify_signature(request.get_data(), signature):
            app.logger.warning(f"[{timestamp}] Invalid HMAC signature")
            abort(401, 'Invalid signature')
    
    try:
        if request.method == 'GET':
            # Преобразовать GET в POST (query параметры -> JSON body)
            data = request.args.to_dict()
            app.logger.info(f"[{timestamp}] Converting GET to POST with {len(data)} parameters")
            app.logger.debug(f"[{timestamp}] GET data: {data}")
            
            headers = {'Content-Type': 'application/json'}
            response = requests.post(N8N_WEBHOOK_URL, json=data, headers=headers, timeout=30)
            
            app.logger.info(f"[{timestamp}] Forwarded GET->POST to n8n. Response: {response.status_code}")
            return (response.text, response.status_code, response.headers.items())
        else:
            # Переслать POST как есть
            content_type = request.headers.get('Content-Type', '')
            app.logger.info(f"[{timestamp}] Forwarding POST request. Content-Type: {content_type}")
            
            if 'application/json' in content_type:
                json_data = request.get_json(silent=True)
                app.logger.debug(f"[{timestamp}] POST JSON data: {json_data}")
                resp = requests.post(
                    N8N_WEBHOOK_URL,
                    json=json_data,
                    headers={k:v for k,v in request.headers if k.lower() not in ['host', 'content-length']},
                    timeout=30
                )
            else:
                raw_data = request.get_data()
                app.logger.debug(f"[{timestamp}] POST raw data length: {len(raw_data)} bytes")
                resp = requests.post(
                    N8N_WEBHOOK_URL,
                    data=raw_data,
                    headers={k:v for k,v in request.headers if k.lower() not in ['host', 'content-length']},
                    timeout=30
                )
            
            app.logger.info(f"[{timestamp}] Forwarded POST to n8n. Response: {resp.status_code}")
            return (resp.text, resp.status_code, resp.headers.items())
            
    except requests.exceptions.Timeout:
        app.logger.error(f"[{timestamp}] Timeout forwarding webhook to n8n")
        abort(504, 'Gateway timeout: n8n did not respond in time')
    except requests.exceptions.ConnectionError as e:
        app.logger.error(f"[{timestamp}] Connection error forwarding webhook: {str(e)}")
        abort(502, 'Bad gateway: could not connect to n8n')
    except Exception as e:
        app.logger.error(f"[{timestamp}] Error forwarding webhook: {str(e)}")
        abort(500, f'Internal server error: {str(e)}')

@app.route('/health')
def health():
    return jsonify({
        "status": "ok", 
        "service": "webhook-proxy",
        "target": N8N_WEBHOOK_URL,
        "timestamp": datetime.now().isoformat()
    }), 200

if __name__ == "__main__":
    app.logger.info(f"Starting webhook-proxy. Target: {N8N_WEBHOOK_URL}")
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
    echo -e "${RED}✗ Сеть '$EXTERNAL_NETWORK' не найдена!${NC}"
    echo -e "${YELLOW}Убедитесь, что сеть создана (обычно создается Traefik)${NC}"
    exit 1
fi

# Сборка и запуск
echo ""
echo -e "${YELLOW}Сборка и запуск контейнера...${NC}"
docker-compose up -d --build

# Проверка статуса
echo -e "${YELLOW}Ожидание запуска контейнера...${NC}"
sleep 5

if docker ps --filter "name=webhook-proxy" --format "{{.Status}}" | grep -q "Up"; then
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  ✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ ПАРТНЕРСКИХ СЕРВИСОВ         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}URL для настройки в EPN.bz (Postback URL):${NC}"
    echo -e "${GREEN}https://${DOMAIN}/webhook/${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${YELLOW}Секретный ключ (сохраните в безопасном месте!):${NC}"
    echo -e "${GREEN}${WEBHOOK_SECRET}${NC}"
    echo ""
    echo -e "${YELLOW}Целевой n8n webhook:${NC}"
    echo -e "${GREEN}${N8N_WEBHOOK_URL}${NC}"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                         НАСТРОЙКА EPN.BZ                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "1. Перейдите в настройки интеграции EPN.bz"
    echo -e "2. Найдите поле ${YELLOW}'Postback URL'${NC} или ${YELLOW}'Webhook URL'${NC}"
    echo -e "3. Вставьте скопированный URL выше"
    echo -e "4. Сохраните настройки"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ПОЛЕЗНЫЕ КОМАНДЫ                             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Просмотр логов (реального времени):${NC}"
    echo -e "  docker logs -f webhook-proxy"
    echo ""
    echo -e "${YELLOW}Просмотр последних 100 строк логов:${NC}"
    echo -e "  docker logs --tail 100 webhook-proxy"
    echo ""
    echo -e "${YELLOW}Перезапуск контейнера:${NC}"
    echo -e "  cd ${PROJECT_DIR} && docker-compose restart"
    echo ""
    echo -e "${YELLOW}Остановка контейнера:${NC}"
    echo -e "  cd ${PROJECT_DIR} && docker-compose down"
    echo ""
    echo -e "${YELLOW}Обновление (пересборка):${NC}"
    echo -e "  cd ${PROJECT_DIR} && docker-compose up -d --build"
    echo ""
    echo -e "${YELLOW}Проверка работоспособности (health check):${NC}"
    echo -e "  curl https://${DOMAIN}/health"
    echo ""
    echo -e "${YELLOW}Тестовый GET запрос:${NC}"
    echo -e "  curl 'https://${DOMAIN}/webhook/${WEBHOOK_SECRET}?test=123&order_id=456'"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                     МОНИТОРИНГ И ОТЛАДКА                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Статус контейнера:${NC}"
    docker ps --filter "name=webhook-proxy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                  ✗ ОШИБКА ЗАПУСКА КОНТЕЙНЕРА                    ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Логи контейнера:${NC}"
    docker-compose logs --tail 50
    exit 1
fi

# Сохранение конфигурации в файл
cat > webhook-info.txt << EOF
═══════════════════════════════════════════════════════════════
              WEBHOOK PROXY CONFIGURATION
═══════════════════════════════════════════════════════════════

Дата установки: $(date '+%Y-%m-%d %H:%M:%S %Z')

POSTBACK URL ДЛЯ EPN.BZ:
https://${DOMAIN}/webhook/${WEBHOOK_SECRET}

СЕКРЕТНЫЙ КЛЮЧ:
${WEBHOOK_SECRET}

КОНФИГУРАЦИЯ:
- Домен прокси: ${DOMAIN}
- Целевой n8n webhook: ${N8N_WEBHOOK_URL}
- Директория проекта: ${PROJECT_DIR}
- Сеть Docker: ${EXTERNAL_NETWORK}

КОМАНДЫ УПРАВЛЕНИЯ:
- Логи: docker logs -f webhook-proxy
- Перезапуск: cd ${PROJECT_DIR} && docker-compose restart
- Остановка: cd ${PROJECT_DIR} && docker-compose down
- Health check: curl https://${DOMAIN}/health

ТЕСТИРОВАНИЕ:
curl 'https://${DOMAIN}/webhook/${WEBHOOK_SECRET}?test=123'

═══════════════════════════════════════════════════════════════
EOF

echo -e "${GREEN}✓ Конфигурация сохранена в: ${PROJECT_DIR}/webhook-info.txt${NC}"
echo ""
