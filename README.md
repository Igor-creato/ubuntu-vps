# Ubuntu VPS Setup Scripts

Безопасные скрипты для первичной настройки Ubuntu VPS сервера (22.04 / 24.04).

## 🚀 Быстрый старт

### Требования

- Чистая установка Ubuntu 22.04 или 24.04
- Root доступ или sudo права
- SSH ключ, сгенерированный на вашей локальной машине

### Генерация SSH ключа (на вашей машине)

**Перед запуском скрипта** сгенерируйте SSH ключ на вашем компьютере:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

Сохраните ключ (по умолчанию `~/.ssh/id_ed25519`) и запомните путь к публичному ключу (`~/.ssh/id_ed25519.pub`).

### Запуск скрипта

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh)
```

## 📋 Что делает скрипт

Скрипт выполняет следующие действия с подтверждением на каждом шаге:

### 1. **Создание пользователя**
- Запрашивает имя нового административного пользователя
- Создает пользователя с sudo правами
- Настраивает NOPASSWD для sudo

### 2. **Настройка SSH**
- Запрашивает новый SSH порт (по умолчанию 22 → ваш порт)
- Запрашивает публичный SSH ключ (вставить содержимое)
- Отключает вход по паролю для всех пользователей
- Отключает root login через SSH
- Использует **транзакционную миграцию** с rollback при ошибках
- Проверяет новое подключение перед финализацией

### 3. **Обновление системы**
- Обновляет список пакетов
- Устанавливает все доступные обновления
- Безопасное обновление без потери SSH соединения

### 4. **UFW (Firewall)**
- Устанавливает UFW
- Открывает порты: SSH (ваш порт), 80 (HTTP), 443 (HTTPS)
- Включает firewall

### 5. **Fail2ban**
- Устанавливает Fail2ban
- Настраивает защиту SSH (3 попытки → бан на 10 минут)
- Автоматически настраивается на ваш SSH порт

### 6. **Docker и Docker Compose**
- Устанавливает Docker Engine (актуальная версия)
- Устанавливает Docker Compose Plugin
- Устанавливает Docker Compose Standalone
- Добавляет пользователя в группу docker

## 🎯 Интерактивный режим

Скрипт запрашивает подтверждение на каждом шаге:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Шаг [1/6]: Настройка SSH (транзакционная миграция)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Выполнить этот шаг? (Y/n):
```

## 🔐 Безопасность

### SSH Migration (Транзакционная)

Скрипт использует fail-safe подход для миграции SSH:

1. **Staging Phase**: Слушает оба порта (старый + новый)
2. **Verification Phase**: Требует реальное SSH подключение на новый порт
3. **Commit Phase**: Закрывает старый порт только после успешной проверки
4. **Rollback**: Автоматический откат при любой ошибке

### Что проверяет скрипт

- ✅ Валидация имени пользователя (запрещает root)
- ✅ Валидация SSH порта (1-65535)
- ✅ Проверка публичного ключа через ssh-keygen
- ✅ SHA256 проверка всех загружаемых скриптов
- ✅ Compatibility check (Ubuntu 22.04/24.04 only)

### Хранение приватных ключей

⚠️ **ВАЖНО**: Приватный SSH ключ **никогда** не должен покидать вашу локальную машину.

- ✅ Генерируйте ключ на своем компьютере
- ✅ Скрипт запрашивает только **публичный** ключ
- ❌ Никогда не копируйте приватный ключ на сервер

## 📖 Использование

### Автоматическая установка (все компоненты)

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh)
```

### Выборочная установка

```bash
# Только SSH
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh) --ssh

# SSH + Docker
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh) --ssh --docker

# Все кроме Docker
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh) --ssh --ufw --fail2ban
```

### Автоматический режим (без подтверждений)

```bash
VPS_AUTO_CONFIRM=true USERNAME=igor SSH_PORT=2222 \
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh)
```

### Опции командной строки

```
--ssh                 Установка и настройка SSH
--docker              Установка Docker
--ufw                 Установка и настройка UFW
--fail2ban            Установка и настройка Fail2ban
--username NAME       Имя административного пользователя
--ssh-port PORT       Порт SSH (1-65535)
--public-key-file PATH Путь к файлу с публичным ключом
--help, -h            Показать справку
--version             Показать версию
```

## 🔄 После установки

### 1. Проверьте новое SSH подключение

```bash
ssh -p YOUR_PORT username@server_ip
```

### 2. Активируйте Docker для пользователя

```bash
newgrp docker
# или перезайдите в систему
```

### 3. Проверьте Docker

```bash
docker run hello-world
docker compose version
```

### 4. Проверьте UFW

```bash
sudo ufw status verbose
```

### 5. Проверьте Fail2ban

```bash
sudo fail2ban-client status sshd
```

## 🛠️ Отладка

### Логи

Все действия логируются:

```bash
# Основной лог
cat /tmp/ubuntu-setup-*.log

# SSH setup лог
cat /var/log/ubuntu-vps-ssh-setup.log

# Docker install лог
cat /var/log/install-docker.log
```

### SSH не работает после миграции

Если что-то пошло не так, скрипт автоматически откатывает изменения. Но если вы потеряли доступ:

1. Используйте recovery console (VPS provider dashboard)
2. Проверьте backup конфигурации:

```bash
ls -la /var/backups/ubuntu-vps/
```

3. Восстановите из backup:

```bash
sudo cp -r /var/backups/ubuntu-vps/ssh-TIMESTAMP /etc/ssh
sudo systemctl restart ssh
```

## 📦 Структура проекта

```
ubuntu-vps/
├── install.sh              # Главный оркестратор
├── scripts/
│   ├── ssh-setup.sh        # Транзакционная SSH миграция
│   └── install-docker.sh   # Установка Docker
├── tests/
│   ├── test_ssh_setup.sh   # Unit тесты SSH
│   └── test_install.sh     # Integration тесты
└── README.md
```

## 🧪 Тестирование

Скрипты покрыты тестами:

```bash
# Запуск всех тестов
sudo bash tests/run.sh

# Только SSH тесты
sudo bash tests/test_ssh_setup.sh

# Integration тесты
sudo bash tests/test_install.sh
```

## 🤝 Поддержка

- Ubuntu 22.04 LTS ✅
- Ubuntu 24.04 LTS ✅ (основной target)
- Ubuntu 20.04 LTS ⚠️ (базовая поддержка)

## 📜 Лицензия

MIT License

## ⚠️ Дисклеймер

Скрипт изменяет критичные настройки безопасности системы. 

**Рекомендации:**
- Тестируйте на test-сервере перед production
- Делайте snapshot VPS перед запуском
- Сохраните SSH ключи в надежном месте
- Не закрывайте текущую SSH сессию до проверки нового подключения
