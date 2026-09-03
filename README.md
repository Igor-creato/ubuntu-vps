# ubuntu-vps

Одной командой напрямую из GitHub:

update and upgrade server

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh)
```

Установщик сначала готовит SSH, проверяет конфигурацию и оставляет старый
listener активным. Для завершения миграции он выведет команду, которую нужно
выполнить во втором терминале после реального входа новым пользователем и
ключом. Только после этого отключаются root login, password authentication и
старый listener.

Параметры можно передать сразу:

```bash
sudo bash install.sh --ssh --username igor --ssh-port 2222 --public-key-file /root/admin-key.pub
```

Если `--public-key-file` не задан, используется существующий
`/root/.ssh/authorized_keys`. Если ни один валидный источник ключа не найден,
скрипт безопасно остановится до изменения SSH/UFW. Root `authorized_keys`
никогда не очищается.

Локальные regression-тесты:

```bash
sudo bash ./tests/run.sh
```

Системные SSH-тесты требуют disposable Ubuntu 24.04 VM с настоящим systemd;
обычный Docker-контейнер для проверки `ssh.socket` недостаточен.

install traefik

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/setup-traefik.sh)
```

install n8n

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/n8n/install-n8n.sh)
```
restart n8n with vpn 
```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d --force-recreate n8n
```
update n8n with vpn
```bash
docker compose pull && docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
```
update n8n
```bash
docker compose pull && docker compose up -d 
```
```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml restart n8n
```
```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
```
install supabase
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/supabase/install-supabase.sh)
```
install wordpress site
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/wordpress/install-wp.sh)
```
install xray
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/xray/install-xray.sh)
```
Установка обработки хука
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts/hook.sh)
```
``` bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts/deploy-webhook-proxy.sh)
```
``` bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts/install_svix.sh)
```
install apache mariadb wordpress
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/scripts/apache-wordpress.sh)
```
чистка системы (запускать команду когда все нужные контейнеры работают!!!)
```bash
docker system prune -a --volumes -f
```
