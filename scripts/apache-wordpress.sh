#!/bin/bash

# Автоматическая установка и настройка веб-сервера на Ubuntu 24.04
# Включает: Apache, MariaDB, PHP 8.4, WordPress, phpMyAdmin, SSL-сертификаты
# Версия: 2.1 с исправлениями ShellCheck

set -euo pipefail  # Остановить выполнение при ошибке, выход при неустановленных переменных и ошибок в конвейере
IFS=$'\n\t'       # Безопасный Internal Field Separator
trap 'print_error "Ошибка на строке $LINENO"; exit 1' ERR

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
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+=' | head -c "$length"
}

# Функция проверки DNS
check_dns() {
    local domain="$1"
    print_status "Проверка DNS для $domain..."
    
    if command -v dig > /dev/null; then
        if dig +short "$domain" | grep -q '^[0-9]'; then
            print_status "? DNS запись для $domain найдена"
            return 0
        else
            print_warning "? DNS запись для $domain не найдена"
            return 1
        fi
    else
        print_warning "Утилита dig не найдена, пробуем host"
        if command -v host >/dev/null 2>&1; then
            if host "$domain" | grep -q 'has address'; then
                print_status "? DNS запись для $domain найдена (host)"
                return 0
            else
                print_warning "? DNS запись для $domain не найдена (host)"
                return 1
            fi
        fi
        print_warning "Утилита dig и host не найдены, пропускаем проверку DNS"
        return 0
    fi
}

# Упрощенная функция замены WordPress солей
replace_wordpress_salts() {
    local wp_config_path=$1
    
    print_status "Настройка WordPress солей..."
    
    # Используем встроенные соли WP-CLI или простую замену
    if command -v wp >/dev/null 2>&1; then
        wp config shuffle-salts --path="$(dirname "$wp_config_path")" --allow-root 2>/dev/null || {
            print_warning "WP-CLI недоступен, используем стандартные соли"
            generate_simple_salts "$wp_config_path"
        }
    else
        generate_simple_salts "$wp_config_path"
    fi
}

# Функция генерации простых солей
generate_simple_salts() {
    local wp_config_path=$1
    local auth_key
    auth_key=$(generate_password 64)
    local secure_auth_key
    secure_auth_key=$(generate_password 64)
    local logged_in_key
    logged_in_key=$(generate_password 64)
    local nonce_key
    nonce_key=$(generate_password 64)
    local auth_salt
    auth_salt=$(generate_password 64)
    local secure_auth_salt
    secure_auth_salt=$(generate_password 64)
    local logged_in_salt
    logged_in_salt=$(generate_password 64)
    local nonce_salt
    nonce_salt=$(generate_password 64)
    
    # Безопасная замена с экранированием
    sed -i "s/put your unique phrase here.*AUTH_KEY.*/define('AUTH_KEY', '$auth_key');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*SECURE_AUTH_KEY.*/define('SECURE_AUTH_KEY', '$secure_auth_key');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*LOGGED_IN_KEY.*/define('LOGGED_IN_KEY', '$logged_in_key');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*NONCE_KEY.*/define('NONCE_KEY', '$nonce_key');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*AUTH_SALT.*/define('AUTH_SALT', '$auth_salt');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*SECURE_AUTH_SALT.*/define('SECURE_AUTH_SALT', '$secure_auth_salt');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*LOGGED_IN_SALT.*/define('LOGGED_IN_SALT', '$logged_in_salt');/" "$wp_config_path"
    sed -i "s/put your unique phrase here.*NONCE_SALT.*/define('NONCE_SALT', '$nonce_salt');/" "$wp_config_path"
    
    print_status "✓ Соли WordPress успешно настроены"
}


# Функция безопасной замены пароля в wp-config.php
escape_sed_replacement() {
    local string="$1"
    # Экранируем специальные символы для sed (используем двойные кавычки)
    printf '%s\n' "$string" | sed "s/[\\[\\.*^$()+?{|]/\\\\&/g"
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
APP_PMA_PASSWORD=$(generate_password 16)

echo ""
print_status "?? Сгенерированы безопасные пароли:"
echo "=================================================="
echo "MySQL root пароль: $MYSQL_ROOT_PASSWORD"
echo "wpuser DB пароль: $WP_DB_PASSWORD"
echo "phpmyadmin DB пароль: $APP_PMA_PASSWORD"
echo "=================================================="
echo ""
print_warning "??  ОБЯЗАТЕЛЬНО СОХРАНИТЕ ЭТИ ПАРОЛИ В БЕЗОПАСНОМ МЕСТЕ!"
echo ""
read -r -p "Нажмите Enter для продолжения после сохранения паролей..."

# Установка Apache
print_header "Шаг 4: Установка Apache веб-сервера"
apt install -y apache2

# Включение и запуск Apache
systemctl enable apache2
systemctl start apache2
print_status "? Apache успешно установлен и запущен"

# Настройка файрвола UFW
print_header "Шаг 5: Настройка файрвола UFW"
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
print_status "? Файрвол настроен"

# Установка MariaDB
print_header "Шаг 6: Установка MariaDB"
apt install -y mariadb-server

# Включение и запуск MariaDB
systemctl enable mariadb
systemctl start mariadb
print_status "? MariaDB установлена и запущена"

# Автоматическая настройка безопасности MariaDB
print_header "Шаг 7: Настройка безопасности MariaDB"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
print_status "? Безопасность MariaDB настроена"

# Создание пользователя WordPress в базе данных
print_header "Шаг 8: Создание базы данных WordPress"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
print_status "? База данных WordPress создана"

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

# Установка WP-CLI, если отсутствует
if ! command -v wp >/dev/null 2>&1; then
    print_status "Установка WP-CLI..."
    curl -sSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
fi

# Отключение старых версий PHP если они есть
a2dismod php8.3 2>/dev/null || true
a2dismod php8.2 2>/dev/null || true
a2dismod php8.1 2>/dev/null || true

print_status "? Установлена PHP версия: $(php -v | head -1)"

# Запрос домена
print_header "Шаг 10: Настройка домена"
echo ""
while true; do
    read -r -p "Введите домен для вашего сайта (например, example.com): " DOMAIN
    if [ -n "$DOMAIN" ]; then
        break
    else
        print_error "Домен не может быть пустым!"
    fi
done

# Создание директории для сайта
print_status "Создание директории для сайта..."
mkdir -p "/var/www/$DOMAIN"
chown -R www-data:www-data "/var/www/$DOMAIN"
chmod -R 755 "/var/www/$DOMAIN"

# Создание виртуального хоста Apache
print_status "Создание виртуального хоста Apache..."
cat > "/etc/apache2/sites-available/$DOMAIN.conf" << EOF
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
a2ensite "$DOMAIN.conf"
a2dissite 000-default.conf

# Перезапуск Apache
systemctl reload apache2
print_status "? Виртуальный хост создан и активирован"

# Установка WordPress
print_header "Шаг 11: Скачивание и установка WordPress"
cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

# Копирование файлов WordPress
cp -R wordpress/* "/var/www/$DOMAIN/"
chown -R www-data:www-data "/var/www/$DOMAIN"
chmod -R 755 "/var/www/$DOMAIN"

# Создание wp-config.php
print_status "Настройка WordPress..."
cd "/var/www/$DOMAIN"
cp wp-config-sample.php wp-config.php

# Настройка wp-config.php с безопасной заменой паролей
sed -i "s/database_name_here/wordpress/" wp-config.php
sed -i "s/username_here/wpuser/" wp-config.php
# Используем функцию для безопасного экранирования пароля
escaped_password=$(escape_sed_replacement "$WP_DB_PASSWORD")
sed -i "s/password_here/$escaped_password/" wp-config.php
sed -i "s/localhost/localhost/" wp-config.php

# Замена WordPress солей
replace_wordpress_salts "/var/www/$DOMAIN/wp-config.php"

print_status "? WordPress установлен и настроен"

# Запрос email для SSL
print_header "Шаг 12: Настройка SSL сертификатов"
echo ""
read -r -p "Введите email для уведомлений Let's Encrypt (оставьте пустым для пропуска SSL): " EMAIL

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
        # shellcheck disable=SC2086
        if certbot --apache --redirect --hsts --staple-ocsp $CERT_DOMAINS --non-interactive --agree-tos --email "$EMAIL"; then
            print_status "? SSL-сертификат успешно получен"
            SSL_SUCCESS=true
            
            # Настройка автоматического обновления сертификатов
            systemctl enable certbot.timer
            systemctl start certbot.timer
            print_status "? Автоматическое обновление SSL сертификатов настроено"
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
print_status "Настройка автоматической конфигурации phpMyAdmin..."
debconf-set-selections << EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/app-password-confirm password $APP_PMA_PASSWORD
phpmyadmin phpmyadmin/mysql/app-pass password $APP_PMA_PASSWORD
phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_ROOT_PASSWORD
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF
DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin

# Создание базы данных и пользователя для phpMyAdmin
print_status "Создание базы данных и пользователя для phpMyAdmin..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS phpmyadmin DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS 'phpmyadmin'@'localhost' IDENTIFIED BY '$APP_PMA_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
print_status "? База данных и пользователь phpMyAdmin созданы"

# Генерация и установка секретного ключа Blowfish для phpMyAdmin
BLOWFISH_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
sed -i "s|\\\$cfg\\['blowfish_secret'\\] = '';|\$cfg['blowfish_secret'] = '$BLOWFISH_SECRET';|" /etc/phpmyadmin/config.inc.php
print_status "? Blowfish secret установлен для phpMyAdmin"

# Защита config.inc.php: владелец и права доступа
chown root:www-data /etc/phpmyadmin/config.inc.php
chmod 640 /etc/phpmyadmin/config.inc.php
print_status "? Права на config.inc.php заданы 640 и владелец root:www-data"

# Создание таблиц хранилища конфигурации phpMyAdmin
print_status "Создание таблиц хранилища конфигурации phpMyAdmin..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" phpmyadmin < /usr/share/phpmyadmin/sql/create_tables.sql
print_status "? Таблицы phpMyAdmin созданы"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO 'phpmyadmin'@'localhost';"
print_status "? Привилегии для phpmyadmin на phpmyadmin базе настроены"

# Блок конфигурационного хранилища phpMyAdmin
cat >> /etc/phpmyadmin/config.inc.php << EOF
\$cfg['Servers'][\$i]['controluser'] = 'phpmyadmin';
\$cfg['Servers'][\$i]['controlpass'] = '$APP_PMA_PASSWORD';
\$cfg['Servers'][\$i]['pmadb'] = 'phpmyadmin';
\$cfg['Servers'][\$i]['bookmarktable'] = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation'] = 'pma__relation';
\$cfg['Servers'][\$i]['table_info'] = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords'] = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages'] = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info'] = 'pma__column_info';
\$cfg['Servers'][\$i]['history'] = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs'] = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking'] = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig'] = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent'] = 'pma__recent';
\$cfg['Servers'][\$i]['favorite'] = 'pma__favorite';
\$cfg['Servers'][\$i]['users'] = 'pma__users';
\$cfg['Servers'][\$i]['usergroups'] = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
\$cfg['Servers'][\$i]['savedsearches'] = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings'] = 'pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';
EOF
print_status "? Конфигурационное хранилище phpMyAdmin настроено"

# Включение phpMyAdmin конфигурации
ln -sf /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
a2enconf phpmyadmin

# Создание поддомена для phpMyAdmin
print_status "Настройка поддомена pma.$DOMAIN для phpMyAdmin..."
cat > "/etc/apache2/sites-available/pma.$DOMAIN.conf" << EOF
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
a2ensite "pma.$DOMAIN.conf"

# Получение SSL для поддомена phpMyAdmin с проверкой DNS
if [ -n "$EMAIL" ]; then
    print_status "Проверка DNS для поддомена phpMyAdmin..."
    if check_dns "pma.$DOMAIN"; then
        print_status "Получение SSL-сертификата для pma.$DOMAIN..."
        if certbot --apache --redirect --hsts --staple-ocsp -d "pma.$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"; then
            print_status "? SSL-сертификат для phpMyAdmin получен"
        else
            print_warning "Ошибка получения SSL для phpMyAdmin. Будет доступен по HTTP."
        fi
    else
        print_warning "DNS запись для pma.$DOMAIN не найдена"
        print_warning "phpMyAdmin будет доступен по HTTP"
    fi
fi

print_status "? phpMyAdmin установлен"

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
phpMyAdmin DB пароль: $APP_PMA_PASSWORD

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
echo "?? ===== УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! ===== ??"
echo ""
print_status "?? Информация о системе сохранена в /root/web-server-info.txt"
echo ""
print_status "?? ВАЖНЫЕ ПАРОЛИ (запишите их!):"
echo "=================================================="
echo "MySQL root: $MYSQL_ROOT_PASSWORD"
echo "WordPress DB: $WP_DB_PASSWORD"
echo "phpMyAdmin DB: $APP_PMA_PASSWORD"
echo "=================================================="
echo ""
print_status "?? Ваш IP адрес: $SERVER_IP"
echo ""
print_status "?? Доступ к сервисам:"
echo "- Основной сайт: $PROTOCOL://$DOMAIN"
echo "- WordPress админка: $PROTOCOL://$DOMAIN/wp-admin"
echo "- phpMyAdmin: $PROTOCOL://pma.$DOMAIN"
echo ""

if [ "$PROTOCOL" = "http" ]; then
    print_warning "??  SSL сертификаты не были получены из-за проблем с DNS"
    print_warning "Настройте следующие A-записи у вашего DNS провайдера:"
    echo "  $DOMAIN -> $SERVER_IP"
    echo "  www.$DOMAIN -> $SERVER_IP"
    echo "  pma.$DOMAIN -> $SERVER_IP"
    print_warning "После настройки DNS выполните:"
    echo "  certbot --apache -d $DOMAIN -d www.$DOMAIN"
    echo "  certbot --apache -d pma.$DOMAIN"
    echo ""
fi

print_warning "?? Не забудьте:"
echo "1. Завершить установку WordPress через браузер"
echo "2. Изменить пароли по умолчанию в WordPress"
echo "3. Настроить регулярные бэкапы"
echo "4. Регулярно обновлять систему"
echo ""
print_status "?? Веб-сервер готов к использованию!"
echo ""
