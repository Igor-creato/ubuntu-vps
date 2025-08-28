#!/bin/bash
# Скрипт настройки безопасного SSH доступа на Ubuntu 22.04+
# Соответствует текущим стандартам безопасности и рекомендациям Ubuntu
# Автор: DevOps Engineer
# Дата: 2023-10-15

# Настройка логирования и обработки ошибок
LOG_FILE="/var/log/ssh_secure_setup_$(date +%Y%m%d%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
set -o errexit          # Выход при ошибке команды
set -o nounset          # Выход при использовании необъявленной переменной
set -o pipefail         # Отслеживание ошибок в конвейерах

# Функция для записи логов с временной меткой
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция для обработки ошибок
error_exit() {
    log "ОШИБКА: $1"
    exit 1
}

# 1. Проверка ОС (только Ubuntu 22.04 или новее)
check_os() {
    log "Проверка версии ОС..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            error_exit "Этот скрипт поддерживает только Ubuntu. Обнаружена: $ID"
        fi
        
        # Извлекаем основную версию (например, 22 из 22.04)
        major_version=$(echo "$VERSION_ID" | cut -d. -f1)
        
        if [ "$major_version" -lt 22 ]; then
            error_exit "Требуется Ubuntu 22.04 или новее. Обнаружена версия: $VERSION_ID"
        fi
        log "Операционная система: $PRETTY_NAME (поддерживается)"
    else
        error_exit "Не удалось определить версию ОС. Файл /etc/os-release отсутствует."
    fi
}

# 2. Проверка прав root
check_root() {
    log "Проверка прав суперпользователя..."
    if [ "$EUID" -ne 0 ]; then
        error_exit "Этот скрипт должен быть запущен с правами root. Используйте sudo или войдите как root."
    fi
    log "Запущено от имени root (EUID=$EUID)"
}

# 3. Обновление системы
update_system() {
    log "Обновление системы..."
    log "Выполнение apt update..."
    if ! apt update; then
        error_exit "Не удалось обновить список пакетов"
    fi
    
    # Проверяем, есть ли обновления
    if apt list --upgradable 2>/dev/null | grep -v "Listing..." | grep -q "upgradable"; then
        log "Обнаружены доступные обновления. Установка..."
        if ! apt upgrade -y; then
            error_exit "Не удалось установить обновления системы"
        fi
        log "Система успешно обновлена"
    else
        log "Обновления не требуются"
    fi
}

# 4. Установка SSH сервера
install_ssh() {
    log "Установка и настройка SSH сервера..."
    if ! dpkg -l | grep -q "openssh-server"; then
        log "Установка openssh-server..."
        if ! apt install -y openssh-server; then
            error_exit "Не удалось установить openssh-server"
        fi
        log "openssh-server успешно установлен"
    else
        log "openssh-server уже установлен"
    fi
    
    # Проверяем статус службы
    if ! systemctl is-active --quiet ssh; then
        log "Запуск службы SSH..."
        if ! systemctl start ssh; then
            error_exit "Не удалось запустить службу SSH"
        fi
        log "Служба SSH запущена"
    fi
    
    # Включаем автозапуск
    if ! systemctl is-enabled --quiet ssh; then
        if ! systemctl enable ssh; then
            error_exit "Не удалось настроить автозапуск SSH"
        fi
        log "Автозапуск SSH настроен"
    fi
}

# 5. Управление пользователями с правами sudo
manage_sudo_users() {
    log "Поиск пользователей с правами sudo..."
    
    # Получаем список пользователей в группе sudo
    sudo_users=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    
    if [ -z "$sudo_users" ]; then
        log "Пользователи с правами sudo не найдены"
    else
        log "Найдены пользователи с правами sudo:"
        IFS=$'\n' read -rd '' -a users_array <<< "$sudo_users"
        for i in "${!users_array[@]}"; do
            echo "$((i+1))) ${users_array[$i]}"
        done
    fi
    
    # Предлагаем выбрать пользователя или создать нового
    while true; do
        echo ""
        echo "Выберите пользователя для настройки SSH:"
        if [ -n "$sudo_users" ]; then
            for i in "${!users_array[@]}"; do
                echo "$((i+1))) ${users_array[$i]}"
            done
        fi
        last_option=$(( ${#users_array[@]} + 1 ))
        echo "$last_option) Создать нового пользователя"
        
        read -p "Введите номер выбора: " choice
        
        # Проверяем валидность выбора
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$last_option" ]; then
            log "Неверный выбор. Пожалуйста, введите число от 1 до $last_option"
            continue
        fi
        
        if [ "$choice" -eq "$last_option" ]; then
            # Создание нового пользователя
            while true; do
                read -p "Введите имя нового пользователя: " new_user
                
                # Проверка валидности имени пользователя
                if [[ ! "$new_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                    log "Ошибка: Недопустимое имя пользователя. Имя должно начинаться с буквы, содержать только строчные буквы, цифры, дефис и подчеркивание, длина не более 32 символов."
                    continue
                fi
                
                # Проверяем, существует ли пользователь
                if id "$new_user" &>/dev/null; then
                    log "Ошибка: Пользователь $new_user уже существует."
                    continue
                fi
                
                # Создаем пользователя
                if ! adduser --disabled-password --gecos "" "$new_user"; then
                    log "Ошибка: Не удалось создать пользователя $new_user"
                    continue
                fi
                
                # Добавляем в группу sudo
                if ! usermod -aG sudo "$new_user"; then
                    log "Ошибка: Не удалось добавить пользователя $new_user в группу sudo"
                    # Удаляем пользователя при ошибке
                    deluser "$new_user" &>/dev/null
                    continue
                fi
                
                log "Пользователь $new_user успешно создан и добавлен в группу sudo"
                SELECTED_USER="$new_user"
                break
            done
            break
        else
            # Выбор существующего пользователя
            SELECTED_USER="${users_array[$((choice-1))]}"
            log "Выбран пользователь: $SELECTED_USER"
            break
        fi
    done
}

# 6. Обработка SSH ключей
handle_ssh_keys() {
    log "Проверка наличия SSH ключей у root..."
    ROOT_SSH_DIR="/root/.ssh"
    ROOT_AUTHORIZED_KEYS="$ROOT_SSH_DIR/authorized_keys"
    
    # Создаем .ssh директорию для root, если не существует
    if [ ! -d "$ROOT_SSH_DIR" ]; then
        mkdir -p "$ROOT_SSH_DIR"
        chmod 700 "$ROOT_SSH_DIR"
    fi
    
    if [ -f "$ROOT_AUTHORIZED_KEYS" ] && [ -s "$ROOT_AUTHORIZED_KEYS" ]; then
        log "Обнаружены SSH ключи у пользователя root"
        log "Содержимое authorized_keys:"
        cat "$ROOT_AUTHORIZED_KEYS"
        
        # Предлагаем варианты действий
        while true; do
            echo ""
            echo "Выберите действие с SSH ключами:"
            echo "1) Перенести ключи от root к пользователю $SELECTED_USER"
            echo "2) Добавить новый SSH ключ (многострочный ввод)"
            
            read -p "Введите номер выбора: " key_choice
            
            if [[ ! "$key_choice" =~ ^[1-2]$ ]]; then
                log "Неверный выбор. Пожалуйста, введите 1 или 2"
                continue
            fi
            
            if [ "$key_choice" -eq 1 ]; then
                # Перенос ключей от root к пользователю
                log "Перенос SSH ключей к пользователю $SELECTED_USER..."
                
                USER_HOME=$(eval echo ~"$SELECTED_USER")
                USER_SSH_DIR="$USER_HOME/.ssh"
                USER_AUTHORIZED_KEYS="$USER_SSH_DIR/authorized_keys"
                
                # Создаем директорию .ssh для пользователя
                if [ ! -d "$USER_SSH_DIR" ]; then
                    mkdir -p "$USER_SSH_DIR"
                    chmod 700 "$USER_SSH_DIR"
                    chown "$SELECTED_USER:$SELECTED_USER" "$USER_SSH_DIR"
                fi
                
                # Копируем ключи
                cat "$ROOT_AUTHORIZED_KEYS" >> "$USER_AUTHORIZED_KEYS"
                chmod 600 "$USER_AUTHORIZED_KEYS"
                chown "$SELECTED_USER:$SELECTED_USER" "$USER_AUTHORIZED_KEYS"
                
                log "SSH ключи успешно перенесены к пользователю $SELECTED_USER"
                
                # Удаляем ключи у root
                echo "" > "$ROOT_AUTHORIZED_KEYS"
                log "Ключи удалены у пользователя root"
                break
            else
                # Добавление нового ключа
                log "Добавление нового SSH ключа для пользователя $SELECTED_USER..."
                
                USER_HOME=$(eval echo ~"$SELECTED_USER")
                USER_SSH_DIR="$USER_HOME/.ssh"
                USER_AUTHORIZED_KEYS="$USER_SSH_DIR/authorized_keys"
                
                # Создаем директорию .ssh для пользователя
                if [ ! -d "$USER_SSH_DIR" ]; then
                    mkdir -p "$USER_SSH_DIR"
                    chmod 700 "$USER_SSH_DIR"
                    chown "$SELECTED_USER:$SELECTED_USER" "$USER_SSH_DIR"
                fi
                
                # Многострочный ввод ключа
                echo "Введите ваш публичный SSH ключ (вставьте содержимое файла .pub)."
                echo "Завершите ввод, нажав Ctrl+D на новой строке."
                echo "Пример начала ключа: ssh-rsa AAAAB3NzaC1yc2E..."
                
                # Создаем временный файл для ключа
                TEMP_KEY="/tmp/ssh_key_$$"
                cat > "$TEMP_KEY"
                
                # Проверяем, что файл не пустой
                if [ ! -s "$TEMP_KEY" ]; then
                    log "Ошибка: Введенный ключ пустой"
                    rm -f "$TEMP_KEY"
                    continue
                fi
                
                # Проверяем формат ключа (упрощенная проверка)
                if ! grep -qE '^ssh-(rsa|ed25519|ecdsa) ' "$TEMP_KEY"; then
                    log "Ошибка: Неверный формат SSH ключа. Должен начинаться с ssh-rsa, ssh-ed25519 или ssh-ecdsa"
                    rm -f "$TEMP_KEY"
                    continue
                fi
                
                # Добавляем ключ
                cat "$TEMP_KEY" >> "$USER_AUTHORIZED_KEYS"
                chmod 600 "$USER_AUTHORIZED_KEYS"
                chown "$SELECTED_USER:$SELECTED_USER" "$USER_AUTHORIZED_KEYS"
                
                log "SSH ключ успешно добавлен для пользователя $SELECTED_USER"
                rm -f "$TEMP_KEY"
                
                # Удаляем ключи у root
                echo "" > "$ROOT_AUTHORIZED_KEYS"
                log "Ключи удалены у пользователя root"
                break
            fi
        done
    else
        log "SSH ключи у пользователя root не обнаружены"
        
        # Добавление нового ключа
        log "Добавление SSH ключа для пользователя $SELECTED_USER..."
        
        USER_HOME=$(eval echo ~"$SELECTED_USER")
        USER_SSH_DIR="$USER_HOME/.ssh"
        USER_AUTHORIZED_KEYS="$USER_SSH_DIR/authorized_keys"
        
        # Создаем директорию .ssh для пользователя
        if [ ! -d "$USER_SSH_DIR" ]; then
            mkdir -p "$USER_SSH_DIR"
            chmod 700 "$USER_SSH_DIR"
            chown "$SELECTED_USER:$SELECTED_USER" "$USER_SSH_DIR"
        fi
        
        # Многострочный ввод ключа
        echo "Введите ваш публичный SSH ключ (вставьте содержимое файла .pub)."
        echo "Завершите ввод, нажав Ctrl+D на новой строке."
        echo "Пример начала ключа: ssh-rsa AAAAB3NzaC1yc2E..."
        
        # Создаем временный файл для ключа
        TEMP_KEY="/tmp/ssh_key_$$"
        cat > "$TEMP_KEY"
        
        # Проверяем, что файл не пустой
        if [ ! -s "$TEMP_KEY" ]; then
            error_exit "Ошибка: Введенный ключ пустой"
        fi
        
        # Проверяем формат ключа (упрощенная проверка)
        if ! grep -qE '^ssh-(rsa|ed25519|ecdsa) ' "$TEMP_KEY"; then
            error_exit "Ошибка: Неверный формат SSH ключа. Должен начинаться с ssh-rsa, ssh-ed25519 или ssh-ecdsa"
        fi
        
        # Добавляем ключ
        cat "$TEMP_KEY" >> "$USER_AUTHORIZED_KEYS"
        chmod 600 "$USER_AUTHORIZED_KEYS"
        chown "$SELECTED_USER:$SELECTED_USER" "$USER_AUTHORIZED_KEYS"
        
        log "SSH ключ успешно добавлен для пользователя $SELECTED_USER"
        rm -f "$TEMP_KEY"
    fi
}

# 7. Изменение стандартного порта SSH
change_ssh_port() {
    log "Настройка пользовательского порта SSH..."
    
    # Получаем текущий порт из конфигурации
    CURRENT_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config | head -1 | awk '{print $2}' 2>/dev/null)
    if [ -z "$CURRENT_PORT" ]; then
        CURRENT_PORT=22  # Значение по умолчанию, если не указано
    fi
    
    log "Текущий порт SSH: $CURRENT_PORT"
    
    # Запрашиваем новый порт у пользователя
    while true; do
        read -p "Введите новый порт SSH (1024-65535, кроме $CURRENT_PORT): " NEW_PORT
        
        # Проверка валидности порта
        if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]]; then
            log "Ошибка: Порт должен быть числом"
            continue
        fi
        
        if [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
            log "Ошибка: Порт должен быть в диапазоне 1024-65535 (зарегистрированные порты)"
            continue
        fi
        
        if [ "$NEW_PORT" -eq "$CURRENT_PORT" ]; then
            log "Ошибка: Указан текущий порт. Пожалуйста, укажите другой порт"
            continue
        fi
        
        # Проверяем, не занят ли порт
        if ss -tuln | grep -q ":$NEW_PORT "; then
            log "Ошибка: Порт $NEW_PORT уже используется. Пожалуйста, укажите другой порт"
            continue
        fi
        
        log "Выбран порт: $NEW_PORT"
        break
    done
    
    # Обновляем конфигурацию SSH
    log "Обновление конфигурации SSH..."
    
    # Добавляем новый порт в конфигурацию (оставляем текущий порт активным для тестирования)
    if ! grep -q "^Port $NEW_PORT" /etc/ssh/sshd_config; then
        echo "Port $NEW_PORT" >> /etc/ssh/sshd_config
        log "Добавлен новый порт $NEW_PORT в /etc/ssh/sshd_config"
    else
        log "Порт $NEW_PORT уже указан в /etc/ssh/sshd_config"
    fi
    
    # Перезагружаем SSH для применения изменений
    log "Перезагрузка службы SSH..."
    if ! systemctl reload ssh; then
        error_exit "Не удалось перезагрузить службу SSH. Проверьте конфигурацию."
    fi
    
    SELECTED_PORT="$NEW_PORT"
}

# 8. Установка и настройка fail2ban
setup_fail2ban() {
    log "Установка и настройка Fail2ban..."
    
    # Установка Fail2ban
    if ! dpkg -l | grep -q "fail2ban"; then
        log "Установка Fail2ban..."
        if ! apt install -y fail2ban; then
            error_exit "Не удалось установить Fail2ban"
        fi
        log "Fail2ban успешно установлен"
    else
        log "Fail2ban уже установлен"
    fi
    
    # Создаем локальную конфигурацию
    log "Настройка Fail2ban для порта $SELECTED_PORT..."
    FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"
    
    # Создаем файл конфигурации, если не существует
    if [ ! -f "$FAIL2BAN_CONFIG" ]; then
        echo "[sshd]" > "$FAIL2BAN_CONFIG"
        echo "enabled = true" >> "$FAIL2BAN_CONFIG"
        echo "port = $SELECTED_PORT" >> "$FAIL2BAN_CONFIG"
        echo "filter = sshd" >> "$FAIL2BAN_CONFIG"
        echo "logpath = /var/log/auth.log" >> "$FAIL2BAN_CONFIG"
        echo "maxretry = 3" >> "$FAIL2BAN_CONFIG"
        echo "bantime = 1h" >> "$FAIL2BAN_CONFIG"
        log "Создан новый конфигурационный файл Fail2ban: $FAIL2BAN_CONFIG"
    else
        # Проверяем, есть ли секция [sshd]
        if ! grep -q "^\[sshd\]" "$FAIL2BAN_CONFIG"; then
            echo "" >> "$FAIL2BAN_CONFIG"
            echo "[sshd]" >> "$FAIL2BAN_CONFIG"
            log "Добавлена секция [sshd] в $FAIL2BAN_CONFIG"
        fi
        
        # Обновляем параметры для [sshd]
        sed -i "/^\[sshd\]/,/^\[/{ 
            /port =/c port = $SELECTED_PORT
            /enabled =/c enabled = true
        }" "$FAIL2BAN_CONFIG"
        
        # Если параметры не найдены, добавляем их
        if ! grep -A 5 "^\[sshd\]" "$FAIL2BAN_CONFIG" | grep -q "port ="; then
            sed -i "/^\[sshd\]/a port = $SELECTED_PORT" "$FAIL2BAN_CONFIG"
        fi
        if ! grep -A 5 "^\[sshd\]" "$FAIL2BAN_CONFIG" | grep -q "enabled ="; then
            sed -i "/^\[sshd\]/a enabled = true" "$FAIL2BAN_CONFIG"
        fi
    fi
    
    # Перезапускаем Fail2ban
    log "Перезапуск службы Fail2ban..."
    if ! systemctl restart fail2ban; then
        error_exit "Не удалось перезапустить Fail2ban"
    fi
    
    # Проверяем статус
    if ! systemctl is-active --quiet fail2ban; then
        error_exit "Служба Fail2ban не активна после перезапуска"
    fi
    
    log "Fail2ban успешно настроен для защиты SSH на порту $SELECTED_PORT"
}

# 9. Настройка UFW
configure_ufw() {
    log "Настройка брандмауэра UFW..."
    
    # Установка UFW, если не установлен
    if ! dpkg -l | grep -q "ufw"; then
        log "Установка UFW..."
        if ! apt install -y ufw; then
            error_exit "Не удалось установить UFW"
        fi
        log "UFW успешно установлен"
    fi
    
    # Разрешаем необходимые порты
    log "Разрешение портов в UFW..."
    
    # Проверяем, разрешен ли SSH (OpenSSH profile)
    if ! ufw status | grep -q "OpenSSH"; then
        if ! ufw allow OpenSSH; then
            error_exit "Не удалось разрешить SSH через UFW"
        fi
        log "Разрешен доступ через OpenSSH profile"
    else
        log "OpenSSH profile уже разрешен в UFW"
    fi
    
    # Разрешаем HTTP и HTTPS
    if ! ufw status | grep -q "80/tcp"; then
        if ! ufw allow 80/tcp; then
            error_exit "Не удалось разрешить порт 80 (HTTP)"
        fi
        log "Разрешен порт 80 (HTTP)"
    fi
    
    if ! ufw status | grep -q "443/tcp"; then
        if ! ufw allow 443/tcp; then
            error_exit "Не удалось разрешить порт 443 (HTTPS)"
        fi
        log "Разрешен порт 443 (HTTPS)"
    fi
    
    # Разрешаем пользовательский SSH порт
    if ! ufw status | grep -q "$SELECTED_PORT/tcp"; then
        if ! ufw allow "$SELECTED_PORT"/tcp; then
            error_exit "Не удалось разрешить порт $SELECTED_PORT"
        fi
        log "Разрешен порт $SELECTED_PORT для SSH"
    else
        log "Порт $SELECTED_PORT уже разрешен в UFW"
    fi
    
    # Включаем UFW, если не включен
    if ! ufw status | grep -q "Status: active"; then
        log "Включение UFW..."
        echo "y" | ufw enable || error_exit "Не удалось включить UFW"
        log "UFW успешно включен"
    else
        log "UFW уже активен"
    fi
    
    # Проверка статуса
    log "Текущие правила UFW:"
    ufw status verbose
    
    # Запрашиваем подтверждение у пользователя
    log "Пожалуйста, проверьте подключение к серверу через новый порт $SELECTED_PORT"
    echo ""
    echo "ВАЖНО: Откройте новое окно терминала и проверьте подключение:"
    echo "ssh -p $SELECTED_PORT $SELECTED_USER@$(hostname -I | awk '{print $1}')"
    echo ""
    
    while true; do
        read -p "Работает ли подключение через новый порт $SELECTED_PORT? (y/n): " test_result
        
        if [[ ! "$test_result" =~ ^[yYnN]$ ]]; then
            log "Неверный ввод. Пожалуйста, введите y или n"
            continue
        fi
        
        if [[ "$test_result" =~ ^[nN]$ ]]; then
            error_exit "Подключение через новый порт не работает. Прерываем выполнение скрипта."
        fi
        
        break
    done
    
    log "Подключение через порт $SELECTED_PORT подтверждено"
    
    # Отключаем парольную аутентификацию и закрываем стандартный порт 22
    log "Усиление безопасности SSH..."
    
    # Обновляем конфигурацию SSH
    SSH_CONFIG="/etc/ssh/sshd_config"
    
    # Отключаем вход под root
    if grep -q "^#PermitRootLogin" "$SSH_CONFIG"; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    elif grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    else
        echo "PermitRootLogin no" >> "$SSH_CONFIG"
    fi
    
    # Отключаем парольную аутентификацию
    if grep -q "^#PasswordAuthentication" "$SSH_CONFIG"; then
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    elif grep -q "^PasswordAuthentication" "$SSH_CONFIG"; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    else
        echo "PasswordAuthentication no" >> "$SSH_CONFIG"
    fi
    
    # Удаляем стандартный порт 22 из конфигурации
    sed -i '/^Port 22/d' "$SSH_CONFIG"
    
    # Перезагружаем SSH
    log "Применение окончательных настроек SSH..."
    if ! systemctl reload ssh; then
        error_exit "Не удалось применить окончательные настройки SSH"
    fi
    
    # Закрываем порт 22 в UFW
    log "Закрытие стандартного порта 22 в UFW..."
    if ufw status | grep -q "22/tcp"; then
        if ! ufw delete allow 22/tcp; then
            error_exit "Не удалось закрыть порт 22 в UFW"
        fi
        log "Порт 22 успешно закрыт в UFW"
    else
        log "Порт 22 уже закрыт в UFW"
    fi
    
    # Проверяем статус
    log "Окончательные правила UFW:"
    ufw status verbose
}

# Основная функция выполнения
main() {
    log "=== Начало настройки безопасного SSH доступа ==="
    
    # Выполняем все шаги
    check_os
    check_root
    update_system
    install_ssh
    manage_sudo_users
    handle_ssh_keys
    change_ssh_port
    setup_fail2ban
    configure_ufw
    
    # Получаем публичный IP (если доступен)
    PUBLIC_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    
    # Финальное сообщение
    log "=== Настройка успешно завершена! ==="
    echo ""
    echo "##################################################"
    echo "#  Настройка безопасности SSH завершена успешно!  #"
    echo "##################################################"
    echo ""
    echo "Для подключения используйте:"
    echo "ssh -p $SELECTED_PORT $SELECTED_USER@$PUBLIC_IP"
    echo ""
    echo "Рекомендуемые параметры безопасности:"
    echo "- Отключен вход под root [[20]]"
    echo "- Отключена аутентификация по паролю, используется только ключ [[21]]"
    echo "- Используется нестандартный порт SSH ($SELECTED_PORT) для снижения риска атак [[23]]"
    echo "- Настроен Fail2ban для защиты от брутфорса [[18]]"
    echo "- Настроен брандмауэр UFW с минимально необходимыми правилами [[27]]"
    echo ""
    log "Настройка безопасности SSH завершена успешно"
    
    # Удаляем временные файлы (если остались)
    rm -f /tmp/ssh_key_* 2>/dev/null
    
    log "=== Завершение работы скрипта ==="
}

# Запуск основной функции
main
