#!/bin/bash

# secure_ssh_setup.sh
# Интерактивный скрипт для безопасной настройки SSH на Ubuntu
# Запускать только от root!

set -euo pipefail

# Цветовые коды для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен быть запущен с правами root!"
    print_error "Используйте: sudo $0"
    exit 1
fi

print_info "=== Безопасная настройка SSH на Ubuntu ==="
print_info "Скрипт создаст нового пользователя с sudo, настроит SSH-ключи и изменит порт"

# Функция для проверки имени пользователя
validate_username() {
    local username=$1
    local regex='^[a-z_][a-z0-9._-]{0,31}$'
    
    if [[ ! $username =~ $regex ]]; then
        return 1
    fi
    
    if id "$username" &>/dev/null; then
        return 2
    fi
    
    return 0
}

# Функция для проверки порта
validate_port() {
    local port=$1
    
    if ! [[ $port =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if (( port < 1024 || port > 65535 )); then
        return 2
    fi
    
    if ss -tulnp | grep -q ":$port "; then
        return 3
    fi
    
    return 0
}

# Функция для проверки SSH ключа
validate_ssh_key() {
    local key=$1
    
    # Проверка на приватный ключ
    if echo "$key" | grep -q "BEGIN.*PRIVATE KEY"; then
        return 1
    fi
    
    # Проверка формата OpenSSH
    if echo "$key" | grep -Eq "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)"; then
        return 0
    fi
    
    # Проверка формата SSH2
    if echo "$key" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
        return 0
    fi
    
    return 2
}

# 1. Создание нового пользователя
while true; do
    read -p "Введите имя нового пользователя с sudo-правами: " username
    
    if validate_username "$username"; then
        break
    elif [[ $? -eq 2 ]]; then
        print_error "Пользователь '$username' уже существует. Выберите другое имя."
    else
        print_error "Неверный формат имени пользователя. Используйте только строчные буквы, цифры, дефис и подчеркивание."
    fi
done

print_info "Создаю пользователя: $username"
useradd -m -s /bin/bash "$username"
usermod -aG sudo "$username"
print_success "Пользователь $username создан и добавлен в группу sudo"

# 2. Настройка SSH-ключей
print_info "\n=== Настройка SSH-ключей ==="

# Проверка наличия ключа у root
root_key=""
if [[ -f /root/.ssh/id_ed25519.pub ]]; then
    root_key="/root/.ssh/id_ed25519.pub"
elif [[ -f /root/.ssh/id_rsa.pub ]]; then
    root_key="/root/.ssh/id_rsa.pub"
elif [[ -f /root/.ssh/id_ecdsa.pub ]]; then
    root_key="/root/.ssh/id_ecdsa.pub"
fi

ssh_key=""

if [[ -n "$root_key" ]]; then
    print_info "Найден SSH-ключ для root: $root_key"
    read -p "Перенести этот ключ к новому пользователю $username? (yes/no): " use_root_key
    
    if [[ "$use_root_key" == "yes" ]]; then
        ssh_key=$(cat "$root_key")
        print_success "Ключ будет перенесен к пользователю $username"
    fi
fi

if [[ -z "$ssh_key" ]]; then
    print_info "Выберите способ получения SSH-ключа:"
    echo "1 - Ввести свой существующий публичный ключ"
    echo "2 - Сгенерировать новый ключ"
    
    while true; do
        read -p "Ваш выбор (1/2): " choice
        
        case $choice in
            1)
                print_info "Введите ваш публичный SSH-ключ (одной строкой или многострочно)."
                print_info "Поддерживаются форматы OpenSSH и SSH2."
                print_info "После ввода нажмите Enter, затем Ctrl+D:"
                
                # Чтение многострочного ввода
                key_input=$(cat)
                
                # Конвертация SSH2 в OpenSSH если необходимо
                if echo "$key_input" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
                    print_info "Обнаружен формат SSH2. Конвертирую в OpenSSH..."
                    ssh_key=$(echo "$key_input" | ssh-keygen -i -f /dev/stdin 2>/dev/null || echo "")
                    
                    if [[ -z "$ssh_key" ]]; then
                        print_error "Ошибка конвертации ключа SSH2"
                        continue
                    fi
                else
                    ssh_key="$key_input"
                fi
                
                if validate_ssh_key "$ssh_key"; then
                    break
                else
                    print_error "Неверный формат SSH-ключа или введен приватный ключ!"
                    print_error "Пожалуйста, введите корректный публичный ключ."
                fi
                ;;
            2)
                print_info "Генерирую новый ключ Ed25519 для пользователя $username..."
                
                # Создаем ключи во временной директории
                temp_dir=$(mktemp -d)
                ssh-keygen -t ed25519 -f "$temp_dir/id_ed25519" -N "" -C "$username@$(hostname)"
                
                ssh_key=$(cat "$temp_dir/id_ed25519.pub")
                private_key=$(cat "$temp_dir/id_ed25519")
                
                print_success "Новый ключ сгенерирован!"
                print_warning "ВАЖНО: Сохраните приватный ключ себе:"
                echo "----------------------------------------"
                echo "$private_key"
                echo "----------------------------------------"
                print_warning "Сохраните это в файл ~/.ssh/id_ed25519 на вашем компьютере!"
                
                rm -rf "$temp_dir"
                break
                ;;
            *)
                print_error "Неверный выбор. Пожалуйста, введите 1 или 2."
                ;;
        esac
    done
fi

# Добавление ключа в authorized_keys
print_info "Настраиваю SSH-ключ для пользователя $username..."
mkdir -p "/home/$username/.ssh"
echo "$ssh_key" >> "/home/$username/.ssh/authorized_keys"
chmod 700 "/home/$username/.ssh"
chmod 600 "/home/$username/.ssh/authorized_keys"
chown -R "$username:$username" "/home/$username/.ssh"
print_success "SSH-ключ добавлен для пользователя $username"

# 3. Изменение порта SSH
print_info "\n=== Изменение порта SSH ==="

while true; do
    read -p "Введите новый порт для SSH (1024-65535): " new_port
    
    if validate_port "$new_port"; then
        break
    elif [[ $? -eq 3 ]]; then
        print_error "Порт $new_port уже используется. Выберите другой."
    else
        print_error "Неверный номер порта. Используйте число от 1024 до 65535."
    fi
done

# 4. Настройка SSH конфигурации
print_info "\n=== Настройка безопасности SSH ==="

# Создание резервной копии
backup_file="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$backup_file"
print_success "Создана резервная копия: $backup_file"

# Проверка корректности конфигурации перед изменениями
if ! sshd -t -f "$backup_file"; then
    print_error "Ошибка в текущей конфигурации SSH. Пожалуйста, исправьте вручную."
    exit 1
fi

# Применение изменений
print_info "Применяю безопасные настройки..."

# Изменение порта
sed -i "s/^#\?Port.*/Port $new_port/" /etc/ssh/sshd_config

# Запрет входа по паролю
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

# Запрет входа root
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Запрет входа по паролю для root
sed -i 's/^#\?PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

# Разрешение входа только для нового пользователя
if ! grep -q "^AllowUsers" /etc/ssh/sshd_config; then
    echo "AllowUsers $username" >> /etc/ssh/sshd_config
else
    sed -i "s/^AllowUsers.*/AllowUsers $username/" /etc/ssh/sshd_config
fi

# Отключение аутентификации по паролю для всех пользователей
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

print_success "Конфигурация SSH обновлена"

# 5. Проверка работоспособности
print_warning "\nВАЖНО! Проверьте работоспособность нового порта перед продолжением."
print_info "Откройте новое окно терминала и выполните:"
print_info "ssh -p $new_port $username@$(hostname -I | awk '{print $1}')"
print_info "Если подключение успешно, вернитесь сюда и продолжите."

while true; do
    read -p "Вы успешно подключились по новому порту? Введите 'yes' для продолжения: " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        break
    else
        print_error "Пожалуйста, проверьте подключение и введите 'yes' для продолжения."
    fi
done

# 6. Перезапуск службы SSH
print_info "Перезапускаю службу SSH..."
systemctl restart sshd
systemctl status sshd --no-pager -l

print_success "\n=== Настройка завершена успешно! ==="
print_info "Теперь SSH доступен:"
print_info "  - Порт: $new_port"
print_info "  - Пользователь: $username"
print_info "  - Только ключевая аутентификация"
print_info "  - Root-доступ запрещен"
print_info ""
print_warning "Не забудьте:"
print_warning "  1. Настроить файрвол для нового порта $new_port"
print_warning "  2. Сохранить приватный ключ если вы его сгенерировали"
print_warning "  3. Закрыть старый порт 22 в файрволе"
