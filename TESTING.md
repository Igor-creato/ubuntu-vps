# Инструкция по тестированию

## Исправленные проблемы

1. **Команда `ss` не найдена** - исправлено на `/usr/sbin/ss`
2. **Группа `sudo` не существует** - добавлена проверка перед `usermod`
3. **Зависание при `curl | bash` в install.sh** - добавлена проверка stdin (`-t 0`) в `prompt_ssh_inputs`, `confirm_step`, `confirm_execution`
4. **Зависание при `curl | bash` в ssh-setup.sh** - добавлена проверка stdin (`-t 0`) в `prompt_missing_inputs`
5. **Отсутствие детального логирования** - добавлены INFO логи на каждом этапе

## Локальное тестирование

```bash
# Тест SSH setup
bash tests/test-ssh-setup.sh

# Тест install.sh
bash tests/test-install.sh
```

**Результат:**
- ✅ Все 5 тестов ssh-setup.sh пройдены
- ✅ Все 3 теста install.sh пройдены

## Тестирование на сервере

### 1. Подождите обновления GitHub CDN (2-3 минуты)

GitHub кеширует файлы на CDN. Подождите несколько минут после push.

### 2. Запустите скрипт

```bash
curl -fsSL https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh | sudo bash
```

### 3. Ожидаемый вывод

```
[INFO]    Запуск bash v3.0.1
[INFO]    Логи: /tmp/ubuntu-setup-YYYYMMDD-HHMMSS.log
[INFO]    Опции не заданы — будут выполнены все шаги.
[INFO]    Используется имя пользователя по умолчанию: admin
[INFO]    Используется SSH-порт по умолчанию: 2222
[INFO]    Автоматическое подтверждение выполнения (pipe mode)
[INFO]    План выполнения (шагов: 6):
[INFO]      - Настройка SSH (транзакционная миграция)
[INFO]      - Проверка SSH подключения
[INFO]      - Обновление системы
[INFO]      - Настройка UFW
[INFO]      - Настройка Fail2ban
[INFO]      - Установка Docker

[INFO]    Установка зависимостей...
[INFO]    Валидация входных данных...
[INFO]    Настройка sudo для пользователя: admin
[INFO]    Предварительная проверка SSH...
[INFO]    Подготовка SSH ключей...
[INFO]    Начало SSH транзакции...
```

### 4. Что проверять

- ✅ Скрипт не зависает на `read`
- ✅ Используются значения по умолчанию (admin, 2222)
- ✅ Детальные логи на каждом этапе
- ✅ Команда `/usr/sbin/ss` работает
- ✅ UFW устанавливается и проверяется
- ✅ Нет ошибок "Ошибка на строке 178"

### 5. Если что-то пошло не так

Проверьте полный лог:

```bash
cat /tmp/ubuntu-setup-*.log
```

## Альтернативный метод (если CDN не обновился)

Запустите напрямую с GitHub, обходя кеш:

```bash
curl -fsSL "https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh?$(date +%s)" | sudo bash
```

Или клонируйте репозиторий:

```bash
git clone https://github.com/Igor-creato/ubuntu-vps.git
cd ubuntu-vps
sudo bash install.sh
```

## Проверка после установки

```bash
# Проверка SSH
ss -tlnp | grep sshd

# Проверка UFW
sudo ufw status verbose

# Проверка Fail2ban
sudo systemctl status fail2ban

# Проверка Docker
docker --version
docker compose version
```
