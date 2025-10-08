#!/bin/bash

# Автоматическая установка и настройка веб-сервера на Ubuntu 24.04
# Включает: Apache, MariaDB, PHP 8.4, WordPress, phpMyAdmin, SSL-сертификаты
# Версия: 2.0 с исправлениями ошибок

set -e  # Остановить выполнение при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Функция генерации безопасных паролей
generate_password() {
    local length=${1:-16}
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+=' | head -c $length
}

# Функция проверки DNS
check_dns() {
    local domain=$1
    print_status "Проверка DNS для $domain..."
    
    if command -v dig > /dev/null; then
        if dig +short $domain | grep -q '^[0-9]'; then
            print_status "✓ DNS запись для $domain найдена"
            return 0
        else
            print_warning "✗ DNS запись для $domain не найдена"
            return 1
        fi
    else
        print_warning "Утилита dig не найдена, пропускаем проверку DNS"
        return 0
    fi
}

# Функция безопасной замены WordPress солей
replace_wordpress_salts() {
    local wp_config_path=$1
    local temp_file=$(mktemp)
    
    print_status "Получение новых WordPress солей..."
    
    # Скачиваем соли
    if curl -s https://api.wordpress.org/secret-key/1.1/salt/ > "$temp_file"; then
        print_status "Замена солей в wp-config.php..."
        
        # Удаляем старые строки с солями
        sed -i '/AUTH_KEY/d' "$wp_config_path"
        sed -i '/SECURE_AUTH_KEY/d' "$wp_config_path"
        sed -i '/LOGGED_IN_KEY/d' "$wp_config_path"
        sed -i '/NONCE_KEY/d' "$wp_config_path"
        sed -i '/AUTH_SALT/d' "$wp_config_path"
        sed -i '/SECURE_AUTH_SALT/d' "$wp_config_path"
        sed -i '/LOGGED_IN_SALT/d' "$wp_config_path"
        sed -i '/NONCE_SALT/d' "$wp_config_path"
        sed -i '/put your unique phrase here/d' "$wp_config_path"
        
        # Вставляем новые соли перед строкой $table_prefix
        sed -i "/\$table_prefix/i\\$(cat $temp_file)" "$wp_config_path"
        
        rm "$temp_file"
        print_status "✓ Соли WordPress успешно обновлены"
    else
        print_warning "Не удалось получить соли WordPress. Используйте значения по умолчанию."
        rm -f "$temp_file"
    fi
}

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    print_error "Пожалуйста, запустите скрипт с правами суперпользователя (sudo)"
    exit 1
fi

print_header "Автоматическая установка веб-сервера на Ubuntu 24.04"
echo "=================================================="

# Обновление системы
print_header "Шаг 1: Обновление системы"
apt update && apt upgrade -y

# Установка необходимых пакетов
print_header "Шаг 2: Установка базовых пакетов"
apt install -y software-properties-common curl wget unzip ufw certbot python3-certbot-apache dnsutils openssl

# Генерация паролей
print_header "Шаг 3: Генерация безопасных паролей"
MYSQL_ROOT_PASSWORD=$(generate_password 20)
WP_DB_PASSWORD=$(generate_password 16)

echo ""
print_status "🔐 Сгенерированы безопасные пароли:"
echo "=================================================="
echo "MySQL root пароль: $MYSQL_ROOT_PASSWORD"
echo "WordPress DB пароль: $WP_DB_PASSWORD"
echo "=================================================="
echo ""
print_warning "⚠️  ОБЯЗАТЕЛЬНО СОХРАНИТЕ ЭТИ ПАРОЛИ В БЕЗОПАСНОМ МЕСТЕ!"
echo ""
read -p "Нажмите Enter для продолжения после сохранения паролей..."

# Установка Apache
print_header "Шаг 4: Установка Apache веб-сервера"
apt install -y apache2

# Включение и запуск Apache
systemctl enable apache2
systemctl start apache2
print_status "✓ Apache успешно установлен и запущен"

# Настройка файрвола UFW
print_header "Шаг 5: Настройка файрвола UFW"
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
print_status "✓ Файрвол настроен"

# Установка MariaDB
print_header "Шаг 6: Установка MariaDB"
apt install -y mariadb-server

# Включение и запуск MariaDB
systemctl enable mariadb
systemctl start mariadb
print_status "✓ MariaDB установлена и запущена"

# Автоматическая настройка безопасности MariaDB
print_header "Шаг 7: Настройка безопасности MariaDB"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';" 2>/dev/null || \
mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$MYSQL_ROOT_PASSWORD');"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
print_status "✓ Безопасность MariaDB настроена"

# Создание пользователя WordPress в базе данных
print_header "Шаг 8: Создание базы данных WordPress"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
print_status "✓ База данных WordPress создана"

# Установка PHP 8.4 и расширений
print_header "Шаг 9: Установка PHP 8.4 и расширений"
add-apt-repository ppa:ondrej/php -y
apt update

apt install -y php8.4 php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-mbstring \
php8.4-soap php8.4-xml php8.4-xmlrpc php8.4-zip php8.4-imagick php8.4-cli \
php8.4-common php8.4-bcmath php8.4-fpm libapache2-mod-php8.4

# Включение модулей Apache
a2enmod rewrite
a2enmod ssl
a2enmod php8.4

# Отключение старых версий PHP если они есть
a2dismod php8.3 2>/dev/null || true
a2dismod php8.2 2>/dev/null || true
a2dismod php8.1 2>/dev/null || true

print_status "✓ Установлена PHP версия: $(php -v | head -1)"

# Запрос домена
print_header "Шаг 10: Настройка домена"
echo ""
while true; do
    read -p "Введите домен для вашего сайта (например, example.com): " DOMAIN
    if [ -n "$DOMAIN" ]; then
        break
    else
        print_error "Домен не может быть пустым!"
    fi
done

# Создание директории для сайта
print_status "Создание директории для сайта..."
mkdir -p /var/www/$DOMAIN
chown -R www-data:www-data /var/www/$DOMAIN
chmod -R 755 /var/www

# Создание виртуального хоста Apache
print_status "Создание виртуального хоста Apache..."
cat > /etc/apache2/sites-available/$DOMAIN.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@$DOMAIN
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/$DOMAIN
    
    <Directory /var/www/$DOMAIN>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF

# Включение сайта
a2ensite $DOMAIN.conf
a2dissite 000-default.conf

# Перезапуск Apache
systemctl reload apache2
print_status "✓ Виртуальный хост создан и активирован"

# Установка WordPress
print_header "Шаг 11: Скачивание и установка WordPress"
cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

# Копирование файлов WordPress
cp -R wordpress/* /var/www/$DOMAIN/
chown -R www-data:www-data /var/www/$DOMAIN
chmod -R 755 /var/www/$DOMAIN

# Создание wp-config.php
print_status "Настройка WordPress..."
cd /var/www/$DOMAIN
cp wp-config-sample.php wp-config.php

# Настройка wp-config.php с экранированием специальных символов
sed -i "s/database_name_here/wordpress/" wp-config.php
sed -i "s/username_here/wpuser/" wp-config.php
sed -i "s/password_here/$(echo "$WP_DB_PASSWORD" | sed 's/[[\.*^$()+?{|]/\\&/g')/" wp-config.php
sed -i "s/localhost/localhost/" wp-config.php

# Замена WordPress солей
replace_wordpress_salts "/var/www/$DOMAIN/wp-config.php"

print_status "✓ WordPress установлен и настроен"

# Запрос email для SSL
print_header "Шаг 12: Настройка SSL сертификатов"
echo ""
read -p "Введите email для уведомлений Let's Encrypt (оставьте пустым для пропуска SSL): " EMAIL

# Получение SSL-сертификата с проверкой DNS
SSL_SUCCESS=false
if [ -n "$EMAIL" ]; then
    print_status "Проверка DNS записей перед получением SSL сертификата..."
    
    # Проверяем основной домен
    if check_dns "$DOMAIN"; then
        CERT_DOMAINS="-d $DOMAIN"
        
        # Проверяем www поддомен
        if check_dns "www.$DOMAIN"; then
            CERT_DOMAINS="$CERT_DOMAINS -d www.$DOMAIN"
            print_status "Будем получать сертификат для: $DOMAIN и www.$DOMAIN"
        else
            print_warning "www.$DOMAIN не найден в DNS. Получаем сертификат только для $DOMAIN"
        fi
        
        # Получаем сертификат
        print_status "Получение SSL-сертификата Let's Encrypt..."
        if certbot --apache $CERT_DOMAINS --non-interactive --agree-tos --email "$EMAIL"; then
            print_status "✓ SSL-сертификат успешно получен"
            SSL_SUCCESS=true
            
            # Настройка автоматического обновления сертификатов
            systemctl enable certbot.timer
            systemctl start certbot.timer
            print_status "✓ Автоматическое обновление SSL сертификатов настроено"
        else
            print_error "Ошибка получения SSL сертификата"
            print_warning "Сайт будет работать по HTTP. SSL можно настроить позже."
        fi
    else
        print_error "Основной домен $DOMAIN не найден в DNS!"
        print_warning "Убедитесь, что A-запись указывает на IP этого сервера"
        print_warning "SSL сертификат не будет получен. Сайт будет работать по HTTP."
    fi
else
    print_warning "Email не указан. SSL-сертификат не будет установлен."
fi

# Установка phpMyAdmin
print_header "Шаг 13: Установка phpMyAdmin"
DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin

# Включение phpMyAdmin конфигурации
ln -sf /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
a2enconf phpmyadmin

# Создание поддомена для phpMyAdmin
print_status "Настройка поддомена pma.$DOMAIN для phpMyAdmin..."
cat > /etc/apache2/sites-available/pma.$DOMAIN.conf << EOF
<VirtualHost *:80>
    ServerName pma.$DOMAIN
    DocumentRoot /usr/share/phpmyadmin
    
    <Directory /usr/share/phpmyadmin>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/pma.$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/pma.$DOMAIN-access.log combined
</VirtualHost>
EOF

# Включение поддомена phpMyAdmin
a2ensite pma.$DOMAIN.conf

# Получение SSL для поддомена phpMyAdmin с проверкой DNS
if [ -n "$EMAIL" ]; then
    print_status "Проверка DNS для поддомена phpMyAdmin..."
    if check_dns "pma.$DOMAIN"; then
        print_status "Получение SSL-сертификата для pma.$DOMAIN..."
        if certbot --apache -d "pma.$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"; then
            print_status "✓ SSL-сертификат для phpMyAdmin получен"
        else
            print_warning "Ошибка получения SSL для phpMyAdmin. Будет доступен по HTTP."
        fi
    else
        print_warning "DNS запись для pma.$DOMAIN не найдена"
        print_warning "phpMyAdmin будет доступен по HTTP"
    fi
fi

print_status "✓ phpMyAdmin установлен"

# Настройка PHP 8.4 (увеличение лимитов для WordPress)
print_header "Шаг 14: Оптимизация PHP для WordPress"
cat >> /etc/php/8.4/apache2/php.ini << EOF

; WordPress optimizations
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_vars = 3000
max_file_uploads = 20
EOF

# Перезапуск Apache
print_status "Перезапуск Apache..."
systemctl restart apache2

# Очистка
print_status "Очистка временных файлов..."
rm -rf /tmp/wordpress /tmp/latest.tar.gz

# Определение протокола для URL
if [ "$SSL_SUCCESS" = true ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    PROTOCOL="https"
else
    PROTOCOL="http"
fi

# Получение IP сервера
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "Не удалось определить")

# Создание файла с информацией о системе
print_header "Шаг 15: Создание файла с информацией о системе"
cat > /root/web-server-info.txt << EOF
=== ИНФОРМАЦИЯ О ВЕБ-СЕРВЕРЕ ===
Дата установки: $(date)
Домен: $DOMAIN
SSL: $(if [ "$PROTOCOL" = "https" ]; then echo "Включен (Let's Encrypt)"; else echo "Не настроен"; fi)
IP сервера: $SERVER_IP

=== ПАРОЛИ (СОХРАНИТЕ В БЕЗОПАСНОМ МЕСТЕ!) ===
MySQL root пароль: $MYSQL_ROOT_PASSWORD
WordPress DB пароль: $WP_DB_PASSWORD

=== ДОСТУП К СЕРВИСАМ ===
Основной сайт: $PROTOCOL://$DOMAIN
WordPress админка: $PROTOCOL://$DOMAIN/wp-admin
phpMyAdmin: $PROTOCOL://pma.$DOMAIN

=== БАЗА ДАННЫХ ===
Имя базы WordPress: wordpress
Пользователь WordPress: wpuser
Хост: localhost

=== УСТАНОВЛЕННЫЕ ВЕРСИИ ===
PHP: $(php -v | head -1)
Apache: $(apache2 -v | head -1)
MariaDB: $(mysql --version)

=== DNS ТРЕБОВАНИЯ ===
Убедитесь что настроены A-записи:
$DOMAIN -> $SERVER_IP
www.$DOMAIN -> $SERVER_IP
pma.$DOMAIN -> $SERVER_IP

=== КОМАНДЫ ДЛЯ SSL (если DNS не был настроен) ===
Основной домен: certbot --apache -d $DOMAIN
С www: certbot --apache -d $DOMAIN -d www.$DOMAIN --expand
phpMyAdmin: certbot --apache -d pma.$DOMAIN

=== ПОЛЕЗНЫЕ КОМАНДЫ ===
Перезапуск Apache: systemctl restart apache2
Перезапуск MariaDB: systemctl restart mariadb
Просмотр логов Apache: tail -f /var/log/apache2/$DOMAIN-error.log
Обновление SSL: certbot renew
Статус фаервола: ufw status
Проверка DNS: dig $DOMAIN

=== СЛЕДУЮЩИЕ ШАГИ ===
1. Откройте $PROTOCOL://$DOMAIN в браузере
2. Завершите установку WordPress через веб-интерфейс
3. Настройте DNS записи (если не были настроены)
4. Получите SSL сертификаты (если DNS не работал)
5. Регулярно обновляйте систему: apt update && apt upgrade
EOF

chmod 600 /root/web-server-info.txt

# Завершение установки
echo ""
echo "🎉 ===== УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! ===== 🎉"
echo ""
print_status "📋 Информация о системе сохранена в /root/web-server-info.txt"
echo ""
print_status "🔐 ВАЖНЫЕ ПАРОЛИ (запишите их!):"
echo "=================================================="
echo "MySQL root: $MYSQL_ROOT_PASSWORD"
echo "WordPress DB: $WP_DB_PASSWORD"
echo "=================================================="
echo ""
print_status "🌐 Ваш IP адрес: $SERVER_IP"
echo ""
print_status "🔗 Доступ к сервисам:"
echo "- Основной сайт: $PROTOCOL://$DOMAIN"
echo "- WordPress админка: $PROTOCOL://$DOMAIN/wp-admin"
echo "- phpMyAdmin: $PROTOCOL://pma.$DOMAIN"
echo ""

if [ "$PROTOCOL" = "http" ]; then
    print_warning "⚠️  SSL сертификаты не были получены из-за проблем с DNS"
    print_warning "Настройте следующие A-записи у вашего DNS провайдера:"
    echo "  $DOMAIN -> $SERVER_IP"
    echo "  www.$DOMAIN -> $SERVER_IP"
    echo "  pma.$DOMAIN -> $SERVER_IP"
    print_warning "После настройки DNS выполните:"
    echo "  certbot --apache -d $DOMAIN -d www.$DOMAIN"
    echo "  certbot --apache -d pma.$DOMAIN"
    echo ""
fi

print_warning "📝 Не забудьте:"
echo "1. Завершить установку WordPress через браузер"
echo "2. Изменить пароли по умолчанию в WordPress"
echo "3. Настроить регулярные бэкапы"
echo "4. Регулярно обновлять систему"
echo ""
print_status "🚀 Веб-сервер готов к использованию!"
echo ""
