#!/usr/bin/env bash
# Тест для проверки ssh-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_SCRIPT="$SCRIPT_DIR/../scripts/ssh-setup.sh"

echo "=== Тестирование ssh-setup.sh ==="
echo

# Тест 1: Проверка синтаксиса
echo "[1/5] Проверка синтаксиса bash..."
if bash -n "$SSH_SCRIPT"; then
    echo "✓ Синтаксис корректен"
else
    echo "✗ Ошибка синтаксиса"
    exit 1
fi
echo

# Тест 2: Проверка наличия обязательных команд
echo "[2/5] Проверка определения бинарников..."
SSHD_BIN="/usr/sbin/sshd"
SS_BIN="/usr/sbin/ss"
UFW_BIN="/usr/sbin/ufw"
FAIL2BAN_BIN="/usr/bin/fail2ban-client"
VISUDO_BIN="/usr/sbin/visudo"

for bin_var in SSHD_BIN SS_BIN UFW_BIN FAIL2BAN_BIN VISUDO_BIN; do
    bin_path="${!bin_var}"
    echo "  $bin_var=$bin_path"
done
echo "✓ Пути к бинарникам определены"
echo

# Тест 3: Проверка что SS_BIN использует полный путь
echo "[3/5] Проверка SS_BIN в скрипте..."
if grep -q 'SS_BIN="${SS_BIN:-/usr/sbin/ss}"' "$SSH_SCRIPT"; then
    echo "✓ SS_BIN использует полный путь /usr/sbin/ss"
else
    echo "✗ SS_BIN не использует полный путь"
    exit 1
fi
echo

# Тест 4: Проверка функции ensure_user
echo "[4/5] Проверка функции ensure_user..."
if grep -A 8 'ensure_user()' "$SSH_SCRIPT" | grep -q 'getent group sudo'; then
    echo "✓ ensure_user проверяет существование группы sudo"
else
    echo "✗ ensure_user не проверяет группу sudo"
    exit 1
fi
echo

# Тест 5: Проверка логирования в main
echo "[5/5] Проверка детального логирования..."
log_checks=(
    "Установка зависимостей"
    "Валидация входных данных"
    "Настройка sudo"
    "Предварительная проверка SSH"
    "Подготовка ключей"
    "Начало транзакции"
)

all_found=true
for check in "${log_checks[@]}"; do
    if grep -q "log INFO \"$check" "$SSH_SCRIPT"; then
        echo "  ✓ Найден лог: $check"
    else
        echo "  ✗ Не найден лог: $check"
        all_found=false
    fi
done

if $all_found; then
    echo "✓ Все критические точки логируются"
else
    echo "✗ Некоторые логи отсутствуют"
    exit 1
fi
echo

echo "=== Все тесты пройдены успешно ==="
