#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Установка Svix Webhook Service ===${NC}"

# Проверка что мы в правильной директории
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Не запускайте скрипт от root!${NC}"
    exit 1
fi

# Проверка Docker и Docker Compose
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker не установлен!${NC}"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}Docker Compose не установлен!${NC}"
    exit 1
fi

# Создание директории
echo -e "${YELLOW}Создание папки svix...${NC}"
mkdir -p svix && cd svix

# Запрос параметров
echo -e "${BLUE}Настройка параметров:${NC}"

read -p "Введите домен для веб-интерфейса (например svix.yourdomain.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Домен обязателен!${NC}"
    exit 1
fi

read -p "Введите название таблицы для webhook данных [webhook_events]: " TABLE_NAME
TABLE_NAME=${TABLE_NAME:-webhook_events}

read -p "Введите логин MariaDB: " DB_USER
if [ -z "$DB_USER" ]; then
    echo -e "${RED}Логин обязателен!${NC}"
    exit 1
fi

read -s -p "Введите пароль MariaDB: " DB_PASSWORD
echo
if [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Пароль обязателен!${NC}"
    exit 1
fi

read -p "Введите название базы данных [wordpress]: " DB_NAME
DB_NAME=${DB_NAME:-wordpress}

read -p "Введите URL для приема хуков [/webhook]: " WEBHOOK_URL
WEBHOOK_URL=${WEBHOOK_URL:-/webhook}

# Генерация секрета
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo -e "${GREEN}Сгенерирован секрет: $WEBHOOK_SECRET${NC}"

# Создание структуры проекта
echo -e "${YELLOW}Создание файлов проекта...${NC}"

# .env файл
cat > .env << EOF
# Database Configuration
DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@mariadb:3306/${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
TABLE_NAME=${TABLE_NAME}

# Webhook Configuration
WEBHOOK_SECRET=${WEBHOOK_SECRET}
WEBHOOK_URL=${WEBHOOK_URL}
DOMAIN=${DOMAIN}

# Svix Configuration
SVIX_DB_DSN=postgresql://svix:svix_password@svix_postgres:5432/svix
SVIX_REDIS_DSN=redis://svix_redis:6379
SVIX_JWT_SECRET=$(openssl rand -base64 32)

# FastAPI Configuration
FASTAPI_HOST=0.0.0.0
FASTAPI_PORT=8000
EOF

echo -e "${GREEN}Файл .env создан${NC}"

# Docker Compose файл
cat > docker-compose.yml << 'EOF'
version: '3.8'

networks:
  proxy:
    external: true
  wp-backend:
    external: true
  svix-internal:
    driver: bridge

services:
  # PostgreSQL для Svix
  svix_postgres:
    image: postgres:13-alpine
    environment:
      POSTGRES_DB: svix
      POSTGRES_USER: svix
      POSTGRES_PASSWORD: svix_password
    volumes:
      - svix_postgres_data:/var/lib/postgresql/data
    networks:
      - svix-internal
    restart: unless-stopped

  # Redis для Svix
  svix_redis:
    image: redis:7-alpine
    networks:
      - svix-internal
    restart: unless-stopped

  # Svix Server
  svix_server:
    image: svix/svix-server:latest
    environment:
      SVIX_DB_DSN: postgresql://svix:svix_password@svix_postgres:5432/svix
      SVIX_REDIS_DSN: redis://svix_redis:6379
      SVIX_JWT_SECRET: ${SVIX_JWT_SECRET}
      SVIX_QUEUE_TYPE: redis
    depends_on:
      - svix_postgres
      - svix_redis
    networks:
      - svix-internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.svix.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.svix.tls=true"
      - "traefik.http.routers.svix.tls.certresolver=letsencrypt"
      - "traefik.http.services.svix.loadbalancer.server.port=8071"
      - "traefik.docker.network=proxy"
    restart: unless-stopped

  # FastAPI Webhook Receiver
  webhook_receiver:
    build: ./app
    environment:
      DATABASE_URL: mysql://${DB_USER}:${DB_PASSWORD}@mariadb:3306/${DB_NAME}
      WEBHOOK_SECRET: ${WEBHOOK_SECRET}
      TABLE_NAME: ${TABLE_NAME}
      SVIX_API_URL: http://svix_server:8071
    depends_on:
      - svix_server
    networks:
      - svix-internal
      - wp-backend
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webhook.rule=Host(`webhook.${DOMAIN}`)"
      - "traefik.http.routers.webhook.tls=true"
      - "traefik.http.routers.webhook.tls.certresolver=letsencrypt"
      - "traefik.http.services.webhook.loadbalancer.server.port=8000"
      - "traefik.docker.network=proxy"
    restart: unless-stopped

volumes:
  svix_postgres_data:

EOF

echo -e "${GREEN}Docker Compose файл создан${NC}"

# Создание структуры FastAPI приложения
mkdir -p app/partners

# Dockerfile
cat > app/Dockerfile << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Установка зависимостей системы
RUN apt-get update && apt-get install -y \
    gcc \
    default-libmysqlclient-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Копирование requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копирование кода
COPY . .

# Запуск
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# Requirements.txt
cat > app/requirements.txt << 'EOF'
fastapi==0.104.1
uvicorn[standard]==0.24.0
sqlalchemy==2.0.23
pymysql==1.1.0
cryptography==41.0.7
python-multipart==0.0.6
pydantic==2.5.0
httpx==0.25.2
python-dotenv==1.0.0
alembic==1.12.1
EOF

echo -e "${GREEN}Dockerfile и requirements.txt созданы${NC}"

# Основной файл FastAPI
cat > app/main.py << 'EOF'
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
import os
import logging
from contextlib import asynccontextmanager

from database import init_db
from webhook_processor import WebhookProcessor
from partners.epn_bz import EpnBzPartner

# Настройка логирования
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Инициализация базы данных при старте
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Initializing database...")
    await init_db()
    logger.info("Database initialized")
    yield
    # Shutdown
    logger.info("Shutting down...")

app = FastAPI(
    title="Universal Webhook Service",
    description="Универсальный сервис приема webhook'ов",
    version="1.0.0",
    lifespan=lifespan
)

# Инициализация процессора webhook'ов
webhook_processor = WebhookProcessor()

# Регистрация партнеров
webhook_processor.register_partner("epn_bz", EpnBzPartner())

@app.get("/")
async def root():
    return {"message": "Universal Webhook Service is running"}

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "webhook-receiver"}

@app.post("/webhook/{partner_id}")
async def receive_webhook_post(
    partner_id: str, 
    request: Request, 
    background_tasks: BackgroundTasks
):
    """Прием POST webhook'ов"""
    return await webhook_processor.process_webhook(
        partner_id, request, background_tasks
    )

@app.get("/webhook/{partner_id}")
async def receive_webhook_get(
    partner_id: str, 
    request: Request, 
    background_tasks: BackgroundTasks
):
    """Прием GET webhook'ов"""
    return await webhook_processor.process_webhook(
        partner_id, request, background_tasks
    )

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Global exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error"}
    )
EOF

echo -e "${GREEN}Основной файл FastAPI создан${NC}"

# Базовый класс партнера
cat > app/partners/__init__.py << 'EOF'
"""Пакет для партнеров webhook'ов"""
EOF

cat > app/partners/base_partner.py << 'EOF'
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional
from fastapi import Request
import logging

logger = logging.getLogger(__name__)

class BasePartner(ABC):
    """Базовый класс для всех партнеров"""

    def __init__(self, name: str):
        self.name = name
        logger.info(f"Initialized partner: {name}")

    @abstractmethod
    async def verify_signature(self, request: Request, body: bytes) -> bool:
        """Проверка подписи webhook'а"""
        pass

    @abstractmethod
    async def parse_webhook(self, request: Request, body: bytes) -> Dict[str, Any]:
        """Парсинг данных webhook'а"""
        pass

    @abstractmethod
    async def process_data(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Обработка и нормализация данных"""
        pass

    def get_client_ip(self, request: Request) -> str:
        """Получение IP клиента"""
        x_forwarded_for = request.headers.get("X-Forwarded-For")
        if x_forwarded_for:
            return x_forwarded_for.split(",")[0].strip()
        return request.client.host

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация запроса"""
        return True
EOF

echo -e "${GREEN}Базовый класс партнера создан${NC}"

# Класс партнера EPN.bz
cat > app/partners/epn_bz.py << 'EOF'
import hmac
import hashlib
import json
from typing import Dict, Any
from fastapi import Request, HTTPException
from urllib.parse import parse_qs
import logging

from .base_partner import BasePartner

logger = logging.getLogger(__name__)

class EpnBzPartner(BasePartner):
    """Класс для работы с webhook'ами EPN.bz"""

    def __init__(self):
        super().__init__("EPN.bz")
        # Эти параметры обычно получаются из конфигурации
        self.secret_key = "your_epn_secret_key"  # Замените на реальный ключ

    async def verify_signature(self, request: Request, body: bytes) -> bool:
        """Проверка подписи EPN.bz"""
        try:
            # EPN.bz обычно передает подпись в заголовке
            signature = request.headers.get("X-Signature") or request.headers.get("X-EPN-Signature")

            if not signature:
                logger.warning("No signature found in headers")
                return True  # Временно пропускаем, если нет подписи

            # Вычисляем ожидаемую подпись
            expected_signature = hmac.new(
                self.secret_key.encode('utf-8'),
                body,
                hashlib.sha256
            ).hexdigest()

            # Сравниваем подписи
            return hmac.compare_digest(signature, expected_signature)

        except Exception as e:
            logger.error(f"Error verifying EPN.bz signature: {e}")
            return False

    async def parse_webhook(self, request: Request, body: bytes) -> Dict[str, Any]:
        """Парсинг webhook'а от EPN.bz"""
        try:
            if request.method == "POST":
                content_type = request.headers.get("content-type", "")

                if "application/json" in content_type:
                    # JSON payload
                    data = json.loads(body.decode('utf-8'))
                elif "application/x-www-form-urlencoded" in content_type:
                    # Form data
                    form_data = parse_qs(body.decode('utf-8'))
                    data = {k: v[0] if len(v) == 1 else v for k, v in form_data.items()}
                else:
                    # Попытка парсинга как JSON
                    data = json.loads(body.decode('utf-8'))
            else:
                # GET request - параметры в URL
                data = dict(request.query_params)

            logger.info(f"Parsed EPN.bz data: {data}")
            return data

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON from EPN.bz: {e}")
            raise HTTPException(status_code=400, detail="Invalid JSON")
        except Exception as e:
            logger.error(f"Error parsing EPN.bz webhook: {e}")
            raise HTTPException(status_code=400, detail="Failed to parse webhook")

    async def process_data(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Обработка и нормализация данных EPN.bz"""
        try:
            # Нормализация данных к единому формату
            processed_data = {
                "partner": "epn_bz",
                "event_type": data.get("type", "unknown"),
                "transaction_id": data.get("click_id") or data.get("transaction_id"),
                "order_id": data.get("order_id") or data.get("offer_id"),
                "amount": float(data.get("amount", 0)),
                "commission": float(data.get("commission", 0)),
                "status": data.get("status", "unknown"),
                "currency": data.get("currency", "RUB"),
                "user_id": data.get("user_id"),
                "offer_id": data.get("offer_id"),
                "click_id": data.get("click_id"),
                "raw_data": data,
                "processed_at": None  # Будет установлено в базе данных
            }

            # Дополнительная валидация
            if not processed_data["transaction_id"]:
                logger.warning("No transaction_id found in EPN.bz data")

            logger.info(f"Processed EPN.bz data: {processed_data}")
            return processed_data

        except Exception as e:
            logger.error(f"Error processing EPN.bz data: {e}")
            raise HTTPException(status_code=400, detail="Failed to process data")

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация для EPN.bz"""
        # Можно добавить проверку IP адресов EPN.bz
        client_ip = self.get_client_ip(request)
        logger.info(f"EPN.bz request from IP: {client_ip}")

        # Здесь можно добавить whitelist IP адресов EPN.bz
        # epn_ips = ["1.2.3.4", "5.6.7.8"]
        # return client_ip in epn_ips

        return True
EOF

echo -e "${GREEN}Класс партнера EPN.bz создан${NC}"

# Процессор webhook'ов
cat > app/webhook_processor.py << 'EOF'
import logging
from typing import Dict, Any
from fastapi import Request, HTTPException, BackgroundTasks

from partners.base_partner import BasePartner
from database import save_webhook_event

logger = logging.getLogger(__name__)

class WebhookProcessor:
    """Основной процессор webhook'ов"""

    def __init__(self):
        self.partners: Dict[str, BasePartner] = {}
        logger.info("WebhookProcessor initialized")

    def register_partner(self, partner_id: str, partner: BasePartner):
        """Регистрация нового партнера"""
        self.partners[partner_id] = partner
        logger.info(f"Registered partner: {partner_id}")

    async def process_webhook(
        self, 
        partner_id: str, 
        request: Request, 
        background_tasks: BackgroundTasks
    ):
        """Основная обработка webhook'а"""
        try:
            # Проверка существования партнера
            if partner_id not in self.partners:
                logger.error(f"Unknown partner: {partner_id}")
                raise HTTPException(status_code=404, detail=f"Partner {partner_id} not found")

            partner = self.partners[partner_id]
            logger.info(f"Processing webhook for partner: {partner_id}")

            # Получение тела запроса
            body = await request.body()

            # Валидация запроса
            if not await partner.validate_request(request):
                logger.error(f"Request validation failed for {partner_id}")
                raise HTTPException(status_code=400, detail="Request validation failed")

            # Проверка подписи
            if not await partner.verify_signature(request, body):
                logger.error(f"Signature verification failed for {partner_id}")
                raise HTTPException(status_code=401, detail="Invalid signature")

            # Парсинг данных
            raw_data = await partner.parse_webhook(request, body)

            # Обработка данных
            processed_data = await partner.process_data(raw_data)

            # Асинхронное сохранение в базу данных
            background_tasks.add_task(save_webhook_event, processed_data)

            # Отправка в Svix (можно добавить позже)
            # background_tasks.add_task(send_to_svix, processed_data)

            logger.info(f"Successfully processed webhook for {partner_id}")
            return {
                "status": "success",
                "partner": partner_id,
                "transaction_id": processed_data.get("transaction_id"),
                "message": "Webhook processed successfully"
            }

        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Error processing webhook for {partner_id}: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail="Internal server error")
EOF

echo -e "${GREEN}Процессор webhook'ов создан${NC}"

# Модуль для работы с базой данных
cat > app/database.py << 'EOF'
import os
import logging
from typing import Dict, Any, Optional
import asyncio
import pymysql
from datetime import datetime
import json

logger = logging.getLogger(__name__)

# Настройки подключения к базе данных
DATABASE_URL = os.getenv("DATABASE_URL")
TABLE_NAME = os.getenv("TABLE_NAME", "webhook_events")

def get_db_connection():
    """Получение соединения с MariaDB"""
    try:
        # Парсинг DATABASE_URL
        # mysql://user:password@host:port/database
        if not DATABASE_URL:
            raise ValueError("DATABASE_URL not configured")

        parts = DATABASE_URL.replace("mysql://", "").split("/")
        db_name = parts[1] if len(parts) > 1 else "wordpress"

        auth_host = parts[0].split("@")
        host_port = auth_host[1].split(":")
        host = host_port[0]
        port = int(host_port[1]) if len(host_port) > 1 else 3306

        user_pass = auth_host[0].split(":")
        user = user_pass[0]
        password = user_pass[1]

        connection = pymysql.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            database=db_name,
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True
        )

        return connection

    except Exception as e:
        logger.error(f"Failed to connect to database: {e}")
        return None

async def init_db():
    """Инициализация базы данных"""
    try:
        connection = get_db_connection()
        if not connection:
            logger.error("Failed to connect to database for initialization")
            return

        with connection.cursor() as cursor:
            # Создание таблицы для webhook событий
            create_table_sql = f"""
            CREATE TABLE IF NOT EXISTS `{TABLE_NAME}` (
                `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                `partner` varchar(50) NOT NULL,
                `event_type` varchar(100) NOT NULL,
                `transaction_id` varchar(255) DEFAULT NULL,
                `order_id` varchar(255) DEFAULT NULL,
                `amount` decimal(10,2) DEFAULT 0.00,
                `commission` decimal(10,2) DEFAULT 0.00,
                `status` varchar(50) NOT NULL,
                `currency` varchar(3) DEFAULT 'RUB',
                `user_id` varchar(255) DEFAULT NULL,
                `offer_id` varchar(255) DEFAULT NULL,
                `click_id` varchar(255) DEFAULT NULL,
                `client_ip` varchar(45) DEFAULT NULL,
                `user_agent` text,
                `raw_data` json DEFAULT NULL,
                `processed_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `unique_transaction` (`partner`, `transaction_id`),
                KEY `idx_partner_status` (`partner`, `status`),
                KEY `idx_created_at` (`created_at`),
                KEY `idx_transaction_id` (`transaction_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            """

            cursor.execute(create_table_sql)
            logger.info(f"Table {TABLE_NAME} created or already exists")

        connection.close()

    except Exception as e:
        logger.error(f"Error initializing database: {e}")

async def save_webhook_event(data: Dict[str, Any]):
    """Сохранение события webhook в базу данных"""
    try:
        connection = get_db_connection()
        if not connection:
            logger.error("Failed to connect to database for saving")
            return False

        with connection.cursor() as cursor:
            # Подготовка данных для вставки
            insert_sql = f"""
            INSERT INTO `{TABLE_NAME}` 
            (partner, event_type, transaction_id, order_id, amount, commission, 
             status, currency, user_id, offer_id, click_id, client_ip, 
             user_agent, raw_data)
            VALUES 
            (%(partner)s, %(event_type)s, %(transaction_id)s, %(order_id)s, 
             %(amount)s, %(commission)s, %(status)s, %(currency)s, 
             %(user_id)s, %(offer_id)s, %(click_id)s, %(client_ip)s, 
             %(user_agent)s, %(raw_data)s)
            ON DUPLICATE KEY UPDATE
            amount = VALUES(amount),
            commission = VALUES(commission),
            status = VALUES(status),
            raw_data = VALUES(raw_data),
            updated_at = CURRENT_TIMESTAMP
            """

            # Подготовка данных
            insert_data = {
                'partner': data.get('partner'),
                'event_type': data.get('event_type'),
                'transaction_id': data.get('transaction_id'),
                'order_id': data.get('order_id'),
                'amount': data.get('amount', 0),
                'commission': data.get('commission', 0),
                'status': data.get('status'),
                'currency': data.get('currency', 'RUB'),
                'user_id': data.get('user_id'),
                'offer_id': data.get('offer_id'),
                'click_id': data.get('click_id'),
                'client_ip': data.get('client_ip'),
                'user_agent': data.get('user_agent'),
                'raw_data': json.dumps(data.get('raw_data', {}))
            }

            cursor.execute(insert_sql, insert_data)

            logger.info(f"Saved webhook event: {data.get('partner')} - {data.get('transaction_id')}")

        connection.close()
        return True

    except Exception as e:
        logger.error(f"Error saving webhook event: {e}")
        return False

async def get_webhook_stats() -> Optional[Dict[str, Any]]:
    """Получение статистики webhook'ов"""
    try:
        connection = get_db_connection()
        if not connection:
            return None

        with connection.cursor() as cursor:
            stats_sql = f"""
            SELECT 
                partner,
                COUNT(*) as total_events,
                COUNT(DISTINCT transaction_id) as unique_transactions,
                SUM(amount) as total_amount,
                SUM(commission) as total_commission
            FROM `{TABLE_NAME}`
            GROUP BY partner
            """

            cursor.execute(stats_sql)
            results = cursor.fetchall()

        connection.close()
        return results

    except Exception as e:
        logger.error(f"Error getting webhook stats: {e}")
        return None
EOF

echo -e "${GREEN}Модуль базы данных создан${NC}"

# Создание SQL скрипта для инициализации
mkdir -p scripts

cat > scripts/init_webhook_table.sql << 'EOF'
-- Создание таблицы для webhook событий
CREATE TABLE IF NOT EXISTS `webhook_events` (
    `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
    `partner` varchar(50) NOT NULL COMMENT 'Название партнера (epn_bz, admitad, etc)',
    `event_type` varchar(100) NOT NULL COMMENT 'Тип события',
    `transaction_id` varchar(255) DEFAULT NULL COMMENT 'Уникальный ID транзакции',
    `order_id` varchar(255) DEFAULT NULL COMMENT 'ID заказа',
    `amount` decimal(10,2) DEFAULT 0.00 COMMENT 'Сумма заказа',
    `commission` decimal(10,2) DEFAULT 0.00 COMMENT 'Размер комиссии/кешбэка',
    `status` varchar(50) NOT NULL COMMENT 'Статус события (confirmed, pending, cancelled)',
    `currency` varchar(3) DEFAULT 'RUB' COMMENT 'Валюта',
    `user_id` varchar(255) DEFAULT NULL COMMENT 'ID пользователя',
    `offer_id` varchar(255) DEFAULT NULL COMMENT 'ID оффера/товара',
    `click_id` varchar(255) DEFAULT NULL COMMENT 'ID клика',
    `client_ip` varchar(45) DEFAULT NULL COMMENT 'IP адрес клиента',
    `user_agent` text COMMENT 'User Agent',
    `raw_data` json DEFAULT NULL COMMENT 'Исходные данные webhook',
    `processed_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `unique_transaction` (`partner`, `transaction_id`),
    KEY `idx_partner_status` (`partner`, `status`),
    KEY `idx_created_at` (`created_at`),
    KEY `idx_transaction_id` (`transaction_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Создание индексов для оптимизации запросов
CREATE INDEX idx_partner_created ON webhook_events(partner, created_at);
CREATE INDEX idx_status_amount ON webhook_events(status, amount);
EOF

# README файл
cat > README.md << 'EOF'
# Universal Webhook Service

Универсальный сервис для приема webhook'ов от различных партнерских программ.

## Архитектура

```
Партнеры → FastAPI → Svix → MariaDB
```

## Установка

1. Запустите установочный скрипт:
```bash
bash install_svix.sh
```

2. Сервис будет доступен по адресам:
- Svix Dashboard: https://your-domain.com
- Webhook Receiver: https://webhook.your-domain.com

## Использование

### Endpoint'ы для webhook'ов:

- POST/GET `/webhook/epn_bz` - для EPN.bz
- POST/GET `/webhook/{partner_id}` - для других партнеров

### Добавление нового партнера:

1. Создайте новый файл в `app/partners/new_partner.py`
2. Наследуйтесь от `BasePartner`
3. Реализуйте методы верификации и обработки
4. Зарегистрируйте в `main.py`

## Мониторинг

- Health check: `/health`
- Статистика в таблице `webhook_events`

## Структура данных

Все webhook'и нормализуются к единому формату:
- partner: название партнера
- transaction_id: уникальный ID
- amount: сумма
- commission: размер кешбэка
- status: статус события
- raw_data: исходные данные

## Безопасность

- Проверка HMAC подписей
- Валидация IP адресов
- Rate limiting через Svix
- Дедупликация событий

EOF

echo -e "${YELLOW}Запуск установки...${NC}"

# Создание сетей если не существуют
docker network create proxy 2>/dev/null || true
docker network create wp-backend 2>/dev/null || true

# Сборка и запуск
echo -e "${YELLOW}Сборка и запуск контейнеров...${NC}"
docker-compose up -d --build

# Ожидание запуска сервисов
echo -e "${YELLOW}Ожидание запуска сервисов (30 секунд)...${NC}"
sleep 30

# Проверка статуса
echo -e "${BLUE}Проверка статуса сервисов:${NC}"
docker-compose ps

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "${BLUE}Сервисы доступны по адресам:${NC}"
echo -e "Svix Dashboard: https://${DOMAIN}"
echo -e "Webhook Receiver: https://webhook.${DOMAIN}"
echo -e "Health Check: https://webhook.${DOMAIN}/health"
echo ""
echo -e "${YELLOW}Тестовый webhook для EPN.bz:${NC}"
echo -e "curl -X POST https://webhook.${DOMAIN}/webhook/epn_bz \\"
echo -e "  -H 'Content-Type: application/json' \\"
echo -e "  -d '{"click_id":"test123","amount":"100.50","status":"confirmed"}'"
echo ""
echo -e "${BLUE}Для просмотра логов:${NC}"
echo -e "docker-compose logs -f webhook_receiver"
echo -e "docker-compose logs -f svix_server"
echo ""
echo -e "${GREEN}Секрет для webhook URL: ${WEBHOOK_SECRET}${NC}"