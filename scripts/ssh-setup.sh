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
    # Удаляем все пробелы в начале и конце строки
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# Функция проверки прав доступа SSH
verify_ssh_permissions() {
    local user="$1"
    local home_dir=""
    
    # Определяем домашнюю директорию пользователя
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
    
    # Проверка прав доступа директории
    if [ "$(stat -c %a "$ssh_dir")" != "700" ]; then
        chmod 700 "$ssh_dir"
        log "Исправлены права доступа для $ssh_dir"
    fi
    
    # Проверка прав доступа файла
    if [ "$(stat -c %a "$auth_keys")" != "600" ]; then
        chmod 600 "$auth_keys"
        log "Исправлены права доступа для $auth_keys"
    fi
    
    # Проверка владельца
    if [ "$user" != "root" ] && [ "$(stat -c %U "$ssh_dir")" != "$user" ]; then
        chown -R "$user:$user" "$ssh_dir"
        log "Исправлен владелец для $ssh_dir"
    fi
}

# Функция копирования ключей с проверкой
copy_ssh_keys() {
    local source_user="$1"
    local target_user="$2"
    local source_dir=""
    local target_dir=""
    
    # Определяем домашние директории
    if [ "$source_user" == "root" ]; then
        source_dir="/root/.ssh"
    else
        source_dir="/home/$source_user/.ssh"
    fi
    
    if [ "$target_user" == "root" ]; then
        target_dir="/root/.ssh"
    else
        target_dir="/home/$target_user/.ssh"
    fi
    
    log "Копирование SSH ключей от $source_user к $target_user"
    
    # Проверка существования исходных ключей
    if [ ! -f "$source_dir/authorized_keys" ] || [ ! -s "$source_dir/authorized_keys" ]; then
        log "Предупреждение: Нет ключей у пользователя $source_user для копирования"
        return 1
    fi
    
    # Создание целевой директории
    verify_ssh_permissions "$target_user"
    
    # Копирование ключей
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

# Функция создания и настройки .ssh директории
setup_ssh_directory() {
    local username=$(trim "$1")
    local home_dir=""
    
    if [ "$username" == "root" ]; then
        home_dir="/root"
    else
        home_dir="/home/$username"
    fi
    
    local ssh_dir="$home_dir/.ssh"
    
    log "Настройка SSH директории для пользователя $username"
    
    # Используем функцию проверки прав доступа
    verify_ssh_permissions "$username"
    
    echo "$ssh_dir"
}

# Функция создания новой конфигурации SSH
create_ssh_config() {
    local port="$1"
    local username="$2"
    
    log "Создание новой конфигурации SSH для порта $port и пользователя $username"
    
    # Создаем backup текущей конфигурации
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Создаем новую конфигурацию на основе существующей
    cp /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S) /etc/ssh/sshd_config
    
    # Обновляем только необходимые параметры
    sed -i "s/^#*Port.*/Port $port/" /etc/ssh/sshd_config
    sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
    
    # Добавляем/обновляем AllowUsers
    if grep -q "^AllowUsers" /etc/ssh/sshd_config; then
        sed -i "s/^AllowUsers.*/AllowUsers $username/" /etc/ssh/sshd_config
    else
        echo "AllowUsers $username" >> /etc/ssh/sshd_config
    fi
    
    # Добавляем security enhancements если их нет
    if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
        echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config
    fi
    if ! grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
        echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config
    fi
    if ! grep -q "^MaxAuthTries" /etc/ssh/sshd_config; then
        echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
    fi
    
    log "Новая конфигурация SSH создана"
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

# Выбор пользователя
select_user() {
    mapfile -t sudo_users < <(getent passwd | awk -F: '$3 >= 1000 && $3 <= 60000 {print $1}' | xargs -n1 groups 2>/dev/null | grep sudo | cut -d: -f1 | sort -u)
    
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
        username=$(trim "$username")
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            if id -u "$username" >/dev/null 2>&1; then
                echo "Пользователь уже существует"
            else
                adduser --gecos "" --disabled-password "$username" >> "$LOG_FILE" 2>&1
                usermod -aG sudo "$username"
                USERNAME="$username"
                
                # Создаем и настраиваем .ssh директорию для нового пользователя
                setup_ssh_directory "$USERNAME"
                
                break
            fi
        else
            echo "Невалидное имя пользователя. Используйте только строчные латинские буквы, цифры, дефисы и подчеркивания"
        fi
    done
}

# Функция проверки валидности SSH ключа
validate_ssh_key() {
    local key_data="$1"
    
    # Удаляем начальные и конечные пробелы
    key_data=$(echo "$key_data" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # Проверка на стандартный OpenSSH ключ (однострочный)
    if echo "$key_data" | grep -q -E "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256) "; then
        return 0
    fi
    
    # Проверка на base64 encoded ключ (минимальная длина)
    if echo "$key_data" | grep -q -E "^[A-Za-z0-9+/]{100,}={0,2}$"; then
        return 0
    fi
    
    return 1
}

# Функция нормализации SSH ключа
normalize_ssh_key() {
    local key_data="$1"
    
    # Удаляем начальные и конечные пробелы
    key_data=$(echo "$key_data" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # Если ключ уже в правильном формате, возвращаем как есть
    if echo "$key_data" | grep -q -E "^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256) "; then
        echo "$key_data"
        return
    fi
    
    # Пытаемся определить тип ключа по содержимому
    if echo "$key_data" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
        # SSH2 формат - преобразуем в OpenSSH
        echo "$key_data" | ssh-keygen -i -f /dev/stdin 2>/dev/null || echo "$key_data"
    else
        # Просто возвращаем как есть, возможно это base64 ключ
        echo "$key_data"
    fi
}

# Работа с SSH ключами
manage_ssh_keys() {
    local root_key="/root/.ssh/authorized_keys"
    
    # Создаем и настраиваем .ssh директорию для выбранного пользователя
    local user_ssh=$(setup_ssh_directory "$USERNAME")
    local user_key="$user_ssh/authorized_keys"
    
    if [ -f "$root_key" ] && [ -s "$root_key" ]; then
        echo "Обнаружены SSH ключи у root"
        echo "1. Перенести ключи root к пользователю"
        echo "2. Добавить новый ключ"
        while true; do
            read -rp "Выберите действие: " choice
            case $choice in
                1)
                    # Используем функцию копирования ключей
                    if copy_ssh_keys "root" "$USERNAME"; then
                        # Очищаем root ключи только после успешного копирования
                        > "$root_key"
                        log "Ключи перенесены от root к $USERNAME"
                    else
                        echo "Не удалось скопировать ключи от root, добавляем новый ключ"
                        add_ssh_key "$user_ssh" "$user_key"
                    fi
                    break
                    ;;
                2)
                    add_ssh_key "$user_ssh" "$user_key"
                    break
                    ;;
                *)
                    echo "Неверный выбор. Введите 1 или 2"
                    ;;
            esac
        done
    else
        echo "Ключи root не найдены или пустые, добавляем новый ключ"
        add_ssh_key "$user_ssh" "$user_key"
    fi
    
    # Проверяем, что у пользователя есть хотя бы один ключ
    if [ ! -s "$user_key" ]; then
        error_exit "У пользователя $USERNAME нет SSH ключей. Настройка не может быть завершена."
    fi
}

# Добавление SSH ключа
add_ssh_key() {
    local ssh_dir="$1"
    local key_file="$2"
    local key_data=""
    
    echo "Введите публичный ключ (Ctrl+D для завершения ввода):"
    echo "Пример: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."
    
    # Чтение многострочного ввода
    while IFS= read -r line; do
        key_data+="$line"$'\n'
    done
    
    # Удаление последнего перевода строки
    key_data="${key_data%$'\n'}"
    
    # Проверка что что-то введено
    if [ -z "$key_data" ]; then
        error_exit "Не введен SSH ключ"
    fi
    
    # Проверка валидности ключа
    if validate_ssh_key "$key_data"; then
        # Нормализация ключа
        local normalized_key=$(normalize_ssh_key "$key_data")
        
        # Добавляем ключ в файл (не перезаписываем, а добавляем)
        echo "$normalized_key" >> "$key_file"
        chown "$USERNAME:$USERNAME" "$key_file"
        chmod 600 "$key_file"
        log "Добавлен новый SSH ключ"
        
        # Проверяем что ключ действительно записался
        if grep -q "$normalized_key" "$key_file"; then
            log "Ключ успешно записан в $key_file"
            echo "Добавленный ключ:"
            tail -n 1 "$key_file"
        else
            log "ОШИБКА: Ключ не записался в файл $key_file"
            error_exit "Не удалось записать SSH ключ"
        fi
    else
        error_exit "Введен невалидный SSH ключ: $key_data"
    fi
}

# Смена порта SSH
change_ssh_port() {
    while true; do
        read -rp "Введите новый порт SSH (1024-65535): " port
        port=$(trim "$port")
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            SSHD_PORT="$port"
            
            # Проверяем, не занят ли порт
            if netstat -tuln | grep -q ":$SSHD_PORT "; then
                echo "Порт $SSHD_PORT уже занят. Выберите другой порт."
                continue
            fi
            
            # Создаем новую конфигурацию SSH
            create_ssh_config "$SSHD_PORT" "$USERNAME"
            
            # Перезагружаем SSH сервер для применения изменений
            systemctl restart ssh
            log "SSH порт изменен на $SSHD_PORT и сервис перезагружен"
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
    
    # Создаем конфигурацию для нового порта
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
    
    # Разрешаем необходимые порты
    ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    ufw allow "$SSHD_PORT/tcp" >> "$LOG_FILE" 2>&1
    
    # Включаем UFW
    ufw --force enable >> "$LOG_FILE" 2>&1
    log "UFW настроен с портами 80, 443 и $SSHD_PORT"
    
    # Даем пользователю время для проверки
    echo "Проверьте подключение по SSH к порту $SSHD_PORT"
    echo "У вас есть 60 секунд для проверки перед закрытием порта 22..."
    sleep 60
    
    # Закрываем порт 22
    ufw delete allow 22/tcp >> "$LOG_FILE" 2>&1
    
    # Перезагружаем службы
    systemctl restart ssh
    systemctl restart fail2ban
    
    log "Порт 22 закрыт, службы перезагружены"
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

# Очистка временных файлов
cleanup() {
    rm -f "${TEMP_FILES[@]}"
    log "Временные файлы удалены"
}

trap cleanup EXIT
main "$@"
