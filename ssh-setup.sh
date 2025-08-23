#!/bin/bash

# secure_ssh_setup_v2.sh
# Исправленный и улучшенный скрипт для безопасной настройки SSH
# Запускать только от root!

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен быть запущен с правами root!"
    exit 1
fi

print_info "=== Безопасная настройка SSH ==="

# Валидация имени пользователя
validate_username() {
    local name=$1
    [[ $name =~ ^[a-z_][a-z0-9._-]{0,31}$ ]] && ! id "$name" &>/dev/null
}

while true; do
    read -p "Введите имя нового пользователя: " username
    if validate_username "$username"; then
        break
    else
        print_error "Неверное имя или пользователь уже существует."
    fi
done

print_info "Создаю пользователя: $username"
useradd -m -s /bin/bash "$username"
usermod -aG sudo "$username"
print_success "Пользователь $username создан и добавлен в sudo"

# --- Проверка и перенос ключа у root ---
print_info "\n=== Проверка SSH-ключей у root ==="

root_key_file=""
for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub; do
    [[ -f "$f" ]] && root_key_file="$f" && break
done

ssh_key=""

if [[ -n "$root_key_file" ]]; then
    print_info "Найден SSH-ключ у root: $root_key_file"
    print_info "Выберите действие:"
    echo "1 - Перенести этот ключ к новому пользователю и удалить у root"
    echo "2 - Ввести свой ключ"
    echo "3 - Сгенерировать новый ключ"

    while true; do
        read -p "Ваш выбор (1/2/3): " choice
        case $choice in
            1)
                ssh_key=$(cat "$root_key_file")
                rm -f "$root_key_file"
                rm -f "${root_key_file%.pub}"
                print_success "Ключ перенесён и удалён у root"
                break
                ;;
            2)
                print_info "Введите публичный ключ (OpenSSH или SSH2), затем Ctrl+D:"
                key_input=$(cat)
                if echo "$key_input" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
                    ssh_key=$(echo "$key_input" | ssh-keygen -i -f /dev/stdin 2>/dev/null)
                else
                    ssh_key="$key_input"
                fi
                if [[ -n "$ssh_key" ]]; then
                    break
                else
                    print_error "Ошибка в формате ключа."
                fi
                ;;
            3)
                temp_dir=$(mktemp -d)
                ssh-keygen -t ed25519 -f "$temp_dir/id_ed25519" -N "" -C "$username@$(hostname)"
                ssh_key=$(cat "$temp_dir/id_ed25519.pub")
                print_success "Ключ сгенерирован:"
                cat "$temp_dir/id_ed25519"
                rm -rf "$temp_dir"
                break
                ;;
            *)
                print_error "Выберите 1, 2 или 3"
                ;;
        esac
    done
else
    print_info "Ключ у root не найден."
    print_info "Выберите:"
    echo "1 - Ввести свой ключ"
    echo "2 - Сгенерировать новый"

    while true; do
        read -p "Ваш выбор (1/2): " choice
        case $choice in
            1)
                print_info "Введите публичный ключ, затем Ctrl+D:"
                key_input=$(cat)
                if echo "$key_input" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
                    ssh_key=$(echo "$key_input" | ssh-keygen -i -f /dev/stdin 2>/dev/null)
                else
                    ssh_key="$key_input"
                fi
                [[ -n "$ssh_key" ]] && break
                print_error "Ошибка в формате ключа."
                ;;
            2)
                temp_dir=$(mktemp -d)
                ssh-keygen -t ed25519 -f "$temp_dir/id_ed25519" -N "" -C "$username@$(hostname)"
                ssh_key=$(cat "$temp_dir/id_ed25519.pub")
                print_success "Ключ сгенерирован:"
                cat "$temp_dir/id_ed25519"
                rm -rf "$temp_dir"
                break
                ;;
            *)
                print_error "Выберите 1 или 2"
                ;;
        esac
    done
fi

mkdir -p "/home/$username/.ssh"
echo "$ssh_key" >> "/home/$username/.ssh/authorized_keys"
chmod 700 "/home/$username/.ssh"
chmod 600 "/home/$username/.ssh/authorized_keys"
chown -R "$username:$username" "/home/$username/.ssh"
print_success "SSH-ключ добавлен для $username"

# --- Изменение порта ---
print_info "\n=== Изменение порта SSH ==="

validate_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) && ! ss -tulnp | grep -q ":$port "
}

while true; do
    read -p "Введите новый порт SSH (1024-65535): " new_port
    if validate_port "$new_port"; then
        break
    else
        print_error "Порт занят или недопустим."
    fi
done

backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$backup"
print_success "Создана резервная копия: $backup"

# Открытие порта в UFW (если включён)
if systemctl is-active --quiet ufw; then
    print_info "Открываю порт $new_port в UFW..."
    ufw allow "$new_port/tcp" >/dev/null 2>&1 || true
fi

# Применение настроек
sed -i "s/^#\?Port.*/Port $new_port/" /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^AllowUsers" /etc/ssh/sshd_config && \
    sed -i "s/^AllowUsers.*/AllowUsers $username/" /etc/ssh/sshd_config || \
    echo "AllowUsers $username" >> /etc/ssh/sshd_config

# Проверка конфигурации
if ! sshd -t; then
    print_error "Ошибка в конфигурации SSH. Восстановление из резервной копии..."
    cp "$backup" /etc/ssh/sshd_config
    systemctl restart sshd
    exit 1
fi

systemctl restart sshd
print_success "SSH перезапущен на порту $new_port"

# --- Проверка подключения ---
print_warning "\nВАЖНО: Проверьте подключение перед закрытием порта 22"
print_info "Команда для проверки:"
print_info "ssh -p $new_port $username@$(hostname -I | awk '{print $1}')"

while true; do
    read -p "Вы успешно подключились по новому порту? Введите 'yes': " confirm
    [[ "$confirm" == "yes" ]] && break
    print_error "Проверьте подключение и введите 'yes'"
done

# Закрытие порта 22 в UFW (если включён)
if systemctl is-active --quiet ufw; then
    print_info "Закрываю порт 22 в UFW..."
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
fi

print_success "\n=== Готово ==="
print_info "Доступ только по:"
print_info "  Порт: $new_port"
print_info "  Пользователь: $username"
print_info "  Только по ключу"
