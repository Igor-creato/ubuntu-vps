# ubuntu-vps

Одной командой напрямую из GitHub:

update and upgrade server

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/install.sh)
```

install traefik

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/traefik/setup-traefik.sh)
```

install n8n

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Igor-creato/ubuntu-vps/main/docker-files/n8n/install-n8n.sh)
```
restart with vpn
```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d --force-recreate n8n
```
# быстрый "bounce" без пересоздания:
# docker compose -f docker-compose.yml -f docker-compose.vpn.yml restart n8n

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
