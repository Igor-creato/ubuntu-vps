#!/bin/bash

# Безопасная функция настройки SSH для Ubuntu
# Основана на официальной документации Ubuntu и лучших практиках безопасности

# Функции для вывода сообщений (предполагается что они уже определены)
print_info() { echo -e "\e[34m[INFO]\e[0m $*"; }
print_ok() { echo -e "\e[32m[OK]\e[0m $*"; }
print_err() { echo -e "\e[31m[ERROR]\e[0m $*"; }
print_warn() { echo -e "\e[33m[WARNING]\e[0m $*"; }

# Проверка существующих пользователей с sudo правами
check_existing_sudo_users() {
    local existing_users=()
    
    print_info "Проверяем существующих пользователей с sudo правами..."
    
    # Получаем список пользователей с sudo правами
    while IFS= read -r user; do
        if [[ "$user" != "root" && "$user" != "" ]]; then
            existing_users+=("$user")
        fi
    done < <(getent group sudo | cut -d: -f4 | tr ',' '\n')
    
    # Также проверяем группу admin (для старых версий Ubuntu)
    if getent group admin >/dev/null 2>&1; then
        while IFS= read -r user; do
            if [[ "$user" != "root" && "$user" != "" && ! " ${existing_users[*]} " =~ " ${user} " ]]; then
                existing_users+=("$user")
            fi
        done < <(getent group admin | cut -d: -f4 | tr ',' '\n')
    fi
    
    if [[ ${#existing_users[@]} -gt 0 ]]; then
        print_warn "Найдены существующие пользователи с sudo правами:"
        printf '  - %s\n' "${existing_users[@]}"
        echo
        echo "Выберите действие:"
        echo "  1) Настроить SSH для существующего пользователя"
        echo "  2) Создать нового пользователя"
        echo
        
        while true; do
            read -r -p "Ваш выбор (1/2): " choice
            case "$choice" in
                1)
                    echo "Доступные пользователи:"
                    for i in "${!existing_users[@]}"; do
                        echo "  $((i+1))) ${existing_users[$i]}"
                    done
                    echo
                    
                    while true; do
                        read -r -p "Выберите пользователя (1-${#existing_users[@]}): " user_choice
                        if [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ "$user_choice" -ge 1 ]] && [[ "$user_choice" -le ${#existing_users[@]} ]]; then
                            SELECTED_USER="${existing_users[$((user_choice-1))]}"
                            print_ok "Выбран пользователь: $SELECTED_USER"
                            return 0
                        else
                            print_err "Неверный выбор. Введите число от 1 до ${#existing_users[@]}"
                        fi
                    done
                    ;;
                2)
                    return 1  # Создать нового пользователя
                    ;;
                *)
                    print_err "Введите 1 или 2"
                    ;;
            esac
        done
    else
        print_info "Пользователи с sudo правами не найдены. Будет создан новый пользователь."
        return 1
    fi
}

# Создание нового пользователя
create_new_user() {
    local username
    
    while true; do
        read -r -p "Введите имя нового пользователя: " username
        
        # Проверка корректности имени пользователя
        if [[ -z "$username" ]]; then
            print_err "Имя пользователя не может быть пустым"
            continue
        fi
        
        if [[ ! "$username" =~ ^[a-z][-a-z0-9_]*$ ]]; then
            print_err "Имя пользователя должно начинаться с буквы и содержать только строчные буквы, цифры, дефисы и подчеркивания"
            continue
        fi
        
        if getent passwd "$username" >/dev/null 2>&1; then
            print_err "Пользователь $username уже существует"
            continue
        fi
        
        break
    done
    
    print_info "Создаем пользователя $username..."
    
    # Создаем пользователя с домашним каталогом и bash оболочкой
    if useradd -m -s /bin/bash "$username"; then
        print_ok "Пользователь $username создан"
    else
        print_err "Ошибка создания пользователя $username"
        return 1
    fi
    
    # Добавляем в группу sudo
    if usermod -aG sudo "$username"; then
        print_ok "Пользователь $username добавлен в группу sudo"
    else
        print_err "Ошибка добавления пользователя $username в группу sudo"
        return 1
    fi
    
    # Устанавливаем пароль
    print_info "Установите пароль для пользователя $username:"
    if passwd "$username"; then
        print_ok "Пароль для пользователя $username установлен"
    else
        print_err "Ошибка установки пароля для пользователя $username"
        return 1
    fi
    
    SELECTED_USER="$username"
    return 0
}

# Настройка SSH ключей
setup_ssh_keys() {
    local user="$1"
    local home_dir
    
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    
    if [[ ! -d "$home_dir" ]]; then
        print_err "Домашний каталог $home_dir не найден для пользователя $user"
        return 1
    fi
    
    # Создаем/проверяем каталог .ssh у пользователя
    print_info "Проверяем каталог .ssh для пользователя $user..."
    if [[ ! -d "$home_dir/.ssh" ]]; then
        print_info "Создаем каталог .ssh для пользователя $user"
        install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
    else
        print_info "Каталог .ssh уже существует"
        # Исправляем права если необходимо
        chown "$user:$user" "$home_dir/.ssh"
        chmod 700 "$home_dir/.ssh"
    fi
    
    # Создаем/проверяем файл authorized_keys
    if [[ ! -f "$home_dir/.ssh/authorized_keys" ]]; then
        touch "$home_dir/.ssh/authorized_keys"
    fi
    chown "$user:$user" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    
    # Проверяем наличие ключей у root
    local root_has_keys=false
    local src_content=""
    
    if [[ -f /root/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
        src_content="$(cat /root/.ssh/authorized_keys)"
        root_has_keys=true
        print_info "Найдены ключи в /root/.ssh/authorized_keys"
    fi
    
    if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
        local pub_content
        pub_content="$(cat /root/.ssh/*.pub 2>/dev/null)"
        if [[ -n "$pub_content" ]]; then
            if [[ -n "$src_content" ]]; then
                src_content="${src_content}"$'\n'"${pub_content}"
            else
                src_content="$pub_content"
            fi
            root_has_keys=true
            print_info "Найдены публичные ключи в /root/.ssh/*.pub"
        fi
    fi
    
    # Выбор действия в зависимости от наличия ключей у root
    if [[ "$root_has_keys" == true ]]; then
        echo
        print_info "У root найдены SSH ключи. Выберите действие:"
        echo "  1) Перенести ключи от root к пользователю $user"
        echo "  2) Добавить свой ключ (многострочный ввод)"
        echo "  3) Сгенерировать новый ed25519 ключ"
        echo
        
        while true; do
            read -r -p "Ваш выбор (1/2/3): " choice
            case "$choice" in
                1)
                    # Переносим ключи от root
                    add_keys_to_user "$user" "$src_content"
                    break
                    ;;
                2)
                    # Добавляем пользовательские ключи
                    add_custom_keys "$user"
                    break
                    ;;
                3)
                    # Генерируем новый ключ
                    generate_new_key "$user"
                    break
                    ;;
                *)
                    print_err "Введите 1, 2 или 3"
                    ;;
            esac
        done
    else
        echo
        print_info "У root SSH ключи не найдены. Выберите действие:"
        echo "  1) Добавить свой ключ (многострочный ввод)"
        echo "  2) Сгенерировать новый ed25519 ключ"
        echo
        
        while true; do
            read -r -p "Ваш выбор (1/2): " choice
            case "$choice" in
                1)
                    add_custom_keys "$user"
                    break
                    ;;
                2)
                    generate_new_key "$user"
                    break
                    ;;
                *)
                    print_err "Введите 1 или 2"
                    ;;
            esac
        done
    fi
    
    # Удаляем ключи у root независимо от выбора
    if [[ "$root_has_keys" == true ]]; then
        print_info "Удаляем SSH ключи у root для безопасности..."
        
        if [[ -f /root/.ssh/authorized_keys ]]; then
            > /root/.ssh/authorized_keys
            print_ok "Очищен /root/.ssh/authorized_keys"
        fi
        
        # Опционально удаляем публичные ключи (оставляем приватные для использования)
        if compgen -G "/root/.ssh/*.pub" >/dev/null 2>&1; then
            read -r -p "Удалить публичные ключи из /root/.ssh/*.pub? (y/n): " remove_pub
            if [[ "$remove_pub" =~ ^[Yy]$ ]]; then
                rm -f /root/.ssh/*.pub
                print_ok "Удалены публичные ключи из /root/.ssh/"
            fi
        fi
    fi
    
    return 0
}

# Добавление ключей к пользователю
add_keys_to_user() {
    local user="$1"
    local keys_content="$2"
    local home_dir
    
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    
    local tmpfile
    tmpfile="$(mktemp)"
    
    # Копируем существующие ключи
    if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
        cp -f "$home_dir/.ssh/authorized_keys" "$tmpfile"
    fi
    
    local added_count=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue
        
        if [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]]; then
            if ! grep -qxF "$line" "$tmpfile" 2>/dev/null; then
                echo "$line" >> "$tmpfile"
                ((added_count++))
            fi
        fi
    done <<< "$keys_content"
    
    install -m 600 -o "$user" -g "$user" "$tmpfile" "$home_dir/.ssh/authorized_keys"
    rm -f "$tmpfile"
    
    print_ok "Добавлено $added_count SSH ключ(ей) для пользователя $user"
}

# Добавление пользовательских ключей
add_custom_keys() {
    local user="$1"
    
    echo
    print_info "Введите ваши SSH публичные ключи:"
    print_info "Каждый ключ на отдельной строке"
    print_info "Завершите ввод нажатием Ctrl+D"
    echo "---"
    
    local user_input=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        user_input="${user_input}${line}"$'\n'
    done
    
    user_input="${user_input%$'\n'}"
    
    if [[ -n "$user_input" ]]; then
        add_keys_to_user "$user" "$user_input"
    else
        print_err "Пустой ввод. Ключи не добавлены."
        return 1
    fi
}

# Генерация нового ключа
generate_new_key() {
    local user="$1"
    local home_dir
    
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    
    # Создаем каталог .ssh у root если его нет
    install -d -m 700 -o root -g root /root/.ssh
    
    local key_name="${user}_ed25519_$(date +%Y%m%d)"
    local key_path="/root/.ssh/${key_name}"
    
    print_info "Генерируем ed25519 ключ..."
    if ssh-keygen -t ed25519 -f "$key_path" -N "" -C "${user}@$(hostname)" >/dev/null 2>&1; then
        local pub_content
        pub_content="$(cat "${key_path}.pub")"
        add_keys_to_user "$user" "$pub_content"
        
        print_ok "SSH ключ сгенерирован успешно!"
        print_info "Приватный ключ: ${key_path}"
        print_info "Публичный ключ: ${key_path}.pub"
        print_warn "ВАЖНО: Скачайте приватный ключ на ваш локальный компьютер!"
        print_info "Команда для скачивания: scp root@$(hostname):${key_path} ~/.ssh/"
    else
        print_err "Ошибка генерации ключа"
        return 1
    fi
}

# Настройка SSH порта
configure_ssh_port() {
    local new_port
    
    print_info "Текущий SSH порт: $(grep -E '^#?Port' /etc/ssh/sshd_config | head -1 | awk '{print $2}' || echo '22')"
    
    while true; do
        read -r -p "Введите новый SSH порт (рекомендуется 1024-65535): " new_port
        
        if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1024 ]] || [[ "$new_port" -gt 65535 ]]; then
            print_err "Порт должен быть числом от 1024 до 65535"
            continue
        fi
        
        # Проверяем, не занят ли порт
        if ss -tlnp | grep -q ":${new_port} "; then
            print_err "Порт $new_port уже используется"
            ss -tlnp | grep ":${new_port} "
            continue
        fi
        
        break
    done
    
    SSH_PORT="$new_port"
    
    # Создаем резервную копию конфигурации SSH
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    
    # Обновляем конфигурацию SSH
    print_info "Обновляем конфигурацию SSH..."
    
    # Удаляем старые настройки Port
    sed -i '/^#\?Port /d' /etc/ssh/sshd_config
    
    # Добавляем новые безопасные настройки
    cat >> /etc/ssh/sshd_config << EOF

# Security settings added by setup script
Port $new_port
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups sudo
Protocol 2
EOF
    
    # Проверяем конфигурацию SSH
    if sshd -t; then
        print_ok "Конфигурация SSH обновлена (порт: $new_port)"
    else
        print_err "Ошибка в конфигурации SSH. Восстанавливаем резервную копию..."
        mv /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
        return 1
    fi
    
    return 0
}

# Настройка Fail2Ban
configure_fail2ban() {
    local ssh_port="$1"
    
    print_info "Настраиваем Fail2Ban для защиты SSH на порту $ssh_port..."
    
    # Устанавливаем Fail2Ban если не установлен
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        print_info "Устанавливаем Fail2Ban..."
        apt-get update -qq
        apt-get install -y fail2ban
    fi
    
    # Создаем локальную конфигурацию Fail2Ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Ban IP for 1 hour after 3 failed attempts within 10 minutes
bantime = 3600
findtime = 600
maxretry = 3

# Ignore localhost and LAN
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12

[sshd]
enabled = true
port = $ssh_port
logpath = /var/log/auth.log
backend = systemd
maxretry = 3
findtime = 600
bantime = 3600
EOF
    
    # Перезапускаем Fail2Ban
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    # Проверяем статус
    if systemctl is-active --quiet fail2ban; then
        print_ok "Fail2Ban настроен и запущен для порта $ssh_port"
        
        # Показываем статус jail
        sleep 2
        if fail2ban-client status sshd >/dev/null 2>&1; then
            print_ok "SSH jail активен в Fail2Ban"
        fi
    else
        print_err "Ошибка запуска Fail2Ban"
        return 1
    fi
    
    return 0
}

# Настройка файрвола UFW
configure_firewall() {
    local ssh_port="$1"
    
    print_info "Настраиваем файрвол UFW..."
    
    # Устанавливаем UFW если не установлен
    if ! command -v ufw >/dev/null 2>&1; then
        print_info "Устанавливаем UFW..."
        apt-get update -qq
        apt-get install -y ufw
    fi
    
    # Сбрасываем правила UFW и настраиваем заново
    ufw --force reset >/dev/null 2>&1
    
    # Настройки по умолчанию
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    
    # Разрешаем новый SSH порт
    if ufw allow "$ssh_port/tcp" >/dev/null 2>&1; then
        print_ok "Разрешен SSH порт $ssh_port в файрволе"
    else
        print_err "Ошибка добавления правила для порта $ssh_port"
        return 1
    fi
    
    # Пока не включаем файрвол - дождемся проверки SSH
    print_info "Файрвол настроен, но пока не активирован"
    return 0
}

# Тестирование SSH соединения
test_ssh_connection() {
    local user="$1"
    local port="$2"
    
    print_warn "ВАЖНО: Протестируйте SSH соединение перед закрытием текущей сессии!"
    print_info "Откройте новый терминал и выполните:"
    echo "  ssh -p $port $user@$(hostname -I | awk '{print $1}')"
    echo
    print_info "Или если у вас есть доменное имя:"
    echo "  ssh -p $port $user@$(hostname -f 2>/dev/null || hostname)"
    echo
    
    while true; do
        read -r -p "SSH соединение работает? Можете войти под новым пользователем? (y/n): " ssh_works
        case "$ssh_works" in
            [Yy]*)
                print_ok "SSH соединение подтверждено"
                return 0
                ;;
            [Nn]*)
                print_err "SSH соединение не работает. Проверьте настройки."
                print_info "Проверьте:"
                echo "  1. Правильность ключа"
                echo "  2. Права доступа к файлам"
                echo "  3. Логи: tail -f /var/log/auth.log"
                echo "  4. Статус SSH: systemctl status ssh"
                
                read -r -p "Попробовать еще раз? (y/n): " retry
                if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                    return 1
                fi
                ;;
            *)
                print_err "Введите y или n"
                ;;
        esac
    done
}

# Финализация настройки
finalize_setup() {
    local ssh_port="$1"
    
    print_info "Завершаем настройку безопасности..."
    
    # Перезапускаем SSH службу
    print_info "Перезапускаем SSH службу..."
    if systemctl restart ssh; then
        print_ok "SSH служба перезапущена"
    else
        print_err "Ошибка перезапуска SSH службы"
        return 1
    fi
    
    # Активируем файрвол и блокируем старый порт 22
    print_info "Активируем файрвол и блокируем порт 22..."
    
    # Включаем UFW
    if ufw --force enable >/dev/null 2>&1; then
        print_ok "Файрвол UFW активирован"
        
        # Показываем статус файрвола
        print_info "Статус файрвола:"
        ufw status numbered
        
    else
        print_err "Ошибка активации файрвола"
        return 1
    fi
    
    # Обновляем конфигурацию SSH - убираем временные порты
    print_info "Обновляем финальную конфигурацию SSH..."
    
    # Убеждаемся что порт 22 заблокирован в конфигурации
    sed -i '/^Port 22$/d' /etc/ssh/sshd_config
    
    # Финальная проверка конфигурации и перезапуск
    if sshd -t && systemctl reload ssh; then
        print_ok "SSH конфигурация финализирована"
    else
        print_warn "Предупреждение: Проблема с финальной конфигурацией SSH"
    fi
    
    return 0
}

# Основная функция настройки SSH
secure_ssh_setup() {
    local selected_user=""
    local ssh_port=""
    
    print_info "=== Безопасная настройка SSH для Ubuntu ==="
    print_info "Данный скрипт выполнит:"
    echo "  - Проверку существующих пользователей"
    echo "  - Создание/настройку пользователя с sudo правами"
    echo "  - Настройку SSH ключей"
    echo "  - Изменение SSH порта"
    echo "  - Настройку Fail2Ban"
    echo "  - Настройку файрвола UFW"
    echo "  - Блокировку root входа"
    echo
    
    read -r -p "Продолжить? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Настройка отменена"
        return 0
    fi
    
    # Проверяем что мы root
    if [[ $EUID -ne 0 ]]; then
        print_err "Скрипт должен запускаться от имени root"
        return 1
    fi
    
    # Шаг 1: Проверка существующих пользователей
    print_info "\n=== Шаг 1: Проверка пользователей ==="
    if ! check_existing_sudo_users; then
        # Создаем нового пользователя
        print_info "\n=== Создание нового пользователя ==="
        if ! create_new_user; then
            print_err "Ошибка создания пользователя"
            return 1
        fi
    fi
    
    selected_user="$SELECTED_USER"
    print_ok "Выбран пользователь: $selected_user"
    
    # Шаг 2: Настройка SSH ключей
    print_info "\n=== Шаг 2: Настройка SSH ключей ==="
    if ! setup_ssh_keys "$selected_user"; then
        print_err "Ошибка настройки SSH ключей"
        return 1
    fi
    
    # Шаг 3: Настройка SSH порта
    print_info "\n=== Шаг 3: Настройка SSH порта ==="
    if ! configure_ssh_port; then
        print_err "Ошибка настройки SSH порта"
        return 1
    fi
    
    ssh_port="$SSH_PORT"
    
    # Шаг 4: Настройка Fail2Ban
    print_info "\n=== Шаг 4: Настройка Fail2Ban ==="
    if ! configure_fail2ban "$ssh_port"; then
        print_warn "Предупреждение: Ошибка настройки Fail2Ban (можно настроить позже)"
    fi
    
    # Шаг 5: Настройка файрвола
    print_info "\n=== Шаг 5: Настройка файрвола ==="
    if ! configure_firewall "$ssh_port"; then
        print_err "Ошибка настройки файрвола"
        return 1
    fi
    
    # Шаг 6: Тестирование SSH
    print_info "\n=== Шаг 6: Тестирование SSH соединения ==="
    if ! test_ssh_connection "$selected_user" "$ssh_port"; then
        print_err "SSH соединение не работает. Настройка не завершена."
        print_info "Текущая сессия остается активной для исправления проблем"
        return 1
    fi
    
    # Шаг 7: Финализация
    print_info "\n=== Шаг 7: Финализация настройки ==="
    if ! finalize_setup "$ssh_port"; then
        print_warn "Предупреждение: Проблемы при финализации"
    fi
    
    # Итоговая информация
    print_ok "\n=== НАСТРОЙКА SSH ЗАВЕРШЕНА УСПЕШНО ==="
    echo
    print_info "Настройки:"
    echo "  • Пользователь: $selected_user"
    echo "  • SSH порт: $ssh_port"
    echo "  • Root login: отключен"
    echo "  • Password auth: отключена"
    echo "  • Fail2Ban: активен"
    echo "  • UFW firewall: активен"
    echo
    print_info "Для подключения используйте:"
    echo "  ssh -p $ssh_port $selected_user@$(hostname -I | awk '{print $1}')"
    echo
    print_warn "ВАЖНЫЕ РЕКОМЕНДАЦИИ:"
    echo "  • Сохраните информацию о новом порте и пользователе"
    echo "  • Убедитесь что SSH ключ сохранен в безопасном месте"
    echo "  • Регулярно обновляйте систему: apt update && apt upgrade"
    echo "  • Мониторьте логи: tail -f /var/log/auth.log"
    echo "  • Проверяйте статус Fail2Ban: fail2ban-client status"
    echo
    print_ok "Сервер настроен безопасно. Текущую сессию можно закрыть."
    
    return 0
}

# Функция для экстренного восстановления SSH (если что-то пошло не так)
emergency_ssh_restore() {
    print_warn "=== ЭКСТРЕННОЕ ВОССТАНОВЛЕНИЕ SSH ==="
    print_info "Эта функция восстанавливает SSH к базовым настройкам"
    
    read -r -p "Продолжить восстановление? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    fi
    
    # Восстанавливаем порт 22
    print_info "Восстанавливаем SSH порт 22..."
    sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config
    
    # Временно разрешаем root login для восстановления
    print_info "Временно разрешаем root login..."
    sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
    
    # Разрешаем пароли для восстановления
    print_info "Временно разрешаем password authentication..."
    sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    # Перезапускаем SSH
    if systemctl restart ssh; then
        print_ok "SSH служба перезапущена"
    else
        print_err "Ошибка перезапуска SSH"
        return 1
    fi
    
    # Открываем порт 22 в файрволе
    if command -v ufw >/dev/null 2>&1; then
        print_info "Открываем порт 22 в файрволе..."
        ufw allow 22/tcp >/dev/null 2>&1
        print_ok "Порт 22 открыт в UFW"
    fi
    
    print_ok "SSH восстановлен к базовым настройкам"
    print_warn "ВНИМАНИЕ: Сервер сейчас менее безопасен"
    print_info "Подключитесь через: ssh root@server_ip"
    print_info "После восстановления доступа запустите настройку заново"
    
    return 0
}

# Функция для показа текущего статуса SSH
show_ssh_status() {
    print_info "=== СТАТУС SSH КОНФИГУРАЦИИ ==="
    
    # SSH служба
    echo "SSH служба:"
    if systemctl is-active --quiet ssh; then
        print_ok "  SSH служба активна"
    else
        print_err "  SSH служба неактивна"
    fi
    
    # SSH порт
    local current_port
    current_port=$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "22")
    print_info "  Текущий порт: $current_port"
    
    # Root login
    local root_login
    root_login=$(grep -E '^PermitRootLogin ' /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "yes")
    if [[ "$root_login" == "no" ]]; then
        print_ok "  Root login: отключен"
    else
        print_warn "  Root login: разрешен"
    fi
    
    # Password authentication
    local pass_auth
    pass_auth=$(grep -E '^PasswordAuthentication ' /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "yes")
    if [[ "$pass_auth" == "no" ]]; then
        print_ok "  Password auth: отключена"
    else
        print_warn "  Password auth: включена"
    fi
    
    # Fail2Ban
    echo
    echo "Fail2Ban:"
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            print_ok "  Fail2Ban активен"
            if fail2ban-client status sshd >/dev/null 2>&1; then
                local banned_count
                banned_count=$(fail2ban-client status sshd | grep "Currently banned" | awk '{print $4}')
                print_info "  SSH jail активен, заблокировано IP: $banned_count"
            fi
        else
            print_warn "  Fail2Ban установлен, но неактивен"
        fi
    else
        print_warn "  Fail2Ban не установлен"
    fi
    
    # UFW
    echo
    echo "UFW Firewall:"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(ufw status | head -1 | awk '{print $2}')
        if [[ "$ufw_status" == "active" ]]; then
            print_ok "  UFW активен"
            print_info "  Открытые порты:"
            ufw status numbered | grep -E "ALLOW|DENY" | head -10
        else
            print_warn "  UFW неактивен"
        fi
    else
        print_warn "  UFW не установлен"
    fi
    
    # Пользователи с sudo
    echo
    echo "Пользователи с sudo правами:"
    local sudo_users
    sudo_users=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^)
    if [[ -n "$sudo_users" ]]; then
        while read -r user; do
            if [[ "$user" != "root" ]]; then
                print_info "  • $user"
            fi
        done <<< "$sudo_users"
    else
        print_warn "  Пользователи с sudo не найдены"
    fi
    
    echo
}

# Функция для быстрой проверки безопасности
security_check() {
    print_info "=== ПРОВЕРКА БЕЗОПАСНОСТИ SSH ==="
    
    local issues=0
    
    # Проверяем SSH конфигурацию
    print_info "Проверяем SSH конфигурацию..."
    
    # Root login
    if grep -E '^PermitRootLogin yes' /etc/ssh/sshd_config >/dev/null 2>&1; then
        print_warn "  ⚠ Root login разрешен"
        ((issues++))
    else
        print_ok "  ✓ Root login отключен"
    fi
    
    # Password authentication
    if grep -E '^PasswordAuthentication yes' /etc/ssh/sshd_config >/dev/null 2>&1; then
        print_warn "  ⚠ Password authentication включена"
        ((issues++))
    else
        print_ok "  ✓ Password authentication отключена"
    fi
    
    # SSH порт
    local ssh_port
    ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "22")
    if [[ "$ssh_port" == "22" ]]; then
        print_warn "  ⚠ Используется стандартный порт 22"
        ((issues++))
    else
        print_ok "  ✓ Используется нестандартный порт $ssh_port"
    fi
    
    # Fail2Ban
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        print_warn "  ⚠ Fail2Ban не активен"
        ((issues++))
    else
        print_ok "  ✓ Fail2Ban активен"
    fi
    
    # UFW
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
    if [[ "$ufw_status" != "active" ]]; then
        print_warn "  ⚠ UFW firewall не активен"
        ((issues++))
    else
        print_ok "  ✓ UFW firewall активен"
    fi
    
    # Root authorized_keys
    if [[ -f /root/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
        print_warn "  ⚠ У root есть SSH ключи"
        ((issues++))
    else
        print_ok "  ✓ У root нет SSH ключей"
    fi
    
    echo
    if [[ $issues -eq 0 ]]; then
        print_ok "✓ Проверка безопасности пройдена успешно"
    else
        print_warn "⚠ Найдено проблем безопасности: $issues"
        print_info "Рекомендуется запустить secure_ssh_setup для исправления"
    fi
    
    return $issues
}

# Вызов основной функции (раскомментируйте для запуска)
# secure_ssh_setup

# Альтернативные функции для администрирования:
# emergency_ssh_restore  # Для экстренного восстановления
# show_ssh_status       # Для показа текущего статуса
# security_check        # Для быстрой проверки безопасности
