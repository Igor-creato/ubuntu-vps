#!/bin/bash

# LAMP Stack Installation Script for Ubuntu/Debian
# Includes Apache, MariaDB, PHP, phpMyAdmin, WordPress, and SSL Certificate
# Author: Automated Installation Script
# Compatible: Ubuntu 20.04+, Debian 10+

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root (use sudo)"
    exit 1
fi

# Get domain name from user
read -r -p "Enter your domain name (example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    print_error "Domain name is required"
    exit 1
fi

# Get email for SSL certificate
read -r -p "Enter your email address for SSL certificate: " EMAIL
if [ -z "$EMAIL" ]; then
    print_error "Email is required for SSL certificate"
    exit 1
fi

# Create log file
LOG_FILE="/var/log/lamp-install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

print_status "Starting LAMP installation for domain: $DOMAIN"

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
print_status "Installing basic packages..."
apt install -y curl wget unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release

# Install Apache
print_status "Installing Apache web server..."
apt install -y apache2
systemctl start apache2
systemctl enable apache2

# Configure Apache
print_status "Configuring Apache..."
a2enmod rewrite
a2enmod ssl
a2enmod headers

# Install MariaDB
print_status "Installing MariaDB database server..."
apt install -y mariadb-server mariadb-client

# Secure MariaDB installation
print_status "Securing MariaDB installation..."
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

# Install PHP
print_status "Installing PHP and extensions..."
apt install -y php php-mysql php-xml php-gd php-curl php-mbstring php-zip php-intl php-bcmath php-json php-imagick libapache2-mod-php

# Install phpMyAdmin
print_status "Installing phpMyAdmin..."
echo 'phpmyadmin phpmyadmin/dbconfig-install boolean true' | debconf-set-selections
echo 'phpmyadmin phpmyadmin/app-password-confirm password' | debconf-set-selections
echo 'phpmyadmin phpmyadmin/mysql/admin-pass password '"$MYSQL_ROOT_PASSWORD" | debconf-set-selections
echo 'phpmyadmin phpmyadmin/mysql/app-pass password' | debconf-set-selections
echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' | debconf-set-selections
apt install -y phpmyadmin

# Create WordPress database and user
print_status "Creating WordPress database and user..."
WP_DB_NAME="wordpress_$(date +%Y%m%d)"
WP_DB_USER="wp_user"
WP_DB_PASSWORD=$(openssl rand -base64 32)

mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $WP_DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $WP_DB_NAME.* TO '$WP_DB_USER'@'localhost';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

# Create Apache virtual host
print_status "Creating Apache virtual host..."
cat > /etc/apache2/sites-available/"$DOMAIN".conf << EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/$DOMAIN

    <Directory /var/www/$DOMAIN>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF

# Enable site and disable default
a2ensite "$DOMAIN".conf
a2dissite 000-default.conf

# Create web directory
mkdir -p /var/www/"$DOMAIN"

# Download and install WordPress
print_status "Downloading and installing WordPress..."
cd /tmp || exit
wget https://wordpress.org/latest.tar.gz
tar xzf latest.tar.gz
cp -R wordpress/* /var/www/"$DOMAIN"/
chown -R www-data:www-data /var/www/"$DOMAIN"
chmod -R 755 /var/www/"$DOMAIN"

# Configure WordPress
print_status "Configuring WordPress..."
cd /var/www/"$DOMAIN" || exit
cp wp-config-sample.php wp-config.php

# Generate WordPress salts
SALT_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Update wp-config.php
sed -i "s/database_name_here/$WP_DB_NAME/" wp-config.php
sed -i "s/username_here/$WP_DB_USER/" wp-config.php
sed -i "s/password_here/$WP_DB_PASSWORD/" wp-config.php
sed -i "s/localhost/localhost/" wp-config.php

# Replace salt keys
sed -i "/AUTH_KEY/,/NONCE_SALT/c\
$SALT_KEYS" wp-config.php

# Install Certbot for SSL
print_status "Installing Certbot for SSL certificates..."
apt install -y certbot python3-certbot-apache

# Configure firewall
print_status "Configuring firewall..."
ufw --force enable
ufw allow ssh
ufw allow 'Apache Full'
ufw allow 80
ufw allow 443

# Restart Apache
systemctl restart apache2

# Get SSL certificate
print_status "Obtaining SSL certificate from Let's Encrypt..."
certbot --apache --non-interactive --agree-tos --email "$EMAIL" --domains "$DOMAIN" --domains www."$DOMAIN"

# Set up automatic certificate renewal
print_status "Setting up automatic certificate renewal..."
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

# Save credentials
print_status "Saving credentials..."
cat > /root/lamp-credentials.txt << EOF
LAMP Installation Completed: $(date)
Domain: $DOMAIN
WordPress URL: https://$DOMAIN
WordPress Admin URL: https://$DOMAIN/wp-admin

Database Information:
MySQL Root Password: $MYSQL_ROOT_PASSWORD
WordPress Database: $WP_DB_NAME
WordPress DB User: $WP_DB_USER
WordPress DB Password: $WP_DB_PASSWORD

phpMyAdmin URL: https://$DOMAIN/phpmyadmin
Log file: $LOG_FILE

IMPORTANT: Please save these credentials securely and delete this file after copying the information!
EOF

# Final status
print_status "LAMP installation completed successfully!"
print_status "WordPress is available at: https://$DOMAIN"
print_status "phpMyAdmin is available at: https://$DOMAIN/phpmyadmin"
print_status "Credentials saved to: /root/lamp-credentials.txt"
print_warning "Please complete WordPress installation by visiting your domain"
print_warning "Don't forget to secure your installation and update default passwords"

echo
echo "=== Installation Summary ==="
echo "✅ Apache Web Server"
echo "✅ MariaDB Database"
echo "✅ PHP with extensions"
echo "✅ phpMyAdmin"
echo "✅ WordPress"
echo "✅ SSL Certificate (Let's Encrypt)"
echo "✅ Firewall configured"
echo "✅ Auto certificate renewal"
echo
