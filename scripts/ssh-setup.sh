#!/bin/bash

LOG_FILE="/var/log/system_setup.log"
TEMP_FILES=()
SSHD_PORT=""
USERNAME=""

# Функция логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция обработки ошибок
error_exit() {
    log "ОШИБКА: $1"
    exit 1
}

# Функция для удаления лишних пробелов
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# Функция проверки прав доступа SSH
verify_ssh_permissions() {
    local user="$1"
    local home_dir=""
    
    if [ "$user" == "root" ]; then
        home_dir="/root"
    else
        home_dir="/home/$user"
    fi
    
    local ssh_dir="$home_dir/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    
    log "Проверка прав доступа SSH для пользователя $user"
    
    # Проверка и создание директории
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        if [ "$user" != "root" ]; then
            chown "$user:$user" "$ssh_dir"
        else
            chown root:root "$ssh_dir"
        fi
        log "Создана директория $ssh_dir"
    fi
    
    # Проверка и создание файла authorized_keys
    if [ ! -f "$auth_keys" ]; then
        touch "$auth_keys"
        chmod 600 "$auth_keys"
        if [ "$user" != "root" ]; then
            chown "$user:$user" "$auth_keys"
        else
            chown root:root "$auth_keys"
        fi
        log "Создан файл $auth_keys"
    fi
    
    # Проверка прав доступа
    if [ "$(stat -c %a "$ssh_dir")" != "700" ]; then
        chmod 700 "$ssh_dir"
        log "Исправлены права доступа для $ssh_dir"
    fi
    
    if [ "$(stat -c %a "$auth_keys")" != "600" ]; then
        chmod 600 "$auth_keys"
        log "Исправлены права доступа для $auth_keys"
    fi
}

# Функция получения пути к SSH директории
get_ssh_directory() {
    local username=$(trim "$1")
    local home_dir=""
    
    if [ "$username" == "root" ]; then
        home_dir="/root"
    else
        home_dir="/home/$username"
    fi
    
    echo "$home_dir/.ssh"
}

# Функция настройки SSH директории
setup_ssh_directory() {
    local username=$(trim "$1")
    local ssh_dir=$(get_ssh_directory "$username")
    
    log "Настройка SSH директории для пользователя $username"
    verify_ssh_permissions "$username"
}

# Функция копирования ключей
copy_ssh_keys() {
    local source_user="$1"
    local target_user="$2"
    local source_dir=$(get_ssh_directory "$source_user")
    local target_dir=$(get_ssh_directory "$target_user")
    
    log "Копирование SSH ключей от $source_user к $target_user"
    
    if [ ! -f "$source_dir/authorized_keys" ] || [ ! -s "$source_dir/authorized_keys" ]; then
        log "Предупреждение: Нет ключей у пользователя $source_user для копирования"
        return 1
    fi
    
    setup_ssh_directory "$target_user"
    
    cp "$source_dir/authorized_keys" "$target_dir/"
    if [ "$target_user" != "root" ]; then
        chown "$target_user:$target_user" "$target_dir/authorized_keys"
    else
        chown root:root "$target_dir/authorized_keys"
    fi
    chmod 600 "$target_dir/authorized_keys"
    
    log "Ключи успешно скопированы от $source_user к $target_user"
    return 0
}

# Функция создания конфигурации SSH
create_ssh_config() {
    local port="$1"
    local username="$2"
    
    log "Создание конфигурации SSH для порта $port"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Обновляем только нужные параметры
    sed -i "s/^#*Port.*/Port $port/" /etc/ssh/sshd_config
    sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
    
    # Обновляем или добавляем AllowUsers
    if grep -q "^AllowUsers" /etc/ssh/sshd_config; then
        sed -i "s/^AllowUsers.*/AllowUsers $username/" /etc/ssh/sshd_config
    else
        echo "AllowUsers $username" >> /etc/ssh/sshd_config
    fi
    
    # Перезагружаем SSH для применения изменений
    systemctl restart ssh
    if ! systemctl is-active --quiet ssh; then
        error_exit "Ошибка при перезагрузке SSH сервера после изменения конфигурации"
    fi
    log "SSH конфигурация применена и сервис перезагружен"
}

# Функция проверки валидности SSH ключа
validate_ssh_key() {
    local key_data="$1"
    key_data=$(echo "$key_data" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # Проверяем различные форматы ключей
    if echo "$key_data" | grep -q -E "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256) "; then
        return 0
    fi
    
    if echo "$key_data" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
        return 0
    fi
    
    if echo "$key_data" | grep -q -E "^[A-Za-z0-9+/]{20,}={0,2}$"; then
        return 0
    fi
    
    return 1
}

# Функция нормализации SSH ключа
normalize_ssh_key() {
    local key_data="$1"
    key_data=$(echo "$key_data" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # Обработка SSH2 формата
    if echo "$key_data" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
        local base64_data=$(echo "$key_data" | \
            sed -e '/BEGIN SSH2 PUBLIC KEY/d' \
                -e '/END SSH2 PUBLIC KEY/d' \
                -e '/Comment:/d' \
                -e 's/^[[:space:]]*//' \
                -e 's/[[:space:]]*$//' | \
            tr -d '\n')
        echo "ssh-ed25519 $base64_data"
        return
    fi
    
    # Если уже OpenSSH формат
    if echo "$key_data" | grep -q -E "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256) "; then
        echo "$key_data"
        return
    fi
    
    # Просто base64 - предполагаем ed25519
    if echo "$key_data" | grep -q -E "^[A-Za-z0-9+/]{20,}={0,2}$"; then
        echo "ssh-ed25519 $key_data"
        return
    fi
    
    echo "$key_data"
}

# Добавление SSH ключа
add_ssh_key() {
    local username="$1"
    local ssh_dir=$(get_ssh_directory "$username")
    local key_file="$ssh_dir/authorized_keys"
    
    echo "Введите публичный ключ (Ctrl+D для завершения):"
    echo "Пример: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."
    
    local key_data=""
    while IFS= read -r line; do
        key_data+="$line"$'\n'
    done
    
    key_data="${key_data%$'\n'}"
    
    if [ -z "$key_data" ]; then
        error_exit "Не введен SSH ключ"
    fi
    
    if validate_ssh_key "$key_data"; then
        local normalized_key=$(normalize_ssh_key "$key_data")
        
        # Обеспечиваем существование директории
        setup_ssh_directory "$username"
        
        # Добавляем ключ
        echo "$normalized_key" >> "$key_file"
        chown "$username:$username" "$key_file"
        chmod 600 "$key_file"
        log "Добавлен новый SSH ключ"
        
        # Проверяем запись
        if grep -q "$normalized_key" "$key_file"; then
            log "Ключ успешно записан в $key_file"
        else
            error_exit "Не удалось записать SSH ключ в $key_file"
        fi
    else
        error_exit "Введен невалидный SSH ключ"
    fi
}

# Работа с SSH ключами
manage_ssh_keys() {
    local root_key="/root/.ssh/authorized_keys"
    
    # Настраиваем директорию для пользователя
    setup_ssh_directory "$USERNAME"
    local user_ssh_dir=$(get_ssh_directory "$USERNAME")
    local user_key="$user_ssh_dir/authorized_keys"
    
    if [ -f "$root_key" ] && [ -s "$root_key" ]; then
        echo "Обнаружены SSH ключи у root"
        echo "1. Перенести ключи root к пользователю"
        echo "2. Добавить новый ключ"
        
        while true; do
            read -rp "Выберите действие: " choice
            case $choice in
                1)
                    if copy_ssh_keys "root" "$USERNAME"; then
                        > "$root_key"
                        log "Ключи перенесены от root к $USERNAME"
                    else
                        echo "Не удалось скопировать ключи, добавляем новый"
                        add_ssh_key "$USERNAME"
                    fi
                    break
                    ;;
                2)
                    add_ssh_key "$USERNAME"
                    break
                    ;;
                *)
                    echo "Неверный выбор. Введите 1 или 2"
                    ;;
            esac
        done
    else
        echo "Ключи root не найдены, добавляем новый ключ"
        add_ssh_key "$USERNAME"
    fi
    
    # Финальная проверка
    if [ ! -s "$user_key" ]; then
        error_exit "У пользователя $USERNAME нет SSH ключей"
    fi
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
    if ! dpkg -l | grep -q openssh-server; then
        log "Установка SSH сервера..."
        apt-get install -y -q openssh-server >> "$LOG_FILE" 2>&1 || error_exit "Ошибка установки SSH"
        log "SSH установлен"
    else
        log "SSH сервер уже установлен"
    fi
}

# Создание пользователя
# Создание пользователя
create_user() {
    while true; do
        read -rp "Введите имя нового пользователя: " username
        username=$(trim "$username")
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            if id -u "$username" >/dev/null 2>&1; then
                echo "Пользователь уже существует"
            else
                # Создаем пользователя без пароля
                adduser --gecos "" --disabled-password "$username" >> "$LOG_FILE" 2>&1
                
                # Добавляем в группу sudo
                usermod -aG sudo "$username"
                
                # Отключаем запрос пароля sudo для этого пользователя
                echo "$username ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$username
                chmod 440 /etc/sudoers.d/$username
                
                USERNAME="$username"
                
                # Создаем и настраиваем .ssh директорию
                setup_ssh_directory "$USERNAME"
                
                log "Создан пользователь $USERNAME с правами sudo без пароля"
                break
            fi
        else
            echo "Невалидное имя пользователя. Используйте только строчные латинские буквы, цифры, дефисы и подчеркивания"
        fi
    done
}

# Выбор пользователя
select_user() {
    # Получаем пользователей с sudo правами
    local sudo_users=()
    while IFS= read -r user; do
        if [ -n "$user" ] && [ "$user" != "root" ]; then
            sudo_users+=("$user")
        fi
    done < <(getent passwd | awk -F: '$3 >= 1000 && $3 <= 60000 {print $1}' | xargs -n1 groups 2>/dev/null | grep sudo | cut -d: -f1 | sort -u)
    
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
                    USERNAME=$(trim "${sudo_users[$((choice-1))]}")
                    
                    # Проверяем и настраиваем sudo без пароля для существующего пользователя
                    if [ ! -f "/etc/sudoers.d/$USERNAME" ]; then
                        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
                        chmod 440 /etc/sudoers.d/$USERNAME
                        log "Настроен sudo без пароля для существующего пользователя $USERNAME"
                    fi
                    
                    break
                else
                    create_user
                    break
                fi
            else
                echo "Неверный выбор. Введите число от 1 до $((${#sudo_users[@]} + 1))"
            fi
        done
    else
        echo "Пользователей с sudo не найдено, создаем нового"
        create_user
    fi
    log "Выбран пользователь: $USERNAME"
}

# Смена порта SSH
change_ssh_port() {
    while true; do
        read -rp "Введите новый порт SSH (1024-65535): " port
        port=$(trim "$port")
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            # Проверяем, не занят ли порт
            if netstat -tuln | grep -q ":$port "; then
                echo "Порт $port уже занят. Выберите другой порт."
                continue
            fi
            
            SSHD_PORT="$port"
            
            # Создаем новую конфигурацию SSH
            create_ssh_config "$SSHD_PORT" "$USERNAME"
            
            # Перезагружаем SSH сервер для применения изменений
            systemctl restart ssh
            log "SSH порт изменен на $SSHD_PORT и сервис перезагружен"
            
            # Проверяем что сервер запустился успешно
            if ! systemctl is-active --quiet ssh; then
                error_exit "Ошибка при перезагрузке SSH сервера. Проверьте конфигурацию."
            fi
            
            break
        else
            echo "Неверный порт. Должен быть числом от 1024 до 65535"
        fi
    done
}

# Установка fail2ban
install_fail2ban() {
    if ! dpkg -l | grep -q fail2ban; then
        log "Установка fail2ban..."
        apt-get install -y -q fail2ban >> "$LOG_FILE" 2>&1
    fi
    
    # Создаем конфигурацию
    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = $SSHD_PORT
logpath = %(sshd_log)s
maxretry = 3
findtime = 600
bantime = 600
EOF
    
    systemctl restart fail2ban
    log "Fail2ban настроен для порта $SSHD_PORT"
}

# Настройка UFW
setup_ufw() {
    if ! dpkg -l | grep -q ufw; then
        log "Установка UFW..."
        apt-get install -y -q ufw >> "$LOG_FILE" 2>&1
    fi
    
    # Сброс правил
    ufw --force reset >> "$LOG_FILE" 2>&1
    
    # Разрешаем необходимые порты (включая старый порт 22 для безопасности)
    ufw allow 22/tcp >> "$LOG_FILE" 2>&1
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    ufw allow "$SSHD_PORT/tcp" >> "$LOG_FILE" 2>&1
    
    # Включаем UFW
    ufw --force enable >> "$LOG_FILE" 2>&1
    systemctl restart ssh
    log "UFW настроен с портами 22, 80, 443 и $SSHD_PORT"
    
    echo "=== ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ ==="
    echo "Сейчас открыты оба порта: 22 и $SSHD_PORT"
    echo "Проверьте подключение по SSH к НОВОМУ порту $SSHD_PORT"
    echo "Убедитесь, что подключение работает корректно"
    echo "============================="
    
    # Запрашиваем подтверждение перед закрытием порта 22
    while true; do
        read -rp "Подключение к порту $SSHD_PORT успешно? Готовы закрыть порт 22? (y/n): " confirm
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
        case $confirm in
            y|yes|д|да)
                # Закрываем порт 22 только после подтверждения
                ufw delete allow 22/tcp >> "$LOG_FILE" 2>&1
                
                # Перезагружаем службы
                systemctl restart ssh
                systemctl restart fail2ban
                
                # Проверяем что SSH запустился
                if ! systemctl is-active --quiet ssh; then
                    error_exit "Ошибка при перезагрузке SSH сервера после настройки UFW"
                fi
                
                log "Порт 22 закрыт, службы перезагружены"
                echo "Порт 22 успешно закрыт. Подключение возможно только через порт $SSHD_PORT"
                break
                ;;
            n|no|н|нет)
                echo "Порт 22 остается открытым. Ручная проверка необходима."
                echo "Вы можете закрыть порт 22 позже командой: ufw delete allow 22/tcp"
                log "Порт 22 оставлен открытым по требованию пользователя"
                break
                ;;
            *)
                echo "Пожалуйста, ответьте yes/y или no/n"
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
    echo "Лог файл: $LOG_FILE"
    log "Настройка успешно завершена для $USERNAME на $IP:$SSHD_PORT"
}

# Очистка
cleanup() {
    rm -f "${TEMP_FILES[@]}"
    log "Временные файлы удалены"
}

trap cleanup EXIT
main "$@"
