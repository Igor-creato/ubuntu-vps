#!/bin/bash

LOG_FILE="/var/log/system_setup.log"
TEMP_FILES=()

# Функция логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция обработки ошибок
error_exit() {
    log "ОШИБКА: $1"
    exit 1
}

# Проверка ОС
check_os() {
    log "Проверка версии Ubuntu..."
    if [ ! -f /etc/os-release ]; then
        error_exit "Это не Ubuntu"
    fi
    source /etc/os-release
    if [ "$NAME" != "Ubuntu" ]; then
        error_exit "ОС не является Ubuntu"
    fi
    VERSION=${VERSION_ID%%.*}
    if [ "$VERSION" -lt 22 ]; then
        error_exit "Требуется Ubuntu 22.04 или новее"
    fi
    log "Найдена Ubuntu версии $VERSION_ID"
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Скрипт должен быть запущен от root"
    fi
    log "Скрипт запущен от root"
}

# Обновление системы
update_system() {
    log "Обновление пакетов..."
    apt-get update -q >> "$LOG_FILE" 2>&1 || error_exit "Ошибка apt-get update"
    apt-get upgrade -y -q >> "$LOG_FILE" 2>&1 || error_exit "Ошибка apt-get upgrade"
    log "Система обновлена"
}

# Установка SSH
install_ssh() {
    log "Установка SSH сервера..."
    apt-get install -y -q openssh-server >> "$LOG_FILE" 2>&1 || error_exit "Ошибка установки SSH"
    log "SSH установлен"
}

# Выбор пользователя
select_user() {
    mapfile -t sudo_users < <(getent passwd | awk -F: '$3 >= 1000 && $3 <= 60000 {print $1}' | xargs -n1 groups | grep sudo | cut -d: -f1 | sort -u)
    
    if [ ${#sudo_users[@]} -gt 0 ]; then
        echo "Найдены пользователи с sudo:"
        for i in "${!sudo_users[@]}"; do
            echo "$((i+1)). ${sudo_users[$i]}"
        done
        echo "$(( ${#sudo_users[@]} + 1 )). Создать нового пользователя"
        
        while true; do
            read -rp "Выберите пользователя: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#sudo_users[@]} + 1)) ]; then
                if [ "$choice" -le ${#sudo_users[@]} ]; then
                    USERNAME="${sudo_users[$((choice-1))]}"
                    break
                else
                    create_user
                    break
                fi
            fi
        done
    else
        create_user
    fi
    log "Выбран пользователь: $USERNAME"
}

# Создание пользователя
create_user() {
    while true; do
        read -rp "Введите имя нового пользователя: " username
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            if id -u "$username" >/dev/null 2>&1; then
                echo "Пользователь уже существует"
            else
                adduser --gecos "" --disabled-password "$username" >> "$LOG_FILE" 2>&1
                usermod -aG sudo "$username"
                USERNAME="$username"
                break
            fi
        else
            echo "Невалидное имя пользователя"
        fi
    done
}

# Функция проверки валидности SSH ключа
validate_ssh_key() {
    local key_data="$1"
    
    # Проверка на стандартный OpenSSH ключ (однострочный)
    if echo "$key_data" | grep -q "ssh-"; then
        return 0
    fi
    
    # Проверка на многострочный ключ в формате SSH2
    if echo "$key_data" | grep -q "BEGIN SSH2 PUBLIC KEY" && \
       echo "$key_data" | grep -q "END SSH2 PUBLIC KEY"; then
        return 0
    fi
    
    # Проверка на многострочный ключ в формате OPENSSH
    if echo "$key_data" | grep -q "BEGIN OPENSSH PRIVATE KEY" && \
       echo "$key_data" | grep -q "END OPENSSH PRIVATE KEY"; then
        return 0
    fi
    
    return 1
}

# Функция нормализации SSH ключа (преобразование в однострочный формат)
normalize_ssh_key() {
    local key_data="$1"
    
    # Если это многострочный формат SSH2, извлекаем base64 данные
    if echo "$key_data" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
        # Удаляем заголовки и футеры, оставляем только base64 данные
        key_data=$(echo "$key_data" | sed -e '/BEGIN SSH2 PUBLIC KEY/d' \
                                         -e '/END SSH2 PUBLIC KEY/d' \
                                         -e '/Comment:/d' \
                                         -e 's/^[[:space:]]*//' \
                                         -e 's/[[:space:]]*$//' | tr -d '\n')
        # Формируем стандартный OpenSSH ключ
        echo "ssh-ed25519 $key_data"
    else
        # Для других форматов возвращаем как есть
        echo "$key_data"
    fi
}

# Работа с SSH ключами
manage_ssh_keys() {
    local root_key="/root/.ssh/authorized_keys"
    local user_ssh="/home/$USERNAME/.ssh"
    local user_key="$user_ssh/authorized_keys"
    
    if [ -f "$root_key" ] && [ -s "$root_key" ]; then
        echo "Обнаружены SSH ключи у root"
        echo "1. Перенести ключи root к пользователю"
        echo "2. Добавить новый ключ"
        read -rp "Выберите действие: " choice
        
        case $choice in
            1)
                mkdir -p "$user_ssh"
                cp "$root_key" "$user_key"
                chown -R "$USERNAME:$USERNAME" "$user_ssh"
                chmod 700 "$user_ssh"
                chmod 600 "$user_key"
                rm -f "$root_key"
                log "Ключи перенесены от root к $USERNAME"
                ;;
            2)
                add_ssh_key "$user_ssh" "$user_key"
                rm -f "$root_key"
                ;;
            *)
                error_exit "Неверный выбор"
                ;;
        esac
    else
        add_ssh_key "$user_ssh" "$user_key"
    fi
}

# Добавление SSH ключа
add_ssh_key() {
    local ssh_dir="$1"
    local key_file="$2"
    local key_data=""
    
    mkdir -p "$ssh_dir"
    echo "Введите публичный ключ (Ctrl+D для завершения):"
    
    # Чтение многострочного ввода
    while IFS= read -r line; do
        key_data+="$line"$'\n'
    done
    
    # Удаление последнего перевода строки
    key_data="${key_data%$'\n'}"
    
    # Проверка валидности ключа
    if validate_ssh_key "$key_data"; then
        # Нормализация ключа (преобразование в однострочный формат если нужно)
        local normalized_key=$(normalize_ssh_key "$key_data")
        
        # Добавление ключа в файл
        echo "$normalized_key" >> "$key_file"
        chown -R "$USERNAME:$USERNAME" "$ssh_dir"
        chmod 700 "$ssh_dir"
        chmod 600 "$key_file"
        log "Добавлен новый SSH ключ"
    else
        error_exit "Введен невалидный SSH ключ"
    fi
}

# Смена порта SSH
change_ssh_port() {
    while true; do
        read -rp "Введите новый порт SSH: " port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            # Создаем backup конфигурации
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
            # Изменяем порт
            sed -i "s/^#Port.*/Port $port/" /etc/ssh/sshd_config
            sed -i "s/^Port.*/Port $port/" /etc/ssh/sshd_config
            # Если порт не был задан, добавляем новую строку
            if ! grep -q "^Port" /etc/ssh/sshd_config; then
                echo "Port $port" >> /etc/ssh/sshd_config
            fi
            SSHD_PORT="$port"
            break
        else
            echo "Неверный порт. Должен быть числом от 1024 до 65535"
        fi
    done
    log "SSH порт изменен на $SSHD_PORT"
}

# Установка fail2ban
install_fail2ban() {
    log "Установка и настройка fail2ban..."
    apt-get install -y -q fail2ban >> "$LOG_FILE" 2>&1
    
    # Создаем конфигурацию для нового порта
    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = $SSHD_PORT
logpath = %(sshd_log)s
maxretry = 3
EOF
    
    systemctl restart fail2ban
    log "Fail2ban настроен для порта $SSHD_PORT"
}

# Настройка UFW
setup_ufw() {
    log "Настройка UFW..."
    apt-get install -y -q ufw >> "$LOG_FILE" 2>&1
    
    # Сброс правил
    ufw --force reset >> "$LOG_FILE" 2>&1
    
    # Разрешаем необходимые порты
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    ufw allow "$SSHD_PORT/tcp" >> "$LOG_FILE" 2>&1
    
    # Включаем UFW
    ufw --force enable >> "$LOG_FILE" 2>&1
    log "UFW настроен с портами 80, 443 и $SSHD_PORT"
    
    # Проверка подключения
    while true; do
        read -rp "Проверьте подключение по SSH к порту $SSHD_PORT. Успешно? (y/n): " confirm
        case $confirm in
            y|Y)
                # Закрываем порт 22 и отключаем парольную аутентификацию
                ufw delete allow 22/tcp >> "$LOG_FILE" 2>&1
                
                # Отключаем парольную аутентификацию
                sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
                sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
                
                # Перезагружаем службы
                systemctl restart ssh
                systemctl restart fail2ban
                break
                ;;
            n|N)
                error_exit "Пользователь отменил настройку"
                ;;
        esac
    done
}

# Основная функция
main() {
    check_os
    check_root
    update_system
    install_ssh
    select_user
    manage_ssh_keys
    change_ssh_port
    install_fail2ban
    setup_ufw
    
    IP=$(hostname -I | awk '{print $1}')
    echo "Настройка завершена!"
    echo "Пользователь: $USERNAME"
    echo "IP: $IP"
    echo "Порт SSH: $SSHD_PORT"
    log "Настройка успешно завершена для $USERNAME на $IP:$SSHD_PORT"
}

# Очистка временных файлов
cleanup() {
    rm -f "${TEMP_FILES[@]}"
    log "Временные файлы удалены"
}

trap cleanup EXIT
main "$@"
