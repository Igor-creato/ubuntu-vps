#!/bin/bash

#================================================================================
#
#   Скрипт для безопасной настройки сервера Ubuntu
#
#   Автор:     DevOps Инженер (Gemini)
#   Версия:    1.0
#   Дата:      28.08.2025
#
#   Описание:
#   Этот скрипт автоматизирует первоначальную настройку сервера Ubuntu:
#   - Проверяет версию ОС и права пользователя.
#   - Обновляет систему и устанавливает SSH.
#   - Управляет пользователями с sudo-правами.
#   - Настраивает SSH-ключи.
#   - Меняет стандартный порт SSH.
#   - Устанавливает и настраивает Fail2Ban и UFW.
#   - Отключает аутентификацию по паролю для повышения безопасности.
#
#================================================================================


# --- Глобальные переменные и конфигурация ---

# Прерывать выполнение скрипта при любой ошибке
set -o errexit
set -o pipefail

# Файл для логирования всех операций
LOG_FILE="/var/log/server_setup.log"
# Временный файл для хранения SSH ключа
TMP_KEY_FILE=$(mktemp)


# --- Функции ---

# Функция для логирования сообщений с временной меткой
# Принимает один аргумент: сообщение для записи в лог.
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция для удаления временных файлов при выходе
# Не принимает аргументов.
cleanup() {
    log_message "INFO: Выполняется очистка временных файлов."
    rm -f "$TMP_KEY_FILE"
    log_message "INFO: Очистка завершена."
}

# Устанавливаем перехватчик для вызова функции cleanup при выходе из скрипта
trap cleanup EXIT

# Функция для проверки версии ОС Ubuntu
# Не принимает аргументов. Завершает скрипт, если версия ниже 22.04.
check_os_version() {
    log_message "INFO: Проверка версии операционной системы."
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            # Получаем основную версию (например, 22 из 22.04)
            local version_id
            version_id=$(echo "$VERSION_ID" | cut -d'.' -f1)
            if (( version_id >= 22 )); then
                log_message "SUCCESS: Обнаружена совместимая версия Ubuntu: $VERSION."
            else
                log_message "ERROR: Этот скрипт требует Ubuntu 22.04 или новее. Ваша версия: $VERSION."
                exit 1
            fi
        else
            log_message "ERROR: Этот скрипт предназначен только для Ubuntu."
            exit 1
        fi
    else
        log_message "ERROR: Не удалось определить операционную систему."
        exit 1
    fi
}

# Функция для проверки, запущен ли скрипт от имени root
# Не принимает аргументов. Завершает скрипт, если пользователь не root.
check_root_privileges() {
    log_message "INFO: Проверка прав суперпользователя."
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR: Этот скрипт должен быть запущен с правами root или через sudo."
        exit 1
    fi
    log_message "SUCCESS: Скрипт запущен с правами root."
}

# Функция для обновления системы
# Не принимает аргументов.
update_system() {
    log_message "INFO: Проверка и установка обновлений системы..."
    if apt-get update -y >> "$LOG_FILE" 2>&1; then
        log_message "INFO: Списки пакетов успешно обновлены."
        if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$LOG_FILE" 2>&1; then
            log_message "SUCCESS: Система успешно обновлена."
        else
            log_message "ERROR: Не удалось обновить пакеты."
            exit 1
        fi
    else
        log_message "ERROR: Не удалось обновить списки пакетов (apt-get update)."
        exit 1
    fi
}

# Функция для установки SSH-сервера
# Не принимает аргументов.
install_ssh() {
    log_message "INFO: Проверка и установка SSH-сервера."
    if ! dpkg -l | grep -q "openssh-server"; then
        log_message "INFO: SSH-сервер не найден. Установка..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >> "$LOG_FILE" 2>&1; then
            log_message "SUCCESS: SSH-сервер успешно установлен."
        else
            log_message "ERROR: Не удалось установить openssh-server."
            exit 1
        fi
    else
        log_message "INFO: SSH-сервер уже установлен."
    fi

    # Включаем и запускаем сервис, если он не активен
    if ! systemctl is-active --quiet ssh; then
        log_message "INFO: Запуск сервиса sshd."
        systemctl enable ssh >> "$LOG_FILE" 2>&1
        systemctl start ssh >> "$LOG_FILE" 2>&1
    fi
}

# Функция для выбора или создания пользователя
# Не принимает аргументов. Устанавливает глобальную переменную TARGET_USER.
manage_system_user() {
    log_message "INFO: Поиск пользователей с sudo-правами."
    # Ищем пользователей в группе sudo
    mapfile -t sudo_users < <(getent group sudo | cut -d: -f4 | tr ',' '\n')

    if [ ${#sudo_users[@]} -eq 0 ]; then
        log_message "INFO: Пользователи с sudo-правами не найдены."
        create_new_user
    else
        echo "Найдены следующие пользователи с sudo-правами:"
        local i=1
        for user in "${sudo_users[@]}"; do
            echo "  $i) $user"
            i=$((i+1))
        done
        echo "  $i) Создать нового пользователя"

        local choice
        while true; do
            read -p "Выберите пользователя для настройки или создайте нового [1-$i]: " choice
            if [[ "$choice" -ge 1 && "$choice" -le ${#sudo_users[@]} ]]; then
                TARGET_USER=${sudo_users[$((choice-1))]}
                log_message "INFO: Выбран существующий пользователь: $TARGET_USER."
                break
            elif [[ "$choice" -eq $i ]]; then
                create_new_user
                break
            else
                echo "Ошибка: Неверный выбор. Пожалуйста, введите число от 1 до $i."
            fi
        done
    fi
}

# Функция для создания нового пользователя
# Не принимает аргументов. Устанавливает глобальную переменную TARGET_USER.
create_new_user() {
    log_message "INFO: Создание нового пользователя."
    while true; do
        read -p "Введите имя нового пользователя: " new_user
        # Проверка имени на валидность (только буквы, цифры, дефис, подчеркивание)
        if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
            if id "$new_user" &>/dev/null; then
                log_message "WARNING: Пользователь '$new_user' уже существует."
                echo "Ошибка: Пользователь с таким именем уже существует. Попробуйте другое имя."
            else
                log_message "INFO: Создание пользователя '$new_user'."
                # Создаем пользователя с домашней директорией и оболочкой bash
                if useradd -m -s /bin/bash "$new_user"; then
                    # Устанавливаем пароль
                    echo "Пожалуйста, установите пароль для нового пользователя '$new_user'."
                    passwd "$new_user"
                    # Добавляем пользователя в группу sudo
                    usermod -aG sudo "$new_user"
                    log_message "SUCCESS: Пользователь '$new_user' успешно создан и добавлен в группу sudo."
                    TARGET_USER=$new_user
                    break
                else
                    log_message "ERROR: Не удалось создать пользователя '$new_user'."
                    echo "Ошибка: Не удалось создать пользователя. Проверьте логи."
                    exit 1
                fi
            fi
        else
            echo "Ошибка: Имя пользователя невалидно. Оно должно начинаться с буквы, может содержать строчные буквы, цифры, '_' и '-'."
        fi
    done
}

# Функция для управления SSH-ключами
# Принимает один аргумент: имя целевого пользователя.
manage_ssh_keys() {
    local user=$1
    local user_ssh_dir="/home/$user/.ssh"
    local user_auth_keys="$user_ssh_dir/authorized_keys"
    local root_auth_keys="/root/.ssh/authorized_keys"

    log_message "INFO: Настройка SSH-ключей для пользователя '$user'."
    mkdir -p "$user_ssh_dir"
    touch "$user_auth_keys"

    if [[ -s "$root_auth_keys" ]]; then
        log_message "INFO: Обнаружен файл authorized_keys у пользователя root."
        echo "Обнаружены существующие SSH-ключи у пользователя root. Выберите действие:"
        echo "  1) Перенести ключ от root к пользователю '$user'"
        echo "  2) Добавить новый ключ для пользователя '$user' (старые ключи root будут удалены)"

        local choice
        read -p "Ваш выбор [1-2]: " choice

        case $choice in
            1)
                log_message "INFO: Выбрано перемещение ключа от root к '$user'."
                cat "$root_auth_keys" >> "$user_auth_keys"
                rm -f "$root_auth_keys"
                log_message "SUCCESS: Ключи успешно перенесены к '$user', ключ root удален."
                ;;
            2)
                log_message "INFO: Выбрано добавление нового ключа для '$user'."
                add_new_ssh_key
                # Записываем ключ во временный файл в authorized_keys пользователя
                cat "$TMP_KEY_FILE" >> "$user_auth_keys"
                rm -f "$root_auth_keys"
                log_message "SUCCESS: Новый ключ добавлен для '$user', ключ root удален."
                ;;
            *)
                log_message "ERROR: Неверный выбор. Выход."
                echo "Неверный выбор. Выход."
                exit 1
                ;;
        esac
    else
        log_message "INFO: Ключи у root не найдены. Предлагается добавить новый ключ."
        echo "SSH-ключи у пользователя root не найдены. Необходимо добавить новый ключ."
        add_new_ssh_key
        # Записываем ключ из временного файла в authorized_keys пользователя
        cat "$TMP_KEY_FILE" >> "$user_auth_keys"
        log_message "SUCCESS: Новый ключ успешно добавлен для '$user'."
    fi

    # Устанавливаем правильные права на директорию и файл
    chown -R "$user":"$user" "$user_ssh_dir"
    chmod 700 "$user_ssh_dir"
    chmod 600 "$user_auth_keys"
    log_message "INFO: Установлены корректные права на $user_auth_keys."
}

# Функция для добавления нового многострочного SSH-ключа
# Не принимает аргументов. Записывает ключ во временный файл.
add_new_ssh_key() {
    log_message "INFO: Запрос нового SSH-ключа."
    echo "Вставьте ваш публичный SSH-ключ (например, id_rsa.pub). Нажмите Ctrl+D после вставки ключа."
    # Читаем многострочный ввод и сохраняем во временный файл
    cat > "$TMP_KEY_FILE"
    if [[ ! -s "$TMP_KEY_FILE" ]]; then
        log_message "ERROR: SSH-ключ не был введен. Выход."
        echo "Ошибка: Вы не ввели SSH-ключ. Выход."
        exit 1
    fi
}

# Функция для изменения порта SSH
# Не принимает аргументов. Устанавливает глобальную переменную NEW_SSH_PORT.
configure_ssh_port() {
    log_message "INFO: Настройка порта SSH."
    local ssh_config="/etc/ssh/sshd_config"

    while true; do
        read -p "Введите новый порт для SSH (рекомендуется > 1024): " NEW_SSH_PORT
        # Проверяем, что введено число и оно находится в допустимом диапазоне
        if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ && "$NEW_SSH_PORT" -gt 0 && "$NEW_SSH_PORT" -le 65535 ]]; then
            log_message "INFO: Пользователь ввел порт $NEW_SSH_PORT."
            # Заменяем старый порт на новый. Используем s#...#...# из-за / в пути.
            sed -i.bak "s/^#?Port 22/Port $NEW_SSH_PORT/" "$ssh_config"
            log_message "SUCCESS: Порт в $ssh_config изменен на $NEW_SSH_PORT."
            break
        else
            log_message "WARNING: Пользователь ввел невалидный порт: '$NEW_SSH_PORT'."
            echo "Ошибка: Неверный порт. Введите число от 1 до 65535."
        fi
    done
}

# Функция для установки и настройки Fail2Ban
# Принимает один аргумент: новый порт SSH.
setup_fail2ban() {
    local port=$1
    log_message "INFO: Установка и настройка Fail2Ban."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >> "$LOG_FILE" 2>&1; then
        log_message "SUCCESS: Fail2Ban успешно установлен."
    else
        log_message "ERROR: Не удалось установить Fail2Ban."
        exit 1
    fi

    # Создаем локальный файл конфигурации, чтобы избежать перезаписи при обновлениях
    local jail_local="/etc/fail2ban/jail.local"
    log_message "INFO: Создание конфигурации $jail_local."
    cp /etc/fail2ban/jail.conf "$jail_local"

    # Настраиваем новый порт для секции [sshd]
    log_message "INFO: Настройка порта $port для Fail2Ban."
    sed -i.bak "s/port *= *ssh/port = $port/" "$jail_local"

    # Включаем и перезапускаем сервис
    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl restart fail2ban >> "$LOG_FILE" 2>&1
    log_message "SUCCESS: Fail2Ban настроен и перезапущен."
}

# Функция для настройки файрвола UFW
# Принимает один аргумент: новый порт SSH.
setup_ufw() {
    local new_port=$1
    log_message "INFO: Установка и настройка UFW."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >> "$LOG_FILE" 2>&1; then
        log_message "SUCCESS: UFW успешно установлен."
    else
        log_message "ERROR: Не удалось установить UFW."
        exit 1
    fi

    # Сбрасываем правила на случай, если UFW уже был настроен
    ufw --force reset >> "$LOG_FILE" 2>&1
    # Устанавливаем правила по умолчанию
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1

    # Открываем необходимые порты
    log_message "INFO: Открытие портов в UFW: 22, 80, 443, $new_port."
    ufw allow 22/tcp      # Временный доступ
    ufw allow 80/tcp      # HTTP
    ufw allow 443/tcp     # HTTPS
    ufw allow "$new_port"/tcp # Новый порт SSH
    
    # Включаем UFW
    ufw --force enable >> "$LOG_FILE" 2>&1
    log_message "SUCCESS: UFW включен и настроен."

    echo "======================================================================"
    echo "ПРОВЕРКА SSH СОЕДИНЕНИЯ"
    echo "======================================================================"
    echo "UFW настроен. Порт 22 и новый порт $new_port временно открыты."
    echo "Пожалуйста, откройте НОВЫЙ терминал и попробуйте подключиться:"
    echo
    echo "ssh -p $new_port $TARGET_USER@$(hostname -I | awk '{print $1}')"
    echo
    echo "После успешного входа вернитесь сюда и подтвердите."
    echo "======================================================================"

    local confirmation
    while true; do
        read -p "Удалось ли вам успешно подключиться по новому порту? (y/n): " confirmation
        case $confirmation in
            [Yy]*)
                log_message "INFO: Пользователь подтвердил успешное SSH-соединение."
                # Закрываем старый порт
                ufw delete allow 22/tcp >> "$LOG_FILE" 2>&1
                log_message "INFO: Старый порт SSH (22) закрыт в UFW."

                # Запрещаем вход по паролю
                log_message "INFO: Отключение аутентификации по паролю."
                sed -i.bak 's/^#?PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
                sed -i.bak 's/^#?ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
                sed -i.bak 's/^#?UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

                # Перезагружаем SSH для применения всех изменений
                systemctl restart ssh
                log_message "SUCCESS: Аутентификация по паролю отключена, SSH перезапущен."
                break
                ;;
            [Nn]*)
                log_message "ERROR: Пользователь сообщил о неудачном SSH-соединении. Откат не производится, скрипт завершается."
                echo "Скрипт прерван. Порт 22 остается открытым для отладки. Проверьте логи: $LOG_FILE"
                exit 1
                ;;
            *)
                echo "Пожалуйста, введите 'y' или 'n'."
                ;;
        esac
    done
}


# --- Основной блок выполнения скрипта ---

main() {
    # Создаем/очищаем лог-файл и устанавливаем права
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    log_message "================== ЗАПУСК СКРИПТА НАСТРОЙКИ СЕРВЕРА =================="

    # Шаг 1: Проверка ОС
    check_os_version
    
    # Шаг 2: Проверка прав root
    check_root_privileges
    
    # Шаг 3: Обновление системы
    update_system
    
    # Шаг 4: Установка SSH
    install_ssh
    
    # Шаг 5: Выбор или создание пользователя
    # Глобальная переменная TARGET_USER будет установлена внутри этой функции
    manage_system_user
    
    # Шаг 6: Управление SSH-ключами
    manage_ssh_keys "$TARGET_USER"

    # Шаг 7: Настройка порта SSH
    # Глобальная переменная NEW_SSH_PORT будет установлена внутри этой функции
    configure_ssh_port

    # Шаг 8: Установка и настройка Fail2Ban
    setup_fail2ban "$NEW_SSH_PORT"

    # Шаг 9: Настройка UFW и финальная проверка
    setup_ufw "$NEW_SSH_PORT"
    
    # Шаг 10: Финальное сообщение
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    echo
    log_message "================== НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА =================="
    echo "✅ Все настройки успешно применены!"
    echo "Данные для подключения по SSH:"
    echo "----------------------------------------"
    echo "  Пользователь: $TARGET_USER"
    echo "  IP-адрес:     $server_ip"
    echo "  Порт:         $NEW_SSH_PORT"
    echo "----------------------------------------"
    echo "Пример команды для подключения:"
    echo "ssh -p $NEW_SSH_PORT $TARGET_USER@$server_ip"
    echo
    echo "Лог всех операций сохранен в файле: $LOG_FILE"
    echo "======================================================================"
}

# Вызов основной функции
main

exit 0
