#!/bin/bash
# ssh-setup.sh
# Безопасная настройка SSH: создание пользователя, ключей, смена порта
# Поддержка --port — переход к выбору порта без создания пользователя

set -euo pipefail

# ----------------------------------------------------------
# 0. Подготовка системы: обновления, чистка, фаервол, fail2ban
# ----------------------------------------------------------

# Обновляем список пакетов
DEBIAN_FRONTEND=noninteractive sudo apt update -y
DEBIAN_FRONTEND=noninteractive sudo apt install -y openssh-server

# Обновляем уже установленные пакеты
DEBIAN_FRONTEND=noninteractive sudo apt -y upgrade
DEBIAN_FRONTEND=noninteractive sudo apt -y full-upgrade || true

# Чистим старые/ненужные зависимости
sudo dpkg --configure -a || true
DEBIAN_FRONTEND=noninteractive sudo apt -f install -y || true
DEBIAN_FRONTEND=noninteractive sudo apt -y autoremove --purge
DEBIAN_FRONTEND=noninteractive sudo apt -y autoclean

# Устанавливаем UFW и разрешаем нужные порты
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   # SSH
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS
ufw --force enable

# Устанавливаем fail2ban
apt-get install -y fail2ban

# Создаём простой локальный конфиг для защиты SSH от брутфорса
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
EOF

# Перезапускаем fail2ban, чтобы применить конфигурацию
systemctl enable fail2ban
systemctl restart fail2ban

# Настройка пользователя

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

[[ $EUID -ne 0 ]] && { print_error "Запустите скрипт от root: sudo $0"; exit 1; }

SKIP=false
[[ "${1:-}" == "--port" ]] && SKIP=true

validate_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 65535 )) && ! ss -tulnp | grep -q ":$port "
}

# --- Выбор/создание пользователя ---
if [[ "$SKIP" == true ]]; then
    read -p "Введите имя существующего пользователя: " username
    id "$username" &>/dev/null || { print_error "Пользователь '$username' не найден"; exit 1; }
else
    read -p "Введите имя нового пользователя: " username
    while ! [[ $username =~ ^[a-z_][a-z0-9._-]{0,31}$ ]] || id "$username" &>/dev/null; do
        print_error "Неверное имя или пользователь существует"
        read -p "Введите имя нового пользователя: " username
    done
    useradd -m -s /bin/bash "$username"
    usermod -aG sudo "$username"
    echo "$username ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/"$username"
sudo chmod 440 /etc/sudoers.d/"$username"
    print_success "Пользователь $username создан"
fi

# --- SSH-ключи (только в обычном режиме) ---
if [[ "$SKIP" != true ]]; then
    print_info "\n=== Настройка SSH-ключей ==="

    root_key=""
    for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub /root/.ssh/authorized_keys; do
        [[ -f "$f" ]] && root_key="$f" && break
    done

    ssh_key=""

    if [[ -n "$root_key" ]]; then
        print_info "Найден ключ у root: $root_key"
        print_info "Выберите:"
        echo "1 - Перенести ключ к пользователю и удалить у root"
        echo "2 - Ввести свой ключ"
        echo "3 - Сгенерировать новый ключ"

        while true; do
            read -p "Ваш выбор (1/2/3): " choice
            case $choice in
                1)
                    ssh_key=$(cat "$root_key")
                    rm -f "$root_key" "${root_key%.pub}"
                    print_success "Ключ перенесён и удалён у root"
                    break
                    ;;
                2)
                    print_info "Введите публичный ключ, затем Ctrl+D:"
                    key_input=$(cat)
                    if echo "$key_input" | grep -q "BEGIN SSH2 PUBLIC KEY"; then
                        ssh_key=$(echo "$key_input" | ssh-keygen -i -f /dev/stdin 2>/dev/null)
                    else
                        ssh_key="$key_input"
                    fi
                    [[ -n "$ssh_key" ]] && break
                    print_error "Ошибка в формате ключа"
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
        print_info "Ключ у root не найден"
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
                    print_error "Ошибка в формате ключа"
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
    print_success "SSH-ключ добавлен"
fi

# --- Порт SSH ---
print_info "\n=== Изменение порта SSH ==="
while true; do
    read -p "Введите новый порт (1024-65535) или 'no' для выхода: " new_port
    [[ "$new_port" == "no" ]] && exit 0
    if validate_port "$new_port"; then
        break
    else
        print_error "Порт недопустим или занят"
    fi
done

backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$backup"
print_success "Резервная копия: $backup"

systemctl is-active --quiet ufw && ufw allow "$new_port/tcp" >/dev/null 2>&1 || true

sed -i "s/^#\?Port.*/Port $new_port/" /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q "^AllowUsers" /etc/ssh/sshd_config && \
    sed -i "s/^AllowUsers.*/AllowUsers $username/" /etc/ssh/sshd_config || \
    echo "AllowUsers $username" >> /etc/ssh/sshd_config

install -d -m 0755 -o root -g root /run/sshd
sshd -t || { print_error "Ошибка конфигурации"; exit 1; }
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
systemctl restart ssh

print_info "SSH перезапущен на порту $new_port"
print_info "Проверьте: ssh -p $new_port $username@$(hostname -I | awk '{print $1}')"

systemctl is-active --quiet ufw && ufw delete allow 22/tcp >/dev/null 2>&1 || true

print_success "\n=== Готово ==="
print_info "  Порт: $new_port"
print_info "  Пользователь: $username"
print_info "  Только по ключу"
