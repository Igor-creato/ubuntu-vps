#!/bin/bash

# Автоматическая установка и настройка веб-сервера на Ubuntu 24.04
# Включает: Apache, MariaDB, PHP, WordPress, phpMyAdmin, SSL-сертификаты

set -e  # Остановить выполнение при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Функция генерации паролей
generate_password() {
    local length=${1:-16}
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c $length
}

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    print_error "Пожалуйста, запустите скрипт с правами суперпользователя (sudo)"
    exit 1
fi

print_status "Начинаем установку веб-сервера..."

# Обновление системы
print_status "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
print_status "Установка базовых пакетов..."
apt install -y software-properties-common curl wget unzip ufw certbot python3-certbot-apache

# Генерация паролей
MYSQL_ROOT_PASSWORD=$(generate_password 20)
WP_DB_PASSWORD=$(generate_password 16)

print_status "Сгенерированы пароли:"
echo "MySQL root пароль: $MYSQL_ROOT_PASSWORD"
echo "WordPress DB пароль: $WP_DB_PASSWORD"

# Установка Apache
print_status "Установка Apache веб-сервера..."
apt install -y apache2

# Включение и запуск Apache
systemctl enable apache2
systemctl start apache2

# Настройка файрвола UFW
print_status "Настройка файрвола UFW..."
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https

# Установка MariaDB
print_status "Установка MariaDB..."
apt install -y mariadb-server

# Включение и запуск MariaDB
systemctl enable mariadb
systemctl start mariadb

# Автоматическая настройка безопасности MariaDB
print_status "Настройка безопасности MariaDB..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Создание пользователя WordPress в базе данных
print_status "Создание пользователя WordPress в MariaDB..."
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';"
mysql -u root -p$MYSQL_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Установка PHP и расширений
print_status "Установка PHP и необходимых расширений..."
apt install -y php php-mysql php-curl php-gd php-intl php-mbstring php-soap php-xml php-xmlrpc php-zip php-json php-imagick php-cli php-common php-bcmath libapache2-mod-php

# Включение модулей Apache
a2enmod rewrite
a2enmod ssl

# Запрос домена
echo ""
read -p "Введите домен для вашего сайта (например, example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    print_error "Домен не может быть пустым!"
    exit 1
fi

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

# Получение SSL-сертификата Let's Encrypt
print_status "Получение SSL-сертификата Let's Encrypt..."
print_warning "ВАЖНО: Убедитесь, что домен $DOMAIN указывает на этот сервер!"
read -p "Введите email для уведомлений Let's Encrypt: " EMAIL

if [ -z "$EMAIL" ]; then
    print_warning "Email не указан. SSL-сертификат не будет установлен."
else
    print_status "Получение SSL-сертификата для $DOMAIN..."
    certbot --apache -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL
    
    # Настройка автоматического обновления сертификатов
    systemctl enable certbot.timer
    systemctl start certbot.timer
fi

# Установка WordPress
print_status "Скачивание и установка WordPress..."
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

# Получение ключей WordPress
WP_SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Настройка wp-config.php
sed -i "s/database_name_here/wordpress/" wp-config.php
sed -i "s/username_here/wpuser/" wp-config.php
sed -i "s/password_here/$WP_DB_PASSWORD/" wp-config.php
sed -i "s/localhost/localhost/" wp-config.php

# Добавление солей безопасности
sed -i "/put your unique phrase here/c\\$WP_SALTS" wp-config.php

# Установка phpMyAdmin
print_status "Установка phpMyAdmin..."
apt install -y phpmyadmin

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

# Получение SSL для поддомена phpMyAdmin
if [ ! -z "$EMAIL" ]; then
    print_status "Получение SSL-сертификата для pma.$DOMAIN..."
    certbot --apache -d pma.$DOMAIN --non-interactive --agree-tos --email $EMAIL
fi

# Перезапуск Apache
print_status "Перезапуск Apache..."
systemctl restart apache2

# Настройка PHP (увеличение лимитов для WordPress)
print_status "Оптимизация PHP для WordPress..."
cat >> /etc/php/*/apache2/php.ini << EOF

; WordPress optimizations
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_vars = 3000
EOF

# Перезапуск Apache после изменений PHP
systemctl restart apache2

# Очистка
print_status "Очистка временных файлов..."
rm -rf /tmp/wordpress /tmp/latest.tar.gz

# Создание файла с информацией о системе
print_status "Создание файла с информацией о системе..."
cat > /root/web-server-info.txt << EOF
=== ИНФОРМАЦИЯ О ВЕБ-СЕРВЕРЕ ===
Дата установки: $(date)
Домен: $DOMAIN
SSL: Включен (Let's Encrypt)

=== ПАРОЛИ (СОХРАНИТЕ В БЕЗОПАСНОМ МЕСТЕ!) ===
MySQL root пароль: $MYSQL_ROOT_PASSWORD
WordPress DB пароль: $WP_DB_PASSWORD

=== ДОСТУП К СЕРВИСАМ ===
Основной сайт: https://$DOMAIN
WordPress админка: https://$DOMAIN/wp-admin
phpMyAdmin: https://pma.$DOMAIN

=== БАЗА ДАННЫХ ===
Имя базы WordPress: wordpress
Пользователь WordPress: wpuser
Хост: localhost

=== ФАЙЛЫ И ДИРЕКТОРИИ ===
Корень сайта: /var/www/$DOMAIN
Конфигурация Apache: /etc/apache2/sites-available/$DOMAIN.conf
Логи Apache: /var/log/apache2/
Конфигурация PHP: /etc/php/*/apache2/php.ini

=== ПОЛЕЗНЫЕ КОМАНДЫ ===
Перезапуск Apache: systemctl restart apache2
Перезапуск MariaDB: systemctl restart mariadb
Просмотр логов Apache: tail -f /var/log/apache2/$DOMAIN-error.log
Обновление SSL: certbot renew
Статус фаервола: ufw status

=== СЛЕДУЮЩИЕ ШАГИ ===
1. Откройте https://$DOMAIN в браузере
2. Завершите установку WordPress через веб-интерфейс
3. Настройте DNS для поддомена pma.$DOMAIN
4. Регулярно обновляйте систему: apt update && apt upgrade
EOF

chmod 600 /root/web-server-info.txt

# Завершение установки
print_status "===== УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! ====="
echo ""
print_status "Информация о системе сохранена в /root/web-server-info.txt"
echo ""
print_status "ВАЖНЫЕ ПАРОЛИ (запишите их!):"
echo "MySQL root: $MYSQL_ROOT_PASSWORD"
echo "WordPress DB: $WP_DB_PASSWORD"
echo ""
print_status "Доступ к сервисам:"
echo "- Основной сайт: https://$DOMAIN"
echo "- WordPress админка: https://$DOMAIN/wp-admin"  
echo "- phpMyAdmin: https://pma.$DOMAIN"
echo ""
print_warning "Не забудьте:"
echo "1. Настроить DNS для поддомена pma.$DOMAIN"
echo "2. Завершить установку WordPress через браузер"
echo "3. Изменить пароли по умолчанию в WordPress"
echo "4. Регулярно обновлять систему"
echo ""
print_status "Веб-сервер готов к использованию!"
