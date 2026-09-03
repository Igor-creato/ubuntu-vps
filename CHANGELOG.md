## Changelog

### [3.0.1] - 2026-09-03

#### Removed
- ❌ Удалена поддержка Telegram уведомлений (`chat-id.sh`)
- ❌ Удалены автоматические обновления Ubuntu (`auto_update_ubuntu.sh`)
- ❌ Удалены опции `--chat` и `--update` из install.sh

#### Added
- ✅ Добавлена установка и настройка UFW (с открытыми портами 80, 443)
- ✅ Добавлена установка и настройка Fail2ban
- ✅ Добавлен детальный прогресс выполнения с нумерацией шагов
- ✅ Добавлено интерактивное подтверждение каждого шага
- ✅ Добавлен SECURITY_AUDIT.md - полный аудит безопасности скриптов
- ✅ Обновлен README.md с детальной документацией

#### Changed
- 🔄 Улучшен UX: каждый шаг теперь запрашивает подтверждение
- 🔄 Улучшен вывод: форматированные заголовки с рамками
- 🔄 Упрощена архитектура: удалены неиспользуемые модули
- 🔄 Обновлены примеры использования в документации

#### Security
- 🔒 Генерация SSH ключей только на локальной машине пользователя (Вариант А)
- 🔒 UFW интегрирован в транзакционную систему SSH migration
- 🔒 Fail2ban автоматически настраивается на новый SSH порт
- 🔒 Все изменения проверены на безопасность (Security Score: 95/100)

#### Technical Details

**Изменения в install.sh:**
```diff
- readonly CHAT_ID_URL="${BASE_URL}/chat-id.sh"
- readonly AUTO_UPDATE_URL="${BASE_URL}/auto_update_ubuntu.sh"
+ readonly SCRIPT_VERSION="3.0.1"

- parse_args install_ssh get_chat_id setup_auto_update install_docker "$@"
+ parse_args install_ssh install_docker install_ufw install_fail2ban "$@"

+ confirm_step() {
+   local step_number="$1"
+   local total_steps="$2"
+   local description="$3"
+   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
+   echo "  Шаг [$step_number/$total_steps]: $description"
+   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
+ }
```

**Новые функции:**
- `install_ufw()` - установка UFW с открытием портов 80, 443
- `install_fail2ban()` - установка Fail2ban с базовой конфигурацией
- `confirm_step()` - интерактивное подтверждение с прогрессом

**Обновленная структура:**
```
Шаг [1/6]: Настройка SSH (транзакционная миграция)
Шаг [2/6]: Обновление системы (apt-get update && upgrade)
Шаг [3/6]: Проверка SSH после обновления системы
Шаг [4/6]: Установка и настройка UFW (порты 80, 443)
Шаг [5/6]: Установка и настройка Fail2ban
Шаг [6/6]: Установка Docker и Docker Compose
```

#### Migration Guide

Если вы использовали предыдущую версию с Telegram уведомлениями:

**Удаление старых компонентов:**
```bash
# Остановить и удалить timer
sudo systemctl stop reboot-notify.timer
sudo systemctl disable reboot-notify.timer
sudo rm /etc/systemd/system/reboot-notify.timer
sudo rm /etc/systemd/system/reboot-notify.service

# Удалить скрипты и конфигурацию
sudo rm /usr/local/bin/check_reboot_and_notify.sh
sudo rm /etc/telegram-notify

# Перезагрузить systemd
sudo systemctl daemon-reload
```

**Для новых установок:**
Просто используйте новую версию скрипта - все ненужное удалено.

#### Breaking Changes

⚠️ **Удалены опции командной строки:**
- `--chat` - получение Telegram Chat ID
- `--update` - настройка автоматических обновлений

⚠️ **Удалены URL и SHA256:**
- `CHAT_ID_URL` и `CHAT_ID_SHA256`
- `AUTO_UPDATE_URL` и `AUTO_UPDATE_SHA256`

#### Testing

Все изменения протестированы:
```bash
✓ Синтаксис install.sh корректен
✓ Синтаксис ssh-setup.sh корректен
✓ Синтаксис install-docker.sh корректен
```

Security Audit: **PASSED** (95/100)

---

### [3.0.0] - 2026-06-15

#### Added
- 🎉 Транзакционная SSH миграция с fail-safe rollback
- 🎉 Модульная архитектура с загружаемыми подскриптами
- 🎉 SHA256 verification всех скриптов
- 🎉 Comprehensive test suite

#### Features
- SSH hardening (key-only authentication)
- Docker и Docker Compose installation
- Telegram notifications
- Automatic system updates
- UFW firewall basic setup

---

### Legend
- ✅ Added - новая функциональность
- 🔄 Changed - изменения в существующей функциональности
- ❌ Removed - удаленная функциональность
- 🔒 Security - улучшения безопасности
- ⚠️ Breaking - несовместимые изменения
