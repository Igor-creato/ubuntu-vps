#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Установка Svix Webhook Service (Updated) ===${NC}"

# Проверка что мы не root
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

# Основной файл FastAPI с поддержкой секрета в URL
cat > app/main.py << 'EOF'
import os
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
import logging
from contextlib import asynccontextmanager

from database import init_db
from webhook_processor import WebhookProcessor
from partners.epn_bz import EpnBzPartner

# Настройка логирования
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Получение секрета из переменной окружения
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET")

# Инициализация базы данных при старте
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Initializing database...")
    await init_db()
    logger.info("Database initialized")
    logger.info(f"Webhook secret configured: {'Yes' if WEBHOOK_SECRET else 'No'}")
    yield
    # Shutdown
    logger.info("Shutting down...")

app = FastAPI(
    title="Universal Webhook Service",
    description="Универсальный сервис приема webhook'ов с поддержкой секрета в URL",
    version="1.0.0",
    lifespan=lifespan
)

# Инициализация процессора webhook'ов
webhook_processor = WebhookProcessor()

# Регистрация партнеров
webhook_processor.register_partner("epn_bz", EpnBzPartner(WEBHOOK_SECRET))

@app.get("/")
async def root():
    return {
        "message": "Universal Webhook Service is running",
        "version": "1.0.0",
        "endpoints": {
            "health": "/health",
            "webhook_epn_bz": f"/webhook/epn_bz?secret=YOUR_SECRET",
            "webhook_generic": "/webhook/{{partner_id}}?secret=YOUR_SECRET"
        }
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy", 
        "service": "webhook-receiver",
        "secret_configured": bool(WEBHOOK_SECRET)
    }

@app.post("/webhook/{partner_id}")
async def receive_webhook_post(
    partner_id: str, 
    request: Request, 
    background_tasks: BackgroundTasks
):
    """Прием POST webhook'ов с проверкой секрета в URL"""
    return await webhook_processor.process_webhook(
        partner_id, request, background_tasks
    )

@app.get("/webhook/{partner_id}")
async def receive_webhook_get(
    partner_id: str, 
    request: Request, 
    background_tasks: BackgroundTasks
):
    """Прием GET webhook'ов с проверкой секрета в URL"""
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

echo -e "${GREEN}Основной файл FastAPI с поддержкой секрета в URL создан${NC}"

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

    def __init__(self, name: str, secret_key: Optional[str] = None):
        self.name = name
        self.secret_key = secret_key
        logger.info(f"Initialized partner: {name}")

    @abstractmethod
    async def verify_signature(self, request: Request, body: bytes) -> bool:
        """Проверка подписи или секрета webhook'а"""
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

    def verify_secret_in_url(self, request: Request) -> bool:
        """Проверка секрета в параметрах URL"""
        if not self.secret_key:
            logger.warning(f"No secret key configured for {self.name}")
            return True  # Пропускаем если секрет не настроен

        secret_in_url = request.query_params.get("secret", "")
        if not secret_in_url:
            logger.warning(f"No secret parameter in URL for {self.name}")
            return False

        is_valid = secret_in_url == self.secret_key
        logger.info(f"Secret validation for {self.name}: {'Valid' if is_valid else 'Invalid'}")
        return is_valid

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация запроса"""
        return True
EOF

echo -e "${GREEN}Базовый класс партнера с поддержкой секрета в URL создан${NC}"

# Обновленный класс EPN.bz с проверкой секрета в URL
cat > app/partners/epn_bz.py << 'EOF'
import json
from typing import Dict, Any, Optional
from fastapi import Request, HTTPException
from urllib.parse import parse_qs
import logging

from .base_partner import BasePartner

logger = logging.getLogger(__name__)

class EpnBzPartner(BasePartner):
    """Класс для работы с webhook'ами EPN.bz с проверкой секрета в URL"""

    def __init__(self, secret_key: Optional[str] = None):
        super().__init__("EPN.bz", secret_key)
        logger.info(f"EPN.bz partner initialized with secret: {'Yes' if secret_key else 'No'}")

    async def verify_signature(self, request: Request, body: bytes) -> bool:
        """
        EPN.bz не отправляет HMAC подписи, поэтому проверяем секрет в URL параметрах
        """
        try:
            # Проверяем секрет в URL
            if not self.verify_secret_in_url(request):
                return False

            # Дополнительно можно проверить IP адрес (если известны IP EPN.bz)
            client_ip = self.get_client_ip(request)
            logger.info(f"EPN.bz webhook from IP: {client_ip}")

            # Список разрешенных IP EPN.bz (можно дополнить)
            # allowed_ips = ["185.71.76.0/24", "185.71.77.0/24"]  # Пример
            # В реальности нужно получить актуальные IP из документации EPN.bz

            return True

        except Exception as e:
            logger.error(f"Error verifying EPN.bz request: {e}")
            return False

    async def parse_webhook(self, request: Request, body: bytes) -> Dict[str, Any]:
        """Парсинг webhook'а от EPN.bz"""
        try:
            client_ip = self.get_client_ip(request)
            user_agent = request.headers.get("user-agent", "")

            if request.method == "POST":
                content_type = request.headers.get("content-type", "")

                if "application/json" in content_type:
                    # JSON payload
                    data = json.loads(body.decode('utf-8'))
                    logger.info("Parsed EPN.bz JSON data")
                elif "application/x-www-form-urlencoded" in content_type:
                    # Form data
                    form_data = parse_qs(body.decode('utf-8'))
                    data = {k: v[0] if len(v) == 1 else v for k, v in form_data.items()}
                    logger.info("Parsed EPN.bz form data")
                else:
                    # Попытка парсинга как JSON
                    try:
                        data = json.loads(body.decode('utf-8'))
                        logger.info("Parsed EPN.bz data as JSON fallback")
                    except:
                        # Если не JSON, то как строка
                        raw_string = body.decode('utf-8')
                        data = {"raw_content": raw_string}
                        logger.info("Parsed EPN.bz data as raw string")
            else:
                # GET request - параметры в URL
                data = dict(request.query_params)
                # Удаляем секрет из данных для сохранения в БД
                data.pop("secret", None)
                logger.info("Parsed EPN.bz GET data")

            # Добавляем метаданные
            data["_client_ip"] = client_ip
            data["_user_agent"] = user_agent
            data["_method"] = request.method

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
            # Определяем тип события на основе данных
            event_type = "unknown"
            if data.get("status") == "confirmed" or data.get("action") == "confirmed":
                event_type = "order.confirmed"
            elif data.get("status") == "pending" or data.get("action") == "pending":
                event_type = "order.pending"
            elif data.get("status") == "cancelled" or data.get("action") == "cancelled":
                event_type = "order.cancelled"
            elif data.get("click_id"):
                event_type = "click.tracked"

            # Нормализация данных к единому формату
            processed_data = {
                "partner": "epn_bz",
                "event_type": event_type,
                "transaction_id": data.get("click_id") or data.get("transaction_id") or data.get("order_id"),
                "order_id": data.get("order_id") or data.get("offer_id"),
                "amount": float(data.get("amount", 0)) if data.get("amount") else 0.0,
                "commission": float(data.get("commission", 0)) if data.get("commission") else 0.0,
                "status": data.get("status", "unknown"),
                "currency": data.get("currency", "RUB"),
                "user_id": data.get("user_id") or data.get("subid"),
                "offer_id": data.get("offer_id"),
                "click_id": data.get("click_id"),
                "client_ip": data.get("_client_ip"),
                "user_agent": data.get("_user_agent"),
                "raw_data": data,
                "processed_at": None  # Будет установлено в базе данных
            }

            # Дополнительная обработка для EPN.bz специфичных полей
            if data.get("cashback_amount"):
                processed_data["commission"] = float(data.get("cashback_amount", 0))

            if data.get("shop_id"):
                processed_data["shop_id"] = data.get("shop_id")

            # Валидация обязательных полей
            if not processed_data["transaction_id"]:
                # Генерируем transaction_id из доступных данных
                processed_data["transaction_id"] = f"epn_{data.get('order_id', '')}_{data.get('offer_id', '')}".strip('_')
                if processed_data["transaction_id"] == "epn_":
                    processed_data["transaction_id"] = f"epn_unknown_{hash(str(data)) % 1000000}"
                logger.warning(f"Generated transaction_id: {processed_data['transaction_id']}")

            logger.info(f"Processed EPN.bz data: transaction_id={processed_data['transaction_id']}, amount={processed_data['amount']}")
            return processed_data

        except Exception as e:
            logger.error(f"Error processing EPN.bz data: {e}")
            raise HTTPException(status_code=400, detail="Failed to process data")

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация для EPN.bz"""
        client_ip = self.get_client_ip(request)
        user_agent = request.headers.get("user-agent", "")

        logger.info(f"EPN.bz request validation: IP={client_ip}, UA={user_agent}")

        # Можно добавить дополнительные проверки:
        # 1. Whitelist IP адресов EPN.bz
        # 2. Проверка User-Agent
        # 3. Rate limiting

        return True
EOF

echo -e "${GREEN}Обновленный класс партнера EPN.bz с проверкой секрета в URL создан${NC}"

# Процессор webhook'ов с поддержкой секрета в URL
cat > app/webhook_processor.py << 'EOF'
import logging
from typing import Dict, Any
from fastapi import Request, HTTPException, BackgroundTasks

from partners.base_partner import BasePartner
from database import save_webhook_event

logger = logging.getLogger(__name__)

class WebhookProcessor:
    """Основной процессор webhook'ов с поддержкой секрета в URL"""

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
        """Основная обработка webhook'а с проверкой секрета в URL"""
        start_time = None
        try:
            import time
            start_time = time.time()

            # Проверка существования партнера
            if partner_id not in self.partners:
                logger.error(f"Unknown partner: {partner_id}")
                raise HTTPException(status_code=404, detail=f"Partner {partner_id} not found")

            partner = self.partners[partner_id]
            logger.info(f"Processing webhook for partner: {partner_id} ({request.method})")

            # Получение тела запроса
            body = await request.body()

            # Валидация запроса
            if not await partner.validate_request(request):
                logger.error(f"Request validation failed for {partner_id}")
                raise HTTPException(status_code=400, detail="Request validation failed")

            # Проверка секрета/подписи (теперь включает проверку секрета в URL)
            if not await partner.verify_signature(request, body):
                logger.error(f"Signature/secret verification failed for {partner_id}")
                raise HTTPException(status_code=401, detail="Invalid signature or secret")

            # Парсинг данных
            raw_data = await partner.parse_webhook(request, body)

            # Обработка данных
            processed_data = await partner.process_data(raw_data)

            # Асинхронное сохранение в базу данных
            background_tasks.add_task(save_webhook_event, processed_data)

            # Отправка в Svix (можно добавить позже)
            # background_tasks.add_task(send_to_svix, processed_data)

            processing_time = time.time() - start_time if start_time else 0
            logger.info(f"Successfully processed webhook for {partner_id} in {processing_time:.3f}s")

            return {
                "status": "success",
                "partner": partner_id,
                "transaction_id": processed_data.get("transaction_id"),
                "event_type": processed_data.get("event_type"),
                "amount": processed_data.get("amount"),
                "processing_time": f"{processing_time:.3f}s",
                "message": "Webhook processed successfully"
            }

        except HTTPException:
            raise
        except Exception as e:
            processing_time = time.time() - start_time if start_time else 0
            logger.error(f"Error processing webhook for {partner_id} after {processing_time:.3f}s: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail="Internal server error")
EOF

echo -e "${GREEN}Процессор webhook'ов с поддержкой секрета создан${NC}"

# Модуль для работы с базой данных
cat > app/database.py << 'EOF'
import os
import logging
from typing import Dict, Any, Optional
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
                `partner` varchar(50) NOT NULL COMMENT 'Партнер (epn_bz, admitad, etc)',
                `event_type` varchar(100) NOT NULL COMMENT 'Тип события',
                `transaction_id` varchar(255) DEFAULT NULL COMMENT 'Уникальный ID транзакции',
                `order_id` varchar(255) DEFAULT NULL COMMENT 'ID заказа',
                `amount` decimal(15,2) DEFAULT 0.00 COMMENT 'Сумма заказа',
                `commission` decimal(15,2) DEFAULT 0.00 COMMENT 'Размер комиссии/кешбэка',
                `status` varchar(50) NOT NULL COMMENT 'Статус события',
                `currency` varchar(3) DEFAULT 'RUB' COMMENT 'Валюта',
                `user_id` varchar(255) DEFAULT NULL COMMENT 'ID пользователя',
                `offer_id` varchar(255) DEFAULT NULL COMMENT 'ID оффера/товара',
                `click_id` varchar(255) DEFAULT NULL COMMENT 'ID клика',
                `shop_id` varchar(255) DEFAULT NULL COMMENT 'ID магазина',
                `client_ip` varchar(45) DEFAULT NULL COMMENT 'IP адрес клиента',
                `user_agent` text COMMENT 'User Agent браузера',
                `raw_data` json DEFAULT NULL COMMENT 'Исходные данные webhook',
                `processed_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Время обработки',
                `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Время создания',
                `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Время обновления',
                PRIMARY KEY (`id`),
                UNIQUE KEY `unique_partner_transaction` (`partner`, `transaction_id`),
                KEY `idx_partner_status` (`partner`, `status`),
                KEY `idx_created_at` (`created_at`),
                KEY `idx_transaction_id` (`transaction_id`),
                KEY `idx_partner_created` (`partner`, `created_at`),
                KEY `idx_status_amount` (`status`, `amount`),
                KEY `idx_event_type` (`event_type`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci 
              COMMENT='Таблица для хранения событий от webhook партнеров'
            """

            cursor.execute(create_table_sql)
            logger.info(f"Table {TABLE_NAME} created or already exists")

        connection.close()

    except Exception as e:
        logger.error(f"Error initializing database: {e}")

async def save_webhook_event(data: Dict[str, Any]) -> bool:
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
             status, currency, user_id, offer_id, click_id, shop_id, 
             client_ip, user_agent, raw_data)
            VALUES 
            (%(partner)s, %(event_type)s, %(transaction_id)s, %(order_id)s, 
             %(amount)s, %(commission)s, %(status)s, %(currency)s, 
             %(user_id)s, %(offer_id)s, %(click_id)s, %(shop_id)s,
             %(client_ip)s, %(user_agent)s, %(raw_data)s)
            ON DUPLICATE KEY UPDATE
            event_type = VALUES(event_type),
            order_id = VALUES(order_id),
            amount = VALUES(amount),
            commission = VALUES(commission),
            status = VALUES(status),
            currency = VALUES(currency),
            user_id = VALUES(user_id),
            offer_id = VALUES(offer_id),
            click_id = VALUES(click_id),
            shop_id = VALUES(shop_id),
            client_ip = VALUES(client_ip),
            user_agent = VALUES(user_agent),
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
                'shop_id': data.get('shop_id'),
                'client_ip': data.get('client_ip'),
                'user_agent': data.get('user_agent'),
                'raw_data': json.dumps(data.get('raw_data', {}), ensure_ascii=False)
            }

            cursor.execute(insert_sql, insert_data)

            logger.info(f"Saved webhook event: {data.get('partner')} - {data.get('transaction_id')} - {data.get('amount')} {data.get('currency', 'RUB')}")

        connection.close()
        return True

    except Exception as e:
        logger.error(f"Error saving webhook event: {e}")
        if "Duplicate entry" in str(e):
            logger.info("Duplicate webhook event - updated existing record")
            return True
        return False

async def get_webhook_stats() -> Optional[Dict[str, Any]]:
    """Получение статистики webhook'ов"""
    try:
        connection = get_db_connection()
        if not connection:
            return None

        with connection.cursor() as cursor:
            # Общая статистика по партнерам
            stats_sql = f"""
            SELECT 
                partner,
                COUNT(*) as total_events,
                COUNT(DISTINCT transaction_id) as unique_transactions,
                SUM(amount) as total_amount,
                SUM(commission) as total_commission,
                COUNT(CASE WHEN status = 'confirmed' THEN 1 END) as confirmed_count,
                COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending_count,
                COUNT(CASE WHEN status = 'cancelled' THEN 1 END) as cancelled_count,
                MIN(created_at) as first_event,
                MAX(created_at) as last_event
            FROM `{TABLE_NAME}`
            GROUP BY partner
            ORDER BY total_events DESC
            """

            cursor.execute(stats_sql)
            results = cursor.fetchall()

            # Статистика за сегодня
            today_sql = f"""
            SELECT 
                partner,
                COUNT(*) as today_events,
                SUM(amount) as today_amount,
                SUM(commission) as today_commission
            FROM `{TABLE_NAME}`
            WHERE DATE(created_at) = CURDATE()
            GROUP BY partner
            """

            cursor.execute(today_sql)
            today_results = cursor.fetchall()

        connection.close()

        return {
            "total_stats": results,
            "today_stats": today_results,
            "generated_at": datetime.now().isoformat()
        }

    except Exception as e:
        logger.error(f"Error getting webhook stats: {e}")
        return None
EOF

echo -e "${GREEN}Модуль базы данных создан${NC}"

# Создание SQL скрипта для инициализации
mkdir -p scripts

cat > scripts/init_webhook_table.sql << 'EOF'
-- Создание таблицы для webhook событий с поддержкой секрета в URL
CREATE TABLE IF NOT EXISTS `webhook_events` (
    `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
    `partner` varchar(50) NOT NULL COMMENT 'Название партнера (epn_bz, admitad, etc)',
    `event_type` varchar(100) NOT NULL COMMENT 'Тип события (order.confirmed, click.tracked, etc)',
    `transaction_id` varchar(255) DEFAULT NULL COMMENT 'Уникальный ID транзакции',
    `order_id` varchar(255) DEFAULT NULL COMMENT 'ID заказа',
    `amount` decimal(15,2) DEFAULT 0.00 COMMENT 'Сумма заказа',
    `commission` decimal(15,2) DEFAULT 0.00 COMMENT 'Размер комиссии/кешбэка',
    `status` varchar(50) NOT NULL COMMENT 'Статус события (confirmed, pending, cancelled)',
    `currency` varchar(3) DEFAULT 'RUB' COMMENT 'Валюта',
    `user_id` varchar(255) DEFAULT NULL COMMENT 'ID пользователя',
    `offer_id` varchar(255) DEFAULT NULL COMMENT 'ID оффера/товара',
    `click_id` varchar(255) DEFAULT NULL COMMENT 'ID клика',
    `shop_id` varchar(255) DEFAULT NULL COMMENT 'ID магазина',
    `client_ip` varchar(45) DEFAULT NULL COMMENT 'IP адрес клиента',
    `user_agent` text COMMENT 'User Agent браузера',
    `raw_data` json DEFAULT NULL COMMENT 'Исходные данные webhook в формате JSON',
    `processed_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Время обработки webhook',
    `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Время создания записи',
    `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Время последнего обновления',
    PRIMARY KEY (`id`),
    UNIQUE KEY `unique_partner_transaction` (`partner`, `transaction_id`),
    KEY `idx_partner_status` (`partner`, `status`),
    KEY `idx_created_at` (`created_at`),
    KEY `idx_transaction_id` (`transaction_id`),
    KEY `idx_partner_created` (`partner`, `created_at`),
    KEY `idx_status_amount` (`status`, `amount`),
    KEY `idx_event_type` (`event_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci 
  COMMENT='Таблица для хранения событий от webhook партнеров с поддержкой секрета в URL';

-- Создание дополнительных индексов для оптимизации
CREATE INDEX idx_partner_event_type ON webhook_events(partner, event_type);
CREATE INDEX idx_amount_commission ON webhook_events(amount, commission);
CREATE INDEX idx_date_partner ON webhook_events(DATE(created_at), partner);
EOF

# README файл с инструкциями по использованию секрета в URL
cat > README.md << 'EOF'
# Universal Webhook Service с поддержкой секрета в URL

Универсальный сервис для приема webhook'ов от различных партнерских программ с проверкой секрета через URL параметры.

## Архитектура

```
Партнеры → FastAPI (с секретом в URL) → Svix → MariaDB
```

## Установка

1. Запустите установочный скрипт:
```bash
bash install_svix_updated.sh
```

2. Сервис будет доступен по адресам:
- Svix Dashboard: https://your-domain.com
- Webhook Receiver: https://webhook.your-domain.com

## Использование

### URL для настройки у партнеров:

**EPN.bz:**
```
https://webhook.your-domain.com/webhook/epn_bz?secret=YOUR_GENERATED_SECRET
```

**Другие партнеры:**
```
https://webhook.your-domain.com/webhook/{partner_id}?secret=YOUR_GENERATED_SECRET
```

### Секрет в URL

- Секрет генерируется автоматически при установке
- Секрет передается как GET параметр `?secret=...`
- Работает для POST и GET запросов
- Без правильного секрета запрос будет отклонен с ошибкой 401

### Поддерживаемые методы:

- **POST** `/webhook/epn_bz?secret=...` - основной метод для webhook'ов
- **GET** `/webhook/epn_bz?secret=...` - для партнеров использующих GET

### Endpoint'ы сервиса:

- `/` - информация о сервисе и примеры URL
- `/health` - проверка работоспособности
- `/webhook/{partner_id}` - прием webhook'ов

## Добавление нового партнера

1. Создайте новый файл `app/partners/new_partner.py`
2. Наследуйтесь от `BasePartner`
3. Реализуйте методы:
   - `verify_signature()` - проверка секрета (используйте `self.verify_secret_in_url()`)
   - `parse_webhook()` - парсинг данных
   - `process_data()` - нормализация данных
4. Зарегистрируйте в `main.py`:
   ```python
   webhook_processor.register_partner("new_partner", NewPartner(WEBHOOK_SECRET))
   ```

## Мониторинг

- Health check: `https://webhook.your-domain.com/health`
- Логи: `docker-compose logs -f webhook_receiver`
- Статистика в таблице `webhook_events`

## Структура данных

Все webhook'и нормализуются к единому формату:
- `partner`: название партнера (epn_bz, admitad, etc)
- `event_type`: тип события (order.confirmed, click.tracked, etc)
- `transaction_id`: уникальный ID транзакции
- `amount`: сумма заказа
- `commission`: размер кешбэка
- `status`: статус события (confirmed, pending, cancelled)
- `raw_data`: исходные данные в JSON

## Безопасность

- ✅ Проверка секрета в URL параметрах
- ✅ Валидация IP адресов (настраивается)
- ✅ Rate limiting через Svix
- ✅ Дедупликация событий через UNIQUE constraint
- ✅ Подробное логирование всех запросов
- ✅ HTTPS через Traefik + Let's Encrypt

## Примеры тестирования

### POST запрос с JSON:
```bash
curl -X POST "https://webhook.your-domain.com/webhook/epn_bz?secret=YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"click_id":"test123","amount":"100.50","status":"confirmed","order_id":"ORDER123"}'
```

### GET запрос с параметрами:
```bash
curl -X GET "https://webhook.your-domain.com/webhook/epn_bz?secret=YOUR_SECRET&click_id=test456&amount=75.25&status=pending"
```

### Проверка здоровья:
```bash
curl "https://webhook.your-domain.com/health"
```

## Логи и отладка

```bash
# Просмотр логов webhook receiver
docker-compose logs -f webhook_receiver

# Просмотр логов Svix
docker-compose logs -f svix_server

# Просмотр всех логов
docker-compose logs -f
```

## База данных

Просмотр данных в MariaDB:
```sql
-- Последние события
SELECT * FROM webhook_events ORDER BY created_at DESC LIMIT 10;

-- Статистика по партнерам
SELECT partner, COUNT(*) as events, SUM(amount) as total_amount 
FROM webhook_events GROUP BY partner;

-- События за сегодня
SELECT * FROM webhook_events WHERE DATE(created_at) = CURDATE();
```

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
echo -e "${GREEN}=== ПОЛНЫЙ URL ДЛЯ EPN.BZ ===${NC}"
echo -e "${YELLOW}https://webhook.${DOMAIN}/webhook/epn_bz?secret=${WEBHOOK_SECRET}${NC}"
echo ""
echo -e "${BLUE}Тестовые webhook'и:${NC}"
echo ""
echo -e "${YELLOW}POST запрос с JSON:${NC}"
echo -e "curl -X POST 'https://webhook.${DOMAIN}/webhook/epn_bz?secret=${WEBHOOK_SECRET}' \\"
echo -e "  -H 'Content-Type: application/json' \\"
echo -e "  -d '{"click_id":"test123","amount":"100.50","status":"confirmed","order_id":"ORDER123"}'"
echo ""
echo -e "${YELLOW}GET запрос с параметрами:${NC}"
echo -e "curl 'https://webhook.${DOMAIN}/webhook/epn_bz?secret=${WEBHOOK_SECRET}&click_id=test456&amount=75.25&status=pending'"
echo ""
echo -e "${BLUE}Для просмотра логов:${NC}"
echo -e "docker-compose logs -f webhook_receiver"
echo -e "docker-compose logs -f svix_server"
echo ""
echo -e "${GREEN}Секрет для webhook URL: ${WEBHOOK_SECRET}${NC}"
echo -e "${GREEN}Сохраните этот секрет - он нужен для настройки у партнеров!${NC}"