<div align="center">
<img src="assets/icons/reyno_logo_dark.png" width="420" alt="Reyno Messenger Lite">

# Reyno Messenger Lite

**Your own private messenger — on your own server, in your browser, in minutes.**

[![Python](https://img.shields.io/badge/Python-3.11-blue)](https://python.org)
[![Flask](https://img.shields.io/badge/Backend-Flask-black)](https://flask.palletsprojects.com)
[![Retention](https://img.shields.io/badge/Data%20retention-72%20hours-red)](#-privacy--safety-design)
[![Videos](https://img.shields.io/badge/Video-limit%20%3C%2010%20MB-green)](#)
[![License](https://img.shields.io/badge/Use-Free-brightgreen)](#)

No phone number. No email. No app install. Just a **username + password**, a link, and any browser — phone, tablet, or computer.
Built for places where privacy matters most: messages are **encrypted on the server disk**, media **auto-deletes after 72 hours**, and the admin **cannot read anyone's chats**.

[Quick start (VPS)](#-quick-start--ubuntu-vps-one-command) · [cPanel hosting](#-quick-start--cpanel-shared-hosting) · [User guide (non-technical)](#-user-guide-for-everyone) · [Feature comparison](#-lite-vs-full-version)
</div>

---

## ✨ What you get

- 💬 Private, group & channel chats — create, add members, assign admins (simple roles only)
- 📝 Text, 📷 photos, 🎬 videos (**under 10 MB**), 🎙 voice messages, 😀 stickers, 📍 **static** location
- ✏️ Edit messages, ❤️ reactions, ↩️ replies, 📌 pinning, ➡️ forwarding
- 🗑 Delete **for me** or **for everyone** (two-way), 🗂 archive chats, 🔕 mute, 📌 pin chats
- 🔍 Search people by **@ID**, plus public groups & channels
- 🟢 Online status, 🎨 light/dark themes
- 🔐 **Admin panel so limited it can't spy:** only *add user*, *remove user*, *clear server storage*

## 🚫 What Lite deliberately does NOT have

No profiles/avatars/bio · no phone or email sign-up · no 2FA · no notifications/background push · no Persian UI (English only) · no Ghost Mode · no multi-account · no documents/files · no GIFs · no polls/quizzes · no secret chats · no live location · no video notes · no spoiler/view-once/scheduled/password messages · no folders · no forwarding controls · no chat backgrounds/disappearing timers · no device/session manager · no granular permissions.

## 📊 Lite vs Full version

| Feature | Full (private) | Lite (this repo) |
|---|:---:|:---:|
| Text / photo / voice / stickers | ✅ | ✅ |
| Video | ✅ | ✅ (<10 MB) |
| Two-way delete + edit | ✅ | ✅ |
| Groups/channels, admins, members | ✅ | ✅ (simple) |
| Search @ID/groups/channels, block, archive, themes, online | ✅ | ✅ |
| Static location | ✅ | ✅ |
| 72-hour auto-clear | ✅ | ✅ |
| Profiles, bio, avatar | ✅ | ❌ |
| Phone sign-up / recovery | ✅ | ❌ |
| 2FA, multi-account, devices | ✅ | ❌ |
| Documents, GIFs, polls, secret chat | ✅ | ❌ |
| Live location, video notes, spoiler, scheduled, password msgs | ✅ | ❌ |
| Notifications / Firebase / background | ✅ | ❌ |
| Persian language | ✅ | ❌ |
| Folders, forwarding controls, granular permissions | ✅ | ❌ |
| God-mode admin panel | ✅ | ❌ (add/remove users + clear storage only) |

## 🚀 Quick start — Ubuntu VPS (one command)

You need: a cheap Ubuntu VPS (the kind sold for VPN/proxy use is fine), optionally a domain pointed at it.

```bash
git clone https://github.com/2052mam/test.git reyno-lite && cd reyno-lite
bash install.sh
```

Answer 3 prompts (domain, admin username, admin password). The script installs everything, starts the service, sets the hourly 72-hour cleanup, configures Nginx, and — if you gave a domain — gets a **free Let's Encrypt SSL certificate** automatically. Then open `https://yourdomain.com`.

**SSL manually later:** `sudo certbot --nginx -d yourdomain.com` (free, auto-renews).

## 🌐 Quick start — cPanel shared hosting

```bash
bash cpanel-setup.sh
```
Then in cPanel: **Setup Python App** (root `backend`, startup `passenger_wsgi.py`, entry `application`) → **SSL/TLS → Let's Encrypt → Issue** → turn on **Force HTTPS**. Add the hourly cron printed by the script. Full screenshots-style walkthrough: [`docs/DEPLOY.md`](docs/DEPLOY.md).

## 📱 User guide (for everyone)

1. Open your server's link in any browser. **Create account** → pick a username & password (that's all — write the password down, there's no phone/email recovery by design).
2. To find someone: type their **@username** in Search → tap → chat.
3. **＋** creates a group/channel; in a chat tap **ℹ** to add members or make someone an admin.
4. Camera/＋ button sends photo/video (video must be <10 MB — trim it in your phone gallery first if bigger). 🎙 records voice. ☺ stickers. ⌖ sends your (static) location.
5. Long-tap/hover a message for Reply / Edit / Delete. *Delete for everyone* removes it for both sides.
6. Remember: **everything auto-deletes after 72 hours** — save anything important elsewhere.

## 🔒 Privacy & safety design

- Message text & location labels are **Fernet-encrypted at rest** (key derived from your server secret) — a stolen DB file doesn't reveal chats.
- Uploaded photos are **EXIF/GPS-stripped**; original device filenames are never stored; IPs are only ever hashed for rate-limiting.
- Admin panel/API expose **zero** user data — no profiles, chats, messages, or activity; only add/remove user + storage cleanup.
- Logins are rate-limited, passwords hashed (Werkzeug scrypt), admin login uses constant-time compare + CSRF, security headers/HSTS on HTTPS.
- Honest limit: this is transport-HTTPS + encrypted-at-rest, **not** end-to-end encryption — the server operator's host still runs the code. Don't oversell it; keep your VPS login secure.

## 🧑‍💼 Admin panel

Open `/admin`, sign in with the credentials from install. You can: add a user, remove a user (type their username), purge >72h data, or clear all server storage. Nothing else exists — by design.

## 🧪 Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt pytest Pillow
PYTHONPATH=backend .venv/bin/python -m pytest backend/tests -q   # 6 passed
```

Optional Flutter Web build (same API/UI): install Flutter, then `flutter build web` — see `lib/main.dart`. The zero-install served web app at `/` needs no build step and is the recommended route for cPanel.

## 📁 Layout

`backend/` Flask API + admin + served web app · `lib/` Flutter Web · `install.sh` VPS one-command · `cpanel-setup.sh` shared hosting · `docs/DEPLOY.md` step-by-step.

<div align="center"><img src="assets/icons/app_icon.png" width="72"><br><b>Reyno Messenger Lite — small, honest, yours.</b></div>
