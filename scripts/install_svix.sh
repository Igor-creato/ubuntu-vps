#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Установка Svix Webhook Service (Path-based Secret) ===${NC}"

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

# Генерация секретного токена для пути URL (64 символа hex)
WEBHOOK_SECRET_TOKEN=$(openssl rand -hex 32)
echo -e "${GREEN}Сгенерирован секретный токен: $WEBHOOK_SECRET_TOKEN${NC}"

# Формирование полного webhook URL
WEBHOOK_DOMAIN="webhook.${DOMAIN}"
FULL_WEBHOOK_URL="https://${WEBHOOK_DOMAIN}/webhook/${WEBHOOK_SECRET_TOKEN}"

# Создание структуры проекта
echo -e "${YELLOW}Создание файлов проекта...${NC}"

# .env файл
cat > .env << EOF
# Database Configuration
DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@db:3306/${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
TABLE_NAME=${TABLE_NAME}

# Webhook Configuration
WEBHOOK_SECRET_TOKEN=${WEBHOOK_SECRET_TOKEN}
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN}
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
      DATABASE_URL: mysql://${DB_USER}:${DB_PASSWORD}@db:3306/${DB_NAME}
      WEBHOOK_SECRET_TOKEN: ${WEBHOOK_SECRET_TOKEN}
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
      - "traefik.http.routers.webhook.rule=Host(`${WEBHOOK_DOMAIN}`)"
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

# Основной файл FastAPI с поддержкой секрета в пути URL
cat > app/main.py << 'EOF'
import os
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks, Path
from fastapi.responses import JSONResponse
import logging
from contextlib import asynccontextmanager

from database import init_db
from webhook_processor import WebhookProcessor
from partners.epn_bz import EpnBzPartner

# Настройка логирования
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Получение секретного токена из переменной окружения
WEBHOOK_SECRET_TOKEN = os.getenv("WEBHOOK_SECRET_TOKEN")

# Инициализация базы данных при старте
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Initializing database...")
    await init_db()
    logger.info("Database initialized")
    logger.info(f"Webhook secret token configured: {'Yes' if WEBHOOK_SECRET_TOKEN else 'No'}")
    yield
    # Shutdown
    logger.info("Shutting down...")

app = FastAPI(
    title="Universal Webhook Service",
    description="Универсальный сервис приема webhook'ов с секретом в пути URL",
    version="2.0.0",
    lifespan=lifespan
)

# Инициализация процессора webhook'ов
webhook_processor = WebhookProcessor()

# Регистрация партнеров с токеном
webhook_processor.register_partner("epn_bz", EpnBzPartner(WEBHOOK_SECRET_TOKEN))

@app.get("/")
async def root():
    webhook_domain = os.getenv("WEBHOOK_DOMAIN", "webhook.yourdomain.com")
    return {
        "message": "Universal Webhook Service is running",
        "version": "2.0.0",
        "description": "Секрет передается в пути URL",
        "endpoints": {
            "health": "/health",
            "webhook_url": f"https://{webhook_domain}/webhook/{{SECRET_TOKEN}}",
            "example": f"https://{webhook_domain}/webhook/{WEBHOOK_SECRET_TOKEN[:16]}..." if WEBHOOK_SECRET_TOKEN else "Not configured"
        }
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy", 
        "service": "webhook-receiver",
        "version": "2.0.0",
        "secret_configured": bool(WEBHOOK_SECRET_TOKEN)
    }

@app.post("/webhook/{secret_token}")
async def receive_webhook_post(
    secret_token: str = Path(..., description="Секретный токен для аутентификации"),
    request: Request = None,
    background_tasks: BackgroundTasks = None
):
    """Прием POST webhook'ов с проверкой секрета в пути URL"""
    return await webhook_processor.process_webhook_with_path_secret(
        secret_token, request, background_tasks
    )

@app.get("/webhook/{secret_token}")
async def receive_webhook_get(
    secret_token: str = Path(..., description="Секретный токен для аутентификации"),
    request: Request = None,
    background_tasks: BackgroundTasks = None
):
    """Прием GET webhook'ов с проверкой секрета в пути URL"""
    return await webhook_processor.process_webhook_with_path_secret(
        secret_token, request, background_tasks
    )

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Global exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error"}
    )
EOF

echo -e "${GREEN}Основной файл FastAPI с секретом в пути URL создан${NC}"

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

    def __init__(self, name: str, secret_token: Optional[str] = None):
        self.name = name
        self.secret_token = secret_token
        logger.info(f"Initialized partner: {name}")

    @abstractmethod
    async def verify_secret_token(self, provided_token: str) -> bool:
        """Проверка секретного токена из пути URL"""
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
        return request.client.host if request.client else "unknown"

    def verify_path_secret_token(self, provided_token: str) -> bool:
        """Базовая проверка токена из пути URL"""
        if not self.secret_token:
            logger.warning(f"No secret token configured for {self.name}")
            return True  # Пропускаем если токен не настроен

        if not provided_token:
            logger.warning(f"No token provided in URL path for {self.name}")
            return False

        is_valid = provided_token == self.secret_token
        logger.info(f"Token validation for {self.name}: {'Valid' if is_valid else 'Invalid'}")
        return is_valid

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация запроса"""
        return True
EOF

echo -e "${GREEN}Базовый класс партнера с поддержкой секрета в пути URL создан${NC}"

# Обновленный класс EPN.bz с проверкой секрета в пути URL
cat > app/partners/epn_bz.py << 'EOF'
import json
from typing import Dict, Any, Optional
from fastapi import Request, HTTPException
from urllib.parse import parse_qs
import logging

from .base_partner import BasePartner

logger = logging.getLogger(__name__)

class EpnBzPartner(BasePartner):
    """Класс для работы с webhook'ами EPN.bz с проверкой секрета в пути URL"""

    def __init__(self, secret_token: Optional[str] = None):
        super().__init__("EPN.bz", secret_token)
        logger.info(f"EPN.bz partner initialized with token: {'Yes' if secret_token else 'No'}")

    async def verify_secret_token(self, provided_token: str) -> bool:
        """
        EPN.bz проверка секретного токена из пути URL
        """
        try:
            # Проверяем токен из пути URL
            is_valid = self.verify_path_secret_token(provided_token)

            if is_valid:
                logger.info(f"EPN.bz token verification successful")
            else:
                logger.warning(f"EPN.bz token verification failed")

            return is_valid

        except Exception as e:
            logger.error(f"Error verifying EPN.bz token: {e}")
            return False

    async def parse_webhook(self, request: Request, body: bytes) -> Dict[str, Any]:
        """Парсинг webhook'а от EPN.bz"""
        try:
            client_ip = self.get_client_ip(request)
            user_agent = request.headers.get("user-agent", "")
            content_type = request.headers.get("content-type", "")

            if request.method == "POST":
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
                logger.info("Parsed EPN.bz GET data")

            # Добавляем метаданные
            data["_client_ip"] = client_ip
            data["_user_agent"] = user_agent
            data["_method"] = request.method
            data["_content_type"] = content_type

            logger.info(f"Parsed EPN.bz data keys: {list(data.keys())}")
            return data

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON from EPN.bz: {e}")
            raise HTTPException(status_code=400, detail="Invalid JSON format")
        except Exception as e:
            logger.error(f"Error parsing EPN.bz webhook: {e}")
            raise HTTPException(status_code=400, detail="Failed to parse webhook data")

    async def process_data(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Обработка и нормализация данных EPN.bz"""
        try:
            # Определяем тип события на основе данных
            event_type = self._determine_event_type(data)

            # Нормализация данных к единому формату
            processed_data = {
                "partner": "epn_bz",
                "event_type": event_type,
                "transaction_id": self._extract_transaction_id(data),
                "order_id": data.get("order_id") or data.get("order_number") or data.get("offer_id"),
                "amount": self._extract_amount(data, "revenue") or self._extract_amount(data, "amount"),
                "commission": self._extract_amount(data, "commission") or self._extract_amount(data, "commission_fee"),
                "status": self._normalize_status(data.get("status") or data.get("order_status")),
                "currency": data.get("currency", "RUB"),
                "user_id": data.get("user_id") or data.get("sub") or data.get("subid"),
                "offer_id": data.get("offer_id"),
                "offer_name": data.get("offer_name"),
                "click_id": data.get("click_id"),
                "uniq_id": data.get("uniq_id"),
                "click_time": data.get("click_time"),
                "time_of_order": data.get("time_of_order"),
                "client_ip": data.get("_client_ip"),
                "user_agent": data.get("_user_agent"),
                "raw_data": data,
                "processed_at": None  # Будет установлено в базе данных
            }

            # Валидация и генерация transaction_id если отсутствует
            if not processed_data["transaction_id"]:
                processed_data["transaction_id"] = self._generate_transaction_id(data)
                logger.warning(f"Generated transaction_id: {processed_data['transaction_id']}")

            logger.info(f"Processed EPN.bz data: transaction_id={processed_data['transaction_id']}, amount={processed_data['amount']}, commission={processed_data['commission']}")
            return processed_data

        except Exception as e:
            logger.error(f"Error processing EPN.bz data: {e}")
            raise HTTPException(status_code=400, detail="Failed to process webhook data")

    def _determine_event_type(self, data: Dict[str, Any]) -> str:
        """Определение типа события"""
        status = (data.get("status") or data.get("order_status", "")).lower()

        if status in ["confirmed", "approved", "paid"]:
            return "order.confirmed"
        elif status in ["pending", "hold", "waiting"]:
            return "order.pending"
        elif status in ["cancelled", "rejected", "declined", "canceled"]:
            return "order.cancelled"
        elif data.get("click_id"):
            return "click.tracked"
        else:
            return "event.unknown"

    def _extract_transaction_id(self, data: Dict[str, Any]) -> Optional[str]:
        """Извлечение transaction_id из различных полей"""
        return (data.get("click_id") or 
                data.get("transaction_id") or 
                data.get("uniq_id") or
                data.get("order_id") or 
                data.get("order_number"))

    def _extract_amount(self, data: Dict[str, Any], field: str) -> float:
        """Безопасное извлечение суммы"""
        try:
            value = data.get(field, 0)
            return float(value) if value else 0.0
        except (ValueError, TypeError):
            return 0.0

    def _normalize_status(self, status: Optional[str]) -> str:
        """Нормализация статуса"""
        if not status:
            return "unknown"

        status_lower = status.lower()
        if status_lower in ["confirmed", "approved", "paid"]:
            return "confirmed"
        elif status_lower in ["pending", "hold", "waiting"]:
            return "pending"
        elif status_lower in ["cancelled", "rejected", "declined", "canceled"]:
            return "cancelled"
        else:
            return status_lower

    def _generate_transaction_id(self, data: Dict[str, Any]) -> str:
        """Генерация transaction_id из доступных данных"""
        parts = []
        if data.get('order_number'):
            parts.append(f"order_{data['order_number']}")
        if data.get('user_id'):
            parts.append(f"user_{data['user_id']}")
        if data.get('offer_id'):
            parts.append(f"offer_{data['offer_id']}")

        if parts:
            return "_".join(parts)
        else:
            # Генерируем на основе хеша данных
            import hashlib
            data_str = json.dumps(data, sort_keys=True)
            hash_part = hashlib.md5(data_str.encode()).hexdigest()[:8]
            return f"epn_generated_{hash_part}"

    async def validate_request(self, request: Request) -> bool:
        """Дополнительная валидация для EPN.bz"""
        client_ip = self.get_client_ip(request)
        user_agent = request.headers.get("user-agent", "")

        logger.info(f"EPN.bz request validation: IP={client_ip}, UA={user_agent[:50]}...")

        # Можно добавить дополнительные проверки:
        # 1. Whitelist IP адресов EPN.bz
        # 2. Проверка User-Agent
        # 3. Rate limiting

        return True
EOF

echo -e "${GREEN}Обновленный класс партнера EPN.bz с секретом в пути URL создан${NC}"

# Процессор webhook'ов с поддержкой секрета в пути URL
cat > app/webhook_processor.py << 'EOF'
import logging
import os
from typing import Dict, Any
from fastapi import Request, HTTPException, BackgroundTasks

from partners.base_partner import BasePartner
from database import save_webhook_event

logger = logging.getLogger(__name__)

class WebhookProcessor:
    """Основной процессор webhook'ов с поддержкой секрета в пути URL"""

    def __init__(self):
        self.partners: Dict[str, BasePartner] = {}
        self.secret_token = os.getenv("WEBHOOK_SECRET_TOKEN")
        logger.info("WebhookProcessor initialized")

    def register_partner(self, partner_id: str, partner: BasePartner):
        """Регистрация нового партнера"""
        self.partners[partner_id] = partner
        logger.info(f"Registered partner: {partner_id}")

    async def process_webhook_with_path_secret(
        self, 
        secret_token: str,
        request: Request, 
        background_tasks: BackgroundTasks
    ):
        """Обработка webhook'а с проверкой секрета в пути URL"""
        start_time = None
        try:
            import time
            start_time = time.time()

            # Проверка секретного токена
            if not self.secret_token:
                logger.error("Webhook secret token not configured")
                raise HTTPException(status_code=500, detail="Service configuration error")

            if secret_token != self.secret_token:
                logger.error(f"Invalid secret token provided: {secret_token[:8]}...")
                raise HTTPException(status_code=401, detail="Invalid secret token")

            logger.info(f"Valid secret token provided, processing webhook ({request.method})")

            # Определяем партнера (пока используем epn_bz по умолчанию)
            # В будущем можно расширить логику определения партнера
            partner_id = self._determine_partner(request)

            if partner_id not in self.partners:
                logger.error(f"Unknown partner: {partner_id}")
                raise HTTPException(status_code=404, detail=f"Partner {partner_id} not supported")

            partner = self.partners[partner_id]
            logger.info(f"Processing webhook for partner: {partner_id}")

            # Получение тела запроса
            body = await request.body()

            # Валидация запроса
            if not await partner.validate_request(request):
                logger.error(f"Request validation failed for {partner_id}")
                raise HTTPException(status_code=400, detail="Request validation failed")

            # Дополнительная проверка токена через партнера
            if not await partner.verify_secret_token(secret_token):
                logger.error(f"Partner token verification failed for {partner_id}")
                raise HTTPException(status_code=401, detail="Token verification failed")

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
                "commission": processed_data.get("commission"),
                "processing_time": f"{processing_time:.3f}s",
                "message": "Webhook processed successfully"
            }

        except HTTPException:
            raise
        except Exception as e:
            processing_time = time.time() - start_time if start_time else 0
            logger.error(f"Error processing webhook after {processing_time:.3f}s: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail="Internal server error")

    def _determine_partner(self, request: Request) -> str:
        """Определение партнера на основе запроса"""
        # Пока возвращаем epn_bz по умолчанию
        # В будущем можно добавить логику определения по:
        # - User-Agent
        # - Заголовкам
        # - Структуре данных
        # - Дополнительным параметрам в URL

        user_agent = request.headers.get("user-agent", "").lower()

        # Примеры определения партнера:
        if "epn" in user_agent:
            return "epn_bz"
        elif "admitad" in user_agent:
            return "admitad"  # Когда добавим
        elif "cityads" in user_agent:
            return "cityads"  # Когда добавим

        # По умолчанию - EPN.bz
        return "epn_bz"
EOF

echo -e "${GREEN}Процессор webhook'ов с поддержкой секрета в пути URL создан${NC}"

# Используем тот же модуль базы данных (без изменений)
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
                `offer_name` varchar(500) DEFAULT NULL COMMENT 'Название оффера/товара',
                `click_id` varchar(255) DEFAULT NULL COMMENT 'ID клика',
                `uniq_id` varchar(255) DEFAULT NULL COMMENT 'Уникальный ID',
                `shop_id` varchar(255) DEFAULT NULL COMMENT 'ID магазина',
                `click_time` varchar(50) DEFAULT NULL COMMENT 'Время клика',
                `time_of_order` varchar(50) DEFAULT NULL COMMENT 'Время заказа',
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
                KEY `idx_event_type` (`event_type`),
                KEY `idx_user_id` (`user_id`),
                KEY `idx_click_id` (`click_id`)
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
             status, currency, user_id, offer_id, offer_name, click_id, uniq_id,
             shop_id, click_time, time_of_order, client_ip, user_agent, raw_data)
            VALUES 
            (%(partner)s, %(event_type)s, %(transaction_id)s, %(order_id)s, 
             %(amount)s, %(commission)s, %(status)s, %(currency)s, 
             %(user_id)s, %(offer_id)s, %(offer_name)s, %(click_id)s, %(uniq_id)s,
             %(shop_id)s, %(click_time)s, %(time_of_order)s, %(client_ip)s, 
             %(user_agent)s, %(raw_data)s)
            ON DUPLICATE KEY UPDATE
            event_type = VALUES(event_type),
            order_id = VALUES(order_id),
            amount = VALUES(amount),
            commission = VALUES(commission),
            status = VALUES(status),
            currency = VALUES(currency),
            user_id = VALUES(user_id),
            offer_id = VALUES(offer_id),
            offer_name = VALUES(offer_name),
            click_id = VALUES(click_id),
            uniq_id = VALUES(uniq_id),
            shop_id = VALUES(shop_id),
            click_time = VALUES(click_time),
            time_of_order = VALUES(time_of_order),
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
                'offer_name': data.get('offer_name'),
                'click_id': data.get('click_id'),
                'uniq_id': data.get('uniq_id'),
                'shop_id': data.get('shop_id'),
                'click_time': data.get('click_time'),
                'time_of_order': data.get('time_of_order'),
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
EOF

echo -e "${GREEN}Модуль базы данных создан${NC}"

# README файл с инструкциями
cat > README.md << EOF
# Universal Webhook Service - Секрет в пути URL

Универсальный сервис для приема webhook'ов с секретом в пути URL.

## Архитектура

\`\`\`
Партнеры → FastAPI (секрет в URL path) → Svix → MariaDB
\`\`\`

## URL Format

**Формат URL:**
\`\`\`
https://webhook.yourdomain.com/webhook/{SECRET_TOKEN}
\`\`\`

**Пример:**
\`\`\`
https://webhook.comfyui.autmatization-bot.ru/webhook/71df03c1eb976689e60c9136c7c72ffdcdca2d216b6858f678b75306391b6893
\`\`\`

## Использование

### Настройка у партнеров:
- URL: \`https://webhook.yourdomain.com/webhook/YOUR_SECRET_TOKEN\`
- Поддерживает POST и GET запросы
- Параметры передаются обычным способом: \`?param1=value1&param2=value2\`

### Пример полного URL с параметрами:
\`\`\`
https://webhook.comfyui.autmatization-bot.ru/webhook/71df03c1eb976689e60c9136c7c72ffdcdca2d216b6858f678b75306391b6893?click_id=test123&order_number=50&offer_name=TestOffer&order_status=confirmed&user_id=6&revenue=1500&commission=100
\`\`\`

## Безопасность

- ✅ 64-символьный hex токен в пути URL
- ✅ Проверка токена перед обработкой
- ✅ Логирование всех попыток доступа
- ✅ HTTP 401 при неверном токене

## Поддерживаемые поля EPN.bz

- click_id, order_number, order_id
- offer_name, offer_id
- order_status, status
- user_id, sub, subid
- revenue, amount
- commission, commission_fee
- uniq_id
- click_time, time_of_order

## Запуск

\`\`\`bash
bash install_svix_path_secret.sh
\`\`\`

EOF

# Завершающая часть установки
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

echo -e "${GREEN}=== УСТАНОВКА ЗАВЕРШЕНА! ===${NC}"
echo -e "${BLUE}Сервисы доступны по адресам:${NC}"
echo -e "Svix Dashboard: https://${DOMAIN}"
echo -e "Webhook Receiver: https://${WEBHOOK_DOMAIN}"
echo -e "Health Check: https://${WEBHOOK_DOMAIN}/health"
echo ""
echo -e "${GREEN}=== ПОЛНЫЙ WEBHOOK URL ===${NC}"
echo -e "${YELLOW}${FULL_WEBHOOK_URL}${NC}"
echo ""
echo -e "${BLUE}Примеры использования:${NC}"
echo ""
echo -e "${YELLOW}POST запрос с JSON:${NC}"
echo -e "curl -X POST '${FULL_WEBHOOK_URL}' \\"
echo -e "  -H 'Content-Type: application/json' \\"
echo -e "  -d '{"click_id":"test123","order_number":"50","offer_name":"TestOffer","order_status":"confirmed","user_id":"6","revenue":"1500","commission":"100"}'"
echo ""
echo -e "${YELLOW}GET запрос с параметрами:${NC}"
echo -e "curl '${FULL_WEBHOOK_URL}?click_id=test456&order_number=75&offer_name=TestOffer2&order_status=pending&user_id=7&revenue=2000&commission=150'"
echo ""
echo -e "${YELLOW}Полный пример URL с параметрами:${NC}"
echo -e "${FULL_WEBHOOK_URL}?click_id=test123&order_number=50&offer_name=TestOffer&order_status=confirmed&user_id=6&revenue=1500&commission=100&uniq_id=uniq3w3w&click_time=2025-10-22%2020:00:00&time_of_order=2025-10-22%2020:01:00"
echo ""
echo -e "${BLUE}Для просмотра логов:${NC}"
echo -e "docker-compose logs -f webhook_receiver"
echo -e "docker-compose logs -f svix_server"
echo ""
echo -e "${GREEN}Секретный токен: ${WEBHOOK_SECRET_TOKEN}${NC}"
echo -e "${GREEN}Сохраните этот URL - используйте его для настройки у партнеров!${NC}"