#!/usr/bin/env bash
set -euo pipefail
echo "=== Reyno Messenger Lite installer (Ubuntu/Debian VPS) ==="
read -rp "Domain (blank = IP only): " DOMAIN || true
read -rp "Admin username [admin]: " ADMIN_USER || true; ADMIN_USER=${ADMIN_USER:-admin}
read -rsp "Admin password (min 8 chars): " ADMIN_PASS; echo
[ ${#ADMIN_PASS} -ge 8 ] || { echo "Admin password too short"; exit 1; }
sudo apt-get update -qq
sudo apt-get install -y -qq python3 python3-venv python3-pip nginx certbot python3-certbot-nginx >/dev/null
cd "$(dirname "$0")"
python3 -m venv .venv; .venv/bin/pip install -q -r backend/requirements.txt gunicorn
SECRET=$(python3 -c "import secrets;print(secrets.token_hex(32))"); JWT=$(python3 -c "import secrets;print(secrets.token_hex(32))")
cat > backend/.env <<EOF
DATABASE_URL=sqlite:///$PWD/backend/reyno_lite.db
SECRET_KEY=$SECRET
JWT_SECRET_KEY=$JWT
ADMIN_USERNAME=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASS
UPLOAD_FOLDER=$PWD/backend/uploads
SESSION_COOKIE_SECURE=true
EOF
mkdir -p backend/uploads
cat > /tmp/reyno.service <<EOF
[Unit]
Description=Reyno Messenger Lite
After=network.target
[Service]
WorkingDirectory=$PWD/backend
EnvironmentFile=$PWD/backend/.env
ExecStart=$PWD/.venv/bin/gunicorn -w 2 -b 127.0.0.1:5000 run:app
Restart=always
User=$USER
[Install]
WantedBy=multi-user.target
EOF
sudo cp /tmp/reyno.service /etc/systemd/system/reyno.service
sudo systemctl daemon-reload; sudo systemctl enable --now reyno
# cron: 72h retention
(crontab -l 2>/dev/null | grep -v retention_maintenance; echo "17 * * * * $PWD/.venv/bin/python $PWD/backend/scripts/retention_maintenance.py >> /tmp/reyno-retention.log 2>&1") | crontab -
SERVER_NAME=${DOMAIN:-_}
sudo tee /etc/nginx/sites-available/reyno >/dev/null <<EOF
server { listen 80; server_name $SERVER_NAME; client_max_body_size 26m;
 location / { proxy_pass http://127.0.0.1:5000; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; } }
EOF
sudo ln -sf /etc/nginx/sites-available/reyno /etc/nginx/sites-enabled/reyno
sudo nginx -t && sudo systemctl reload nginx
if [ -n "${DOMAIN:-}" ]; then echo "Getting free SSL (Let's Encrypt)..."; sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect || echo "SSL failed - check DNS points to this server, then run: sudo certbot --nginx -d $DOMAIN"; fi
echo "DONE. Open: http://${DOMAIN:-YOUR_SERVER_IP}/  Admin: /admin"
