# Deploy Reyno Messenger Lite — step by step (no programming needed)

## Option A: Ubuntu VPS (easiest)
1. Buy any small Ubuntu 22.04/24.04 VPS. If using a domain, point its A record to the VPS IP and wait ~10 min.
2. SSH in, then:
   `git clone <this repo> reyno-lite && cd reyno-lite && bash install.sh`
3. Answer: domain (or blank), admin username, admin password (save it!).
4. Open the printed link. Create your account. Share the link.
SSL: automatic with a domain (free Let's Encrypt). Renewals are automatic via certbot timer. No domain? Use `http://SERVER_IP/` (no SSL — only for testing).

## Option B: cPanel
1. Upload/clone this repo in File Manager / Git Version Control.
2. Terminal (or SSH): `bash cpanel-setup.sh` and set admin credentials.
3. cPanel → **Setup Python App** → Create Application: Python 3.11, Application root `.../backend`, URL = your domain, startup file `passenger_wsgi.py`, entry point `application`. Click Create, then Restart.
4. cPanel → **SSL/TLS → Let's Encrypt™ SSL** → Issue (free) → then **Domains → Force HTTPS Redirect ON**.
5. cPanel → **Cron Jobs** → hourly: `<repo>/venv/bin/python <repo>/backend/scripts/retention_maintenance.py`
6. Open your domain; admin at `/admin`.

## Everyday admin
`/admin` → add/remove users (username only) and clear storage. The 72-hour purge also runs hourly by cron/systemd, so storage cannot silently fill up.

## Troubleshooting
- Video rejected: it must be **under 10 MB** — trim/compress on the phone first.
- 502 on VPS: `sudo systemctl status reyno nginx`
- Forgot admin password: edit `backend/.env` (ADMIN_PASSWORD), restart app.
