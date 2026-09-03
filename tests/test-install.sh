#!/usr/bin/env bash
# Тест для проверки install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/../install.sh"

echo "=== Тестирование install.sh ==="
echo

# Тест 1: Проверка синтаксиса
echo "[1/3] Проверка синтаксиса bash..."
if bash -n "$INSTALL_SCRIPT"; then
    echo "✓ Синтаксис корректен"
else
    echo "✗ Ошибка синтаксиса"
    exit 1
fi
echo

# Тест 2: Проверка обработки pipe mode в prompt_ssh_inputs
echo "[2/3] Проверка pipe mode в prompt_ssh_inputs..."
if grep -A 5 'prompt_ssh_inputs()' "$INSTALL_SCRIPT" | grep -q '\-t 0'; then
    echo "✓ prompt_ssh_inputs поддерживает pipe mode"
else
    echo "✗ prompt_ssh_inputs не проверяет stdin"
    exit 1
fi
echo

# Тест 3: Проверка обработки pipe mode в confirm функциях
echo "[3/3] Проверка pipe mode в confirm функциях..."
confirm_checks=0
if grep -A 10 'confirm_step()' "$INSTALL_SCRIPT" | grep -q '\-t 0'; then
    echo "  ✓ confirm_step поддерживает pipe mode"
    confirm_checks=$((confirm_checks + 1))
else
    echo "  ✗ confirm_step не проверяет stdin"
fi

if grep -A 10 'confirm_execution()' "$INSTALL_SCRIPT" | grep -q '\-t 0'; then
    echo "  ✓ confirm_execution поддерживает pipe mode"
    confirm_checks=$((confirm_checks + 1))
else
    echo "  ✗ confirm_execution не проверяет stdin"
fi

if [[ $confirm_checks -eq 2 ]]; then
    echo "✓ Все confirm функции поддерживают pipe mode"
else
    echo "✗ Некоторые confirm функции не поддерживают pipe mode"
    exit 1
fi
echo

echo "=== Все тесты пройдены успешно ==="
