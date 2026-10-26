"""The admin panel web UI (Point 5).

Rebuilt from a handful of unfiltered 200-row dumps into a real console:

* sidebar navigation and a consistent layout on every page
* filter bars + working pagination on every list
* user / chat detail pages with the actions an operator actually needs
* a **support section** that reads the chats users sent to support and lets an
  admin reply in-thread, plus the login-screen ticket inbox
* reports queue, media browser, device oversight, security-event log
* a filterable audit log

Security notes: the panel is behind a secret path *and* a login, every mutating
action is a POST guarded by a per-session CSRF token, brute-force login attempts
are throttled, and credentials are compared in constant time.
"""
import hmac
import os
import secrets
from datetime import datetime, timedelta
from functools import wraps
from urllib.parse import urlencode

from flask import (
    Blueprint, current_app, redirect, request, session, url_for,
)
from sqlalchemy import func, or_

from app import db
from app.admin.ui import (
    action_form, bars, e, filter_bar, page, pager, sparkline, stat, table,
)
from app.models.audit import AuditLog
from app.models.chat import Chat, ChatMember
from app.models.media import MediaFile
from app.models.message import Message
from app.models.report import Report
from app.models.support import TICKET_STATUSES, SecurityAlert, SupportTicket
from app.models.user import User, UserDevice, UserSession

admin_web_bp = Blueprint('admin_web', __name__)

LOGIN_MAX_ATTEMPTS = 5
LOGIN_LOCKOUT = timedelta(minutes=10)
_login_attempts = {}


# --------------------------------------------------------------------------
# auth plumbing
# --------------------------------------------------------------------------
def _secret_ok(secret_path):
    return hmac.compare_digest(
        str(secret_path), str(current_app.config['ADMIN_SECRET_PATH']))


def _csrf_token():
    token = session.get('admin_csrf')
    if not token:
        token = secrets.token_urlsafe(32)
        session['admin_csrf'] = token
    return token


def _csrf_ok():
    sent = request.form.get('csrf_token', '')
    expected = session.get('admin_csrf', '')
    return bool(expected) and hmac.compare_digest(sent, expected)


def admin_required(view):
    """Guard every panel page: correct secret path, live session, CSRF on POST."""
    @wraps(view)
    def wrapper(secret_path, *args, **kwargs):
        if not _secret_ok(secret_path):
            return 'Not Found', 404
        if not session.get('admin_logged_in'):
            return redirect(f'/{secret_path}/login')
        if request.method == 'POST' and not _csrf_ok():
            return _flash_redirect(
                secret_path, '', 'err',
                'درخواست نامعتبر بود (CSRF). دوباره تلاش کنید.')
        return view(secret_path, *args, **kwargs)
    return wrapper


def _flash_redirect(secret, path, kind, message):
    session['admin_flash'] = [kind, message]
    return redirect(f'/{secret}/{path}')


def _take_flash():
    flash = session.pop('admin_flash', None)
    return tuple(flash) if flash else None


def _client_ip():
    forwarded = request.headers.get('X-Forwarded-For')
    return (forwarded.split(',')[0].strip() if forwarded
            else request.remote_addr) or 'unknown'


def _throttled(ip):
    record = _login_attempts.get(ip)
    if not record:
        return False
    count, first = record
    if datetime.utcnow() - first > LOGIN_LOCKOUT:
        _login_attempts.pop(ip, None)
        return False
    return count >= LOGIN_MAX_ATTEMPTS


def _note_failure(ip):
    count, first = _login_attempts.get(ip, (0, datetime.utcnow()))
    if datetime.utcnow() - first > LOGIN_LOCKOUT:
        count, first = 0, datetime.utcnow()
    _login_attempts[ip] = (count + 1, first)


# --------------------------------------------------------------------------
# query helpers
# --------------------------------------------------------------------------
def _page_no():
    try:
        return max(1, int(request.args.get('page', 1)))
    except (TypeError, ValueError):
        return 1


PER_PAGE = 40


def _paginate(query, per_page=PER_PAGE):
    page_no = _page_no()
    pagination = query.paginate(page=page_no, per_page=per_page,
                                error_out=False)
    return pagination, page_no, (pagination.pages or 1)


def _args(*names):
    return {name: (request.args.get(name) or '').strip() for name in names}


def _parse_date(raw):
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00')).replace(
            tzinfo=None)
    except (TypeError, ValueError):
        return None


def _apply_dates(query, column, values):
    start = _parse_date(values.get('from'))
    end = _parse_date(values.get('to'))
    if start:
        query = query.filter(column >= start)
    if end:
        query = query.filter(column < end + timedelta(days=1))
    return query


def _dt(value, fmt='%Y-%m-%d %H:%M'):
    return value.strftime(fmt) if value else '—'


def _names(ids):
    ids = {i for i in ids if i}
    if not ids:
        return {}
    return {u.id: (u.display_name or u.username or u.id[:8])
            for u in User.query.filter(User.id.in_(ids)).all()}


BADGE_ONLINE = '<span class="badge badge-ok">آنلاین</span>'
BADGE_OFFLINE = '<span class="badge badge-off">آفلاین</span>'
BADGE_BANNED = '<span class="badge badge-bad">غیرفعال</span>'
BADGE_PRIMARY = '<span class="badge badge-info">اصلی</span>'
BADGE_DELETED = '<span class="badge badge-off">حذف‌شده</span>'
BADGE_ACTIVE = '<span class="badge badge-ok">فعال</span>'
ENCRYPTED_LABEL = '🔒 رمزگذاری‌شده'


def _presence(user):
    mark = BADGE_ONLINE if user.is_online else BADGE_OFFLINE
    if not user.is_active:
        mark += ' ' + BADGE_BANNED
    return mark


def _audit(action, entity_type, entity_id, **kw):
    db.session.add(AuditLog(
        actor_id=f"panel:{session.get('admin_user', 'admin')}",
        action=action, entity_type=entity_type, entity_id=entity_id,
        ip_address=_client_ip(), user_agent=request.headers.get('User-Agent'),
        new_value=kw.get('new_value'), old_value=kw.get('old_value'),
    ))


def _human_bytes(num):
    value = float(num or 0)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if value < 1024 or unit == 'TB':
            return f'{value:.0f} {unit}' if unit == 'B' else f'{value:.1f} {unit}'
        value /= 1024
    return f'{value:.1f} TB'


# --------------------------------------------------------------------------
# login / logout
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/login', methods=['GET', 'POST'])
def admin_login(secret_path):
    if not _secret_ok(secret_path):
        return 'Not Found', 404
    error = None
    ip = _client_ip()
    if request.method == 'POST':
        if _throttled(ip):
            error = 'تعداد تلاش‌های ناموفق بیش از حد است. ۱۰ دقیقه بعد تلاش کنید.'
        else:
            expected_user = os.getenv('ADMIN_USERNAME') or ''
            expected_pass = os.getenv('ADMIN_PASSWORD') or ''
            sent_user = request.form.get('username', '')
            sent_pass = request.form.get('password', '')
            # Constant-time comparison; an unset credential never authenticates.
            ok = bool(expected_user and expected_pass) and (
                hmac.compare_digest(sent_user, expected_user)
                and hmac.compare_digest(sent_pass, expected_pass))
            if ok:
                session.clear()
                session['admin_logged_in'] = True
                session['admin_user'] = expected_user
                _login_attempts.pop(ip, None)
                _csrf_token()
                db.session.add(AuditLog(
                    actor_id=f'panel:{expected_user}', action='admin_panel_login',
                    entity_type='admin', entity_id=expected_user,
                    ip_address=ip,
                    user_agent=request.headers.get('User-Agent')))
                db.session.commit()
                return redirect(f'/{secret_path}/')
            _note_failure(ip)
            error = 'نام کاربری یا رمز اشتباه است'

    from app.admin.ui import BASE_CSS
    error_html = f'<p class="error">{e(error)}</p>' if error else ''
    return f"""<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ورود مدیر</title><style>{BASE_CSS}</style></head><body>
<div class="login-wrap"><div class="login-card">
<h2>🔒 ورود پنل مدیریت</h2>
<form method="post">
<input name="username" placeholder="نام کاربری" required autocomplete="username">
<input name="password" type="password" placeholder="رمز عبور" required
 autocomplete="current-password">
<button type="submit">ورود به پنل</button>
{error_html}
</form></div></div></body></html>"""


@admin_web_bp.route('/<path:secret_path>/logout')
def admin_logout(secret_path):
    if not _secret_ok(secret_path):
        return 'Not Found', 404
    session.clear()
    return redirect(f'/{secret_path}/login')


# --------------------------------------------------------------------------
# dashboard
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/')
@admin_required
def admin_dashboard(secret_path):
    now = datetime.utcnow()
    day_ago = now - timedelta(days=1)
    week_ago = now - timedelta(days=7)

    users = User.query.filter_by(is_deleted=False).count()
    online = User.query.filter(
        User.is_deleted.is_(False), User.is_online.is_(True),
        User.last_seen >= now - timedelta(seconds=60)).count()
    chats = Chat.query.filter_by(is_deleted=False).count()
    messages = Message.query.filter_by(is_deleted_for_all=False).count()
    media = MediaFile.query.filter_by(is_deleted=False).count()
    devices = UserDevice.query.filter_by(is_deleted=False).count()
    new_24h = User.query.filter(User.is_deleted.is_(False),
                                User.created_at >= day_ago).count()
    msgs_24h = Message.query.filter(Message.created_at >= day_ago).count()
    pending_reports = Report.query.filter_by(status='pending').count()
    open_tickets = SupportTicket.query.filter(
        SupportTicket.status.in_(['open', 'in_progress'])).count()
    banned = User.query.filter_by(is_deleted=False, is_active=False).count()
    storage = db.session.query(
        func.coalesce(func.sum(MediaFile.file_size), 0)).filter(
        MediaFile.is_deleted.is_(False)).scalar() or 0

    series = []
    for offset in range(13, -1, -1):
        start = (now - timedelta(days=offset)).replace(
            hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        series.append({
            'date': start.strftime('%Y-%m-%d'),
            'messages': Message.query.filter(
                Message.created_at >= start, Message.created_at < end).count(),
        })

    chat_type_rows = db.session.query(
        Chat.chat_type, func.count(Chat.id)).filter(
        Chat.is_deleted.is_(False)).group_by(Chat.chat_type).all()
    msg_type_rows = db.session.query(
        Message.message_type, func.count(Message.id)).filter(
        Message.created_at >= week_ago).group_by(
        Message.message_type).order_by(func.count(Message.id).desc()).limit(8).all()

    recent_users = User.query.filter_by(is_deleted=False).order_by(
        User.created_at.desc()).limit(8).all()
    recent_alerts = SecurityAlert.query.order_by(
        SecurityAlert.created_at.desc()).limit(8).all()
    alert_names = _names([a.user_id for a in recent_alerts])

    user_rows = [
        f'<tr><td><a href="/{secret_path}/users/{u.id}">{e(u.display_name)}</a></td>'
        f'<td class="mono">{e(u.username)}</td>'
        f'<td>{_presence(u)}</td>'
        f'<td class="mono">{_dt(u.created_at, "%Y-%m-%d")}</td></tr>'
        for u in recent_users]

    alert_rows = [
        f'<tr><td>{e(a.title)}</td>'
        f'<td>{e(alert_names.get(a.user_id, a.user_id))}</td>'
        f'<td><span class="badge badge-{"bad" if a.severity == "critical" else "warn"}">'
        f'{e(a.severity)}</span></td>'
        f'<td class="mono">{_dt(a.created_at)}</td></tr>'
        for a in recent_alerts]

    body = f"""
<div class="stats">
{stat(users, 'کاربران')}
{stat(online, 'آنلاین', 'ok')}
{stat(chats, 'چت‌ها')}
{stat(messages, 'پیام‌ها')}
{stat(media, 'رسانه‌ها')}
{stat(devices, 'دستگاه‌ها')}
</div>
<div class="stats">
{stat(new_24h, 'کاربر جدید ۲۴ساعت', 'ok')}
{stat(msgs_24h, 'پیام ۲۴ساعت')}
{stat(pending_reports, 'گزارش در انتظار', 'warn' if pending_reports else '')}
{stat(open_tickets, 'تیکت باز', 'warn' if open_tickets else '')}
{stat(banned, 'کاربر مسدود', 'danger' if banned else '')}
{stat(_human_bytes(storage), 'حجم رسانه')}
</div>
<div class="card"><h2>پیام‌های ۱۴ روز اخیر</h2>{sparkline(series, 'messages')}</div>
<div class="grid2">
<div class="card"><h2>توزیع چت‌ها</h2>{bars([(r[0], r[1]) for r in chat_type_rows])}</div>
<div class="card"><h2>نوع پیام‌ها (۷ روز)</h2>{bars([(r[0], r[1]) for r in msg_type_rows])}</div>
</div>
<div class="grid2">
<div class="card"><h2>آخرین کاربران <a href="/{secret_path}/users">همه</a></h2>
{table(['نام', 'یوزرنیم', 'وضعیت', 'تاریخ'], user_rows)}</div>
<div class="card"><h2>رویدادهای امنیتی <a href="/{secret_path}/security">همه</a></h2>
{table(['رویداد', 'کاربر', 'شدت', 'زمان'], alert_rows)}</div>
</div>
"""
    return page(secret_path, 'داشبورد', body, '', _take_flash())


# --------------------------------------------------------------------------
# users
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/users')
@admin_required
def admin_users(secret_path):
    values = _args('q', 'status', 'role', 'from', 'to')
    query = User.query.filter(User.is_deleted.is_(False))
    if values['q']:
        like = f"%{values['q']}%"
        query = query.filter(or_(
            User.display_name.ilike(like), User.username.ilike(like),
            User.email.ilike(like), User.mobile_number.ilike(like),
            User.id == values['q']))
    status = values['status']
    if status == 'active':
        query = query.filter(User.is_active.is_(True), User.is_limited.is_(False))
    elif status == 'banned':
        query = query.filter(User.is_active.is_(False))
    elif status == 'limited':
        query = query.filter(User.is_limited.is_(True))
    elif status == 'online':
        query = query.filter(
            User.is_online.is_(True),
            User.last_seen >= datetime.utcnow() - timedelta(seconds=60))
    elif status == 'unverified':
        query = query.filter(User.mobile_verified_at.is_(None))
    if values['role'] == 'admin':
        query = query.filter(User.is_admin.is_(True))
    elif values['role'] == 'support':
        query = query.filter(User.is_support.is_(True))
    query = _apply_dates(query, User.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(User.created_at.desc()))

    csrf = _csrf_token()
    rows = []
    for u in pagination.items:
        badges = []
        if u.is_online:
            badges.append('<span class="badge badge-ok">آنلاین</span>')
        if not u.is_active:
            badges.append('<span class="badge badge-bad">مسدود</span>')
        if u.is_limited:
            badges.append('<span class="badge badge-warn">محدود</span>')
        if u.is_admin:
            badges.append('<span class="badge badge-info">ادمین</span>')
        if u.is_support:
            badges.append('<span class="badge badge-info">پشتیبان</span>')
        toggle = action_form(
            secret_path, f'users/{u.id}/toggle',
            'فعال‌سازی' if not u.is_active else 'مسدود', csrf,
            cls='btn btn-sm' if not u.is_active else 'btn btn-sm btn-danger',
            confirm='مطمئن هستید؟')
        rows.append(
            f'<tr><td><a href="/{secret_path}/users/{u.id}">{e(u.display_name)}</a></td>'
            f'<td class="mono">{e(u.username)}</td>'
            f'<td class="mono">{e(u.mobile_number)}</td>'
            f'<td>{" ".join(badges) or "—"}</td>'
            f'<td class="mono">{_dt(u.created_at, "%Y-%m-%d")}</td>'
            f'<td class="actions">{toggle}'
            f'<a class="btn btn-sm btn-ghost" href="/{secret_path}/users/{u.id}">جزئیات</a>'
            f'</td></tr>')

    filters = filter_bar(secret_path, 'users', [
        ('q', 'جستجو (نام/یوزرنیم/شماره)', 'text', None),
        ('status', 'وضعیت', 'select', [
            ('', 'همه'), ('active', 'فعال'), ('online', 'آنلاین'),
            ('banned', 'مسدود'), ('limited', 'محدود'),
            ('unverified', 'تأییدنشده')]),
        ('role', 'نقش', 'select', [
            ('', 'همه'), ('admin', 'ادمین'), ('support', 'پشتیبان')]),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)

    body = (filters +
            f'<div class="card"><h2>کاربران <span class="stat-label">'
            f'{pagination.total} مورد</span></h2>' +
            table(['نام', 'یوزرنیم', 'شماره', 'وضعیت', 'عضویت', 'عملیات'], rows) +
            '</div>' +
            pager(secret_path, 'users', page_no, pages, values))
    return page(secret_path, 'کاربران', body, 'users', _take_flash())


@admin_web_bp.route('/<path:secret_path>/users/<user_id>')
@admin_required
def admin_user_detail(secret_path, user_id):
    user = db.session.get(User, user_id)
    if not user:
        return page(secret_path, 'کاربر', '<div class="empty">کاربر یافت نشد</div>',
                    'users')
    csrf = _csrf_token()
    devices = UserDevice.query.filter_by(
        user_id=user_id, is_deleted=False).order_by(
        UserDevice.last_active.desc()).all()
    memberships = db.session.query(Chat, ChatMember).join(
        ChatMember, ChatMember.chat_id == Chat.id).filter(
        ChatMember.user_id == user_id, ChatMember.is_deleted.is_(False),
        Chat.is_deleted.is_(False)).limit(50).all()
    recent = Message.query.filter_by(sender_id=user_id).order_by(
        Message.created_at.desc()).limit(15).all()
    logs = AuditLog.query.filter_by(actor_id=user_id).order_by(
        AuditLog.created_at.desc()).limit(15).all()

    info = f"""<dl class="kv">
<dt>شناسه</dt><dd class="mono">{e(user.id)}</dd>
<dt>نام</dt><dd>{e(user.display_name)}</dd>
<dt>یوزرنیم</dt><dd>{e(user.username)}</dd>
<dt>ایمیل</dt><dd>{e(user.email)}</dd>
<dt>موبایل</dt><dd class="mono">{e(user.mobile_number)}</dd>
<dt>تأیید شماره</dt><dd>{_dt(user.mobile_verified_at)}</dd>
<dt>دو مرحله‌ای</dt><dd>{'فعال' if user.is_2fa_enabled else 'غیرفعال'}</dd>
<dt>قفل آرشیو</dt><dd>{'دارد' if user.has_archive_pin else 'ندارد'}</dd>
<dt>وضعیت</dt><dd>{'فعال' if user.is_active else 'مسدود'}
{' / محدود تا ' + _dt(user.limited_until) if user.is_limited else ''}</dd>
<dt>آخرین بازدید</dt><dd>{_dt(user.last_seen)}</dd>
<dt>عضویت</dt><dd>{_dt(user.created_at)}</dd>
</dl>"""

    actions = ' '.join([
        action_form(secret_path, f'users/{user.id}/toggle',
                    'فعال‌سازی' if not user.is_active else 'مسدود کردن', csrf,
                    cls='btn' if not user.is_active else 'btn btn-danger',
                    confirm='مطمئن هستید؟'),
        action_form(secret_path, f'users/{user.id}/limit',
                    'رفع محدودیت' if user.is_limited else 'محدود کردن (۷ روز)',
                    csrf, cls='btn btn-warn'),
        action_form(secret_path, f'users/{user.id}/logout-all',
                    'خروج از همه دستگاه‌ها', csrf, cls='btn btn-ghost',
                    confirm='همه نشست‌های این کاربر بسته شود؟'),
        action_form(secret_path, f'users/{user.id}/support',
                    'برداشتن نقش پشتیبان' if user.is_support else 'تعیین به‌عنوان پشتیبان',
                    csrf, cls='btn btn-ghost'),
    ])

    from app.services import app_settings
    current_cap = app_settings.user_limit_mb(user_id)
    cap_text = '' if not current_cap else (
        str(int(current_cap)) if float(current_cap).is_integer()
        else str(current_cap))
    upload_limit_form = f"""
<form method="post" action="/{secret_path}/settings/user-limit"
style="margin-top:16px">
<input type="hidden" name="csrf_token" value="{csrf}">
<input type="hidden" name="user_id" value="{e(user.id)}">
<input type="hidden" name="back" value="user">
<label class="stat-label">سقف حجم آپلود این کاربر (مگابایت — خالی یعنی بدون سقف اختصاصی)</label>
<div style="display:flex;gap:8px;margin-top:6px">
<input type="number" name="max_mb" min="0" max="10240" step="any"
value="{cap_text}" style="width:130px;background:#0b1220;border:1px solid var(--line);color:var(--text);border-radius:8px;padding:7px">
<button class="btn btn-sm" type="submit">ثبت سقف</button>
</div></form>"""

    device_rows = [
        f'<tr><td>{e(d.device_name)}'
        f'{" " + BADGE_PRIMARY if d.is_primary else ""}</td>'
        f'<td>{e(d.device_model)}</td><td>{e(d.os_version)}</td>'
        f'<td class="mono">{_dt(d.last_active)}</td></tr>' for d in devices]
    chat_rows = [
        f'<tr><td><a href="/{secret_path}/chats/{c.id}">{e(c.title or c.chat_type)}</a></td>'
        f'<td>{e(c.chat_type)}</td><td>{e(m.role)}</td></tr>'
        for c, m in memberships]
    msg_rows = [
        f'<tr><td>{e(m.message_type)}</td>'
        f'<td>{e((m.content or "")[:90])}</td>'
        f'<td class="mono">{_dt(m.created_at)}</td></tr>' for m in recent]
    log_rows = [
        f'<tr><td>{e(l.action)}</td><td class="mono">{e(l.ip_address)}</td>'
        f'<td class="mono">{_dt(l.created_at)}</td></tr>' for l in logs]

    body = f"""
<div class="stats">
{stat(Message.query.filter_by(sender_id=user_id).count(), 'پیام')}
{stat(len(memberships), 'چت')}
{stat(len(devices), 'دستگاه')}
{stat(Report.query.filter_by(target_user_id=user_id).count(), 'گزارش علیه', 'warn')}
{stat(SupportTicket.query.filter_by(user_id=user_id).count(), 'تیکت')}
</div>
<div class="grid2">
<div class="card"><h2>مشخصات</h2>{info}
<div class="actions" style="margin-top:14px">{actions}</div>{upload_limit_form}</div>
<div class="card"><h2>دستگاه‌ها</h2>
{table(['نام', 'مدل', 'سیستم', 'آخرین فعالیت'], device_rows)}</div>
</div>
<div class="grid2">
<div class="card"><h2>چت‌ها</h2>{table(['عنوان', 'نوع', 'نقش'], chat_rows)}</div>
<div class="card"><h2>آخرین پیام‌ها</h2>{table(['نوع', 'محتوا', 'زمان'], msg_rows)}</div>
</div>
<div class="card"><h2>فعالیت امنیتی</h2>{table(['عملیات', 'IP', 'زمان'], log_rows)}</div>
"""
    return page(secret_path, f'کاربر: {user.display_name}', body, 'users',
                _take_flash())


@admin_web_bp.route('/<path:secret_path>/users/<user_id>/toggle', methods=['POST'])
@admin_required
def toggle_user(secret_path, user_id):
    user = db.session.get(User, user_id)
    if not user:
        return _flash_redirect(secret_path, 'users', 'err', 'کاربر یافت نشد')
    user.is_active = not user.is_active
    if not user.is_active:
        # Blocking must cut live sessions, not just flip a flag.
        UserSession.query.filter_by(user_id=user.id, is_active=True).update(
            {'is_active': False}, synchronize_session=False)
    UserDevice.query.filter_by(user_id=user.id, is_deleted=False).update(
        {'is_active': user.is_active}, synchronize_session=False)
    _audit('admin_toggle_user', 'user', user_id, new_value=str(user.is_active))
    db.session.commit()
    return _flash_redirect(
        secret_path, f'users/{user_id}', 'ok',
        'کاربر فعال شد' if user.is_active else 'کاربر مسدود شد')


@admin_web_bp.route('/<path:secret_path>/users/<user_id>/limit', methods=['POST'])
@admin_required
def limit_user_web(secret_path, user_id):
    user = db.session.get(User, user_id)
    if not user:
        return _flash_redirect(secret_path, 'users', 'err', 'کاربر یافت نشد')
    if user.is_limited:
        user.is_limited = False
        user.limited_until = None
        user.limited_reason = None
        message = 'محدودیت برداشته شد'
    else:
        user.is_limited = True
        user.limited_until = datetime.utcnow() + timedelta(days=7)
        user.limited_reason = 'اعمال‌شده از پنل مدیریت'
        message = 'کاربر برای ۷ روز محدود شد'
    _audit('admin_limit_user', 'user', user_id, new_value=str(user.is_limited))
    db.session.commit()
    return _flash_redirect(secret_path, f'users/{user_id}', 'ok', message)


@admin_web_bp.route('/<path:secret_path>/users/<user_id>/logout-all',
                    methods=['POST'])
@admin_required
def logout_all_web(secret_path, user_id):
    count = UserSession.query.filter_by(user_id=user_id, is_active=True).count()
    UserSession.query.filter_by(user_id=user_id, is_active=True).update(
        {'is_active': False}, synchronize_session=False)
    UserDevice.query.filter_by(user_id=user_id, is_deleted=False).update(
        {'push_token': None, 'push_platform': None}, synchronize_session=False)
    _audit('admin_force_logout', 'user', user_id, new_value=str(count))
    db.session.commit()
    return _flash_redirect(secret_path, f'users/{user_id}', 'ok',
                           f'{count} نشست بسته شد')


@admin_web_bp.route('/<path:secret_path>/users/<user_id>/support',
                    methods=['POST'])
@admin_required
def toggle_support_role(secret_path, user_id):
    user = db.session.get(User, user_id)
    if not user:
        return _flash_redirect(secret_path, 'users', 'err', 'کاربر یافت نشد')
    user.is_support = not user.is_support
    _audit('admin_set_support_role', 'user', user_id,
           new_value=str(user.is_support))
    db.session.commit()
    return _flash_redirect(
        secret_path, f'users/{user_id}', 'ok',
        'نقش پشتیبان داده شد' if user.is_support else 'نقش پشتیبان برداشته شد')


# --------------------------------------------------------------------------
# chats
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/chats')
@admin_required
def admin_chats(secret_path):
    values = _args('q', 'chat_type', 'state', 'from', 'to')
    query = Chat.query.filter(Chat.is_deleted.is_(False))
    if values['q']:
        like = f"%{values['q']}%"
        query = query.filter(or_(Chat.title.ilike(like),
                                 Chat.username.ilike(like),
                                 Chat.id == values['q']))
    if values['chat_type']:
        query = query.filter(Chat.chat_type == values['chat_type'])
    if values['state'] == 'suspended':
        query = query.filter(Chat.is_suspended.is_(True))
    elif values['state'] == 'sponsored':
        query = query.filter(Chat.is_sponsored.is_(True))
    elif values['state'] == 'public':
        query = query.filter(Chat.is_public.is_(True))
    query = _apply_dates(query, Chat.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(Chat.updated_at.desc()))

    chat_ids = [c.id for c in pagination.items]
    members = dict(db.session.query(
        ChatMember.chat_id, func.count(ChatMember.id)).filter(
        ChatMember.chat_id.in_(chat_ids),
        ChatMember.is_deleted.is_(False)).group_by(
        ChatMember.chat_id).all()) if chat_ids else {}
    msgs = dict(db.session.query(
        Message.chat_id, func.count(Message.id)).filter(
        Message.chat_id.in_(chat_ids)).group_by(
        Message.chat_id).all()) if chat_ids else {}

    rows = []
    for c in pagination.items:
        marks = []
        if c.is_sponsored:
            marks.append('<span class="badge badge-info">اسپانسر</span>')
        if c.is_suspended:
            marks.append('<span class="badge badge-bad">معلق</span>')
        if c.is_public:
            marks.append('<span class="badge badge-off">عمومی</span>')
        rows.append(
            f'<tr><td><a href="/{secret_path}/chats/{c.id}">'
            f'{e(c.title or "—")}</a></td>'
            f'<td>{e(c.chat_type)}</td><td class="mono">{e(c.username)}</td>'
            f'<td>{members.get(c.id, 0)}</td><td>{msgs.get(c.id, 0)}</td>'
            f'<td>{" ".join(marks) or "—"}</td>'
            f'<td class="mono">{_dt(c.updated_at)}</td></tr>')

    filters = filter_bar(secret_path, 'chats', [
        ('q', 'جستجو (عنوان/یوزرنیم)', 'text', None),
        ('chat_type', 'نوع', 'select', [
            ('', 'همه'), ('private', 'خصوصی'), ('group', 'گروه'),
            ('channel', 'کانال'), ('support', 'پشتیبانی'), ('saved', 'ذخیره')]),
        ('state', 'وضعیت', 'select', [
            ('', 'همه'), ('public', 'عمومی'), ('sponsored', 'اسپانسرشده'),
            ('suspended', 'معلق')]),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)

    body = (filters +
            f'<div class="card"><h2>چت‌ها <span class="stat-label">'
            f'{pagination.total} مورد</span></h2>' +
            table(['عنوان', 'نوع', 'یوزرنیم', 'اعضا', 'پیام', 'وضعیت', 'به‌روزرسانی'],
                  rows) + '</div>' +
            pager(secret_path, 'chats', page_no, pages, values))
    return page(secret_path, 'چت‌ها', body, 'chats', _take_flash())


@admin_web_bp.route('/<path:secret_path>/chats/<chat_id>')
@admin_required
def admin_chat_detail(secret_path, chat_id):
    chat = db.session.get(Chat, chat_id)
    if not chat:
        return page(secret_path, 'چت', '<div class="empty">چت یافت نشد</div>',
                    'chats')
    csrf = _csrf_token()
    members = db.session.query(ChatMember, User).join(
        User, User.id == ChatMember.user_id).filter(
        ChatMember.chat_id == chat_id,
        ChatMember.is_deleted.is_(False)).limit(100).all()
    recent = Message.query.filter_by(chat_id=chat_id).order_by(
        Message.created_at.desc()).limit(40).all()
    senders = _names([m.sender_id for m in recent])

    member_rows = [
        f'<tr><td><a href="/{secret_path}/users/{u.id}">{e(u.display_name)}</a></td>'
        f'<td class="mono">{e(u.username)}</td><td>{e(m.role)}</td>'
        f'<td class="mono">{_dt(m.joined_at, "%Y-%m-%d")}</td></tr>'
        for m, u in members]
    msg_rows = []
    for m in recent:
        preview = (ENCRYPTED_LABEL if getattr(m, 'is_encrypted', False)
                   else e((m.content or '')[:110]))
        control = BADGE_DELETED if m.is_deleted_for_all else action_form(
            secret_path, f'messages/{m.id}/delete', 'حذف', csrf,
            cls='btn btn-sm btn-danger', confirm='این پیام برای همه حذف شود؟')
        msg_rows.append(
            f'<tr><td>{e(senders.get(m.sender_id, m.sender_id))}</td>'
            f'<td>{e(m.message_type)}</td><td>{preview}</td>'
            f'<td class="mono">{_dt(m.created_at)}</td>'
            f'<td>{control}</td></tr>')

    actions = action_form(
        secret_path, f'chats/{chat_id}/suspend',
        'رفع تعلیق' if chat.is_suspended else 'تعلیق چت', csrf,
        cls='btn btn-warn', confirm='مطمئن هستید؟')
    if chat.chat_type == 'channel':
        actions += ' ' + action_form(
            secret_path, f'chats/{chat_id}/sponsor',
            'حذف اسپانسر' if chat.is_sponsored else 'اسپانسر کردن', csrf,
            cls='btn btn-ghost')

    info = f"""<dl class="kv">
<dt>شناسه</dt><dd class="mono">{e(chat.id)}</dd>
<dt>نوع</dt><dd>{e(chat.chat_type)}</dd>
<dt>عنوان</dt><dd>{e(chat.title)}</dd>
<dt>یوزرنیم</dt><dd class="mono">{e(chat.username)}</dd>
<dt>توضیح</dt><dd>{e(chat.description)}</dd>
<dt>عمومی</dt><dd>{'بله' if chat.is_public else 'خیر'}</dd>
<dt>تعلیق</dt><dd>{('بله — ' + e(chat.suspension_reason)) if chat.is_suspended else 'خیر'}</dd>
<dt>ایجاد</dt><dd>{_dt(chat.created_at)}</dd>
</dl>"""

    body = f"""
<div class="stats">
{stat(len(members), 'اعضا')}
{stat(Message.query.filter_by(chat_id=chat_id).count(), 'پیام')}
{stat(Report.query.filter_by(target_chat_id=chat_id).count(), 'گزارش', 'warn')}
</div>
<div class="grid2">
<div class="card"><h2>مشخصات</h2>{info}
<div class="actions" style="margin-top:14px">{actions}</div></div>
<div class="card"><h2>اعضا</h2>
{table(['نام', 'یوزرنیم', 'نقش', 'عضویت'], member_rows)}</div>
</div>
<div class="card"><h2>آخرین پیام‌ها</h2>
{table(['فرستنده', 'نوع', 'محتوا', 'زمان', 'عملیات'], msg_rows)}</div>
"""
    return page(secret_path, f'چت: {chat.title or chat.chat_type}', body,
                'chats', _take_flash())


@admin_web_bp.route('/<path:secret_path>/chats/<chat_id>/suspend',
                    methods=['POST'])
@admin_required
def suspend_chat_web(secret_path, chat_id):
    chat = db.session.get(Chat, chat_id)
    if not chat:
        return _flash_redirect(secret_path, 'chats', 'err', 'چت یافت نشد')
    chat.is_suspended = not chat.is_suspended
    chat.suspension_reason = 'اعمال‌شده از پنل مدیریت' if chat.is_suspended else None
    chat.suspended_at = datetime.utcnow() if chat.is_suspended else None
    _audit('admin_suspend_chat', 'chat', chat_id,
           new_value=str(chat.is_suspended))
    db.session.commit()
    return _flash_redirect(
        secret_path, _back_target(default=f'chats/{chat_id}'), 'ok',
        'چت معلق شد' if chat.is_suspended else 'تعلیق برداشته شد')


@admin_web_bp.route('/<path:secret_path>/chats/<chat_id>/sponsor',
                    methods=['POST'])
@admin_required
def sponsor_chat_web(secret_path, chat_id):
    chat = db.session.get(Chat, chat_id)
    if not chat or chat.chat_type != 'channel':
        return _flash_redirect(secret_path, 'chats', 'err',
                               'فقط کانال‌ها اسپانسر می‌شوند')
    chat.is_sponsored = not chat.is_sponsored
    chat.sponsored_at = datetime.utcnow() if chat.is_sponsored else None
    _audit('sponsor_channel', 'chat', chat_id, new_value=str(chat.is_sponsored))
    db.session.commit()
    return _flash_redirect(secret_path, f'chats/{chat_id}', 'ok',
                           'وضعیت اسپانسر تغییر کرد')


# --------------------------------------------------------------------------
# messages
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/messages')
@admin_required
def admin_messages(secret_path):
    values = _args('q', 'chat_id', 'sender_id', 'message_type', 'deleted',
                   'from', 'to')
    query = Message.query
    if values['q']:
        query = query.filter(Message.content.ilike(f"%{values['q']}%"))
    if values['chat_id']:
        query = query.filter(Message.chat_id == values['chat_id'])
    if values['sender_id']:
        query = query.filter(Message.sender_id == values['sender_id'])
    if values['message_type']:
        query = query.filter(Message.message_type == values['message_type'])
    if values['deleted'] == 'yes':
        query = query.filter(or_(Message.is_deleted.is_(True),
                                 Message.is_deleted_for_all.is_(True)))
    elif values['deleted'] == 'no':
        query = query.filter(Message.is_deleted.is_(False),
                             Message.is_deleted_for_all.is_(False))
    query = _apply_dates(query, Message.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(Message.created_at.desc()))

    csrf = _csrf_token()
    senders = _names([m.sender_id for m in pagination.items])
    rows = []
    for m in pagination.items:
        content = (ENCRYPTED_LABEL if getattr(m, 'is_encrypted', False)
                   else e((m.content or '')[:110]))
        state = (BADGE_DELETED if m.is_deleted_for_all or m.is_deleted
                 else BADGE_ACTIVE)
        delete = ('' if m.is_deleted_for_all else action_form(
            secret_path, f'messages/{m.id}/delete', 'حذف', csrf,
            cls='btn btn-sm btn-danger', confirm='برای همه حذف شود؟'))
        rows.append(
            f'<tr><td><a href="/{secret_path}/users/{m.sender_id}">'
            f'{e(senders.get(m.sender_id, m.sender_id))}</a></td>'
            f'<td><a href="/{secret_path}/chats/{m.chat_id}">چت</a></td>'
            f'<td>{e(m.message_type)}</td><td>{content}</td>'
            f'<td>{state}</td><td class="mono">{_dt(m.created_at)}</td>'
            f'<td>{delete}</td></tr>')

    filters = filter_bar(secret_path, 'messages', [
        ('q', 'جستجوی متن', 'text', None),
        ('chat_id', 'شناسه چت', 'text', None),
        ('sender_id', 'شناسه فرستنده', 'text', None),
        ('message_type', 'نوع', 'select', [
            ('', 'همه'), ('text', 'متن'), ('image', 'عکس'), ('video', 'ویدیو'),
            ('voice', 'صوت'), ('file', 'فایل'), ('poll', 'نظرسنجی'),
            ('sticker', 'استیکر'), ('gif', 'گیف')]),
        ('deleted', 'حذف‌شده', 'select', [
            ('', 'همه'), ('no', 'فقط فعال'), ('yes', 'فقط حذف‌شده')]),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)

    body = (filters +
            f'<div class="card"><h2>پیام‌ها <span class="stat-label">'
            f'{pagination.total} مورد</span></h2>' +
            table(['فرستنده', 'چت', 'نوع', 'محتوا', 'وضعیت', 'زمان', 'عملیات'],
                  rows) + '</div>' +
            pager(secret_path, 'messages', page_no, pages, values))
    return page(secret_path, 'پیام‌ها', body, 'messages', _take_flash())


@admin_web_bp.route('/<path:secret_path>/messages/<message_id>/delete',
                    methods=['POST'])
@admin_required
def delete_message_web(secret_path, message_id):
    message = db.session.get(Message, message_id)
    if not message:
        return _flash_redirect(secret_path, 'messages', 'err', 'پیام یافت نشد')
    message.is_deleted = True
    message.is_deleted_for_all = True
    message.deleted_at = datetime.utcnow()
    _audit('admin_delete_message', 'message', message_id)
    db.session.commit()
    return _flash_redirect(secret_path, _back_target(default='messages'),
                           'ok', 'پیام حذف شد')


# --------------------------------------------------------------------------
# support (tickets + user↔support chats)
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/support')
@admin_required
def admin_support(secret_path):
    tab = (request.args.get('tab') or 'chats').strip()
    if tab == 'tickets':
        return _support_tickets(secret_path)
    return _support_chats(secret_path)


def _support_tabs(secret_path, active, open_tickets, threads):
    return (f'<div class="tabs">'
            f'<a class="{"active" if active == "chats" else ""}" '
            f'href="/{secret_path}/support?tab=chats">💬 گفتگوهای پشتیبانی ({threads})</a>'
            f'<a class="{"active" if active == "tickets" else ""}" '
            f'href="/{secret_path}/support?tab=tickets">🎫 تیکت‌ها ({open_tickets})</a>'
            f'</div>')


def _support_counts():
    return (
        SupportTicket.query.filter(
            SupportTicket.status.in_(['open', 'in_progress'])).count(),
        Chat.query.filter_by(chat_type='support', is_deleted=False).count(),
    )


def _support_chats(secret_path):
    values = _args('q')
    query = Chat.query.filter(Chat.chat_type == 'support',
                              Chat.is_deleted.is_(False))
    pagination, page_no, pages = _paginate(
        query.order_by(Chat.updated_at.desc()), per_page=25)

    chat_ids = [c.id for c in pagination.items]
    rows_raw = db.session.query(ChatMember, User).join(
        User, User.id == ChatMember.user_id).filter(
        ChatMember.chat_id.in_(chat_ids),
        ChatMember.is_deleted.is_(False)).all() if chat_ids else []
    requester = {}
    for member, user in rows_raw:
        if not user.is_support and member.chat_id not in requester:
            requester[member.chat_id] = user

    rows = []
    for c in pagination.items:
        peer = requester.get(c.id)
        if values['q'] and peer:
            needle = values['q'].lower()
            haystack = ' '.join(filter(None, [
                peer.display_name, peer.username, peer.mobile_number])).lower()
            if needle not in haystack:
                continue
        last = Message.query.filter_by(chat_id=c.id).order_by(
            Message.created_at.desc()).first()
        from_user = Message.query.filter_by(
            chat_id=c.id, sender_id=peer.id).count() if peer else 0
        rows.append(
            f'<tr><td>' +
            (f'<a href="/{secret_path}/users/{peer.id}">{e(peer.display_name)}</a>'
             if peer else '—') +
            f'</td><td class="mono">{e(peer.mobile_number) if peer else "—"}</td>'
            f'<td>{e((last.content or "")[:80]) if last else "—"}</td>'
            f'<td>{from_user}</td>'
            f'<td class="mono">{_dt(c.updated_at)}</td>'
            f'<td><a class="btn btn-sm" href="/{secret_path}/support/chat/{c.id}">'
            f'باز کردن</a></td></tr>')

    open_tickets, threads = _support_counts()
    filters = filter_bar(secret_path, 'support', [
        ('q', 'جستجوی کاربر', 'text', None),
    ], values)
    body = (_support_tabs(secret_path, 'chats', open_tickets, threads) +
            filters +
            '<div class="card"><h2>گفتگوهایی که کاربران به پشتیبانی فرستاده‌اند</h2>' +
            table(['کاربر', 'شماره', 'آخرین پیام', 'پیام کاربر', 'به‌روزرسانی',
                   'عملیات'], rows,
                  'هنوز هیچ کاربری به پشتیبانی پیام نداده است') +
            '</div>' +
            pager(secret_path, 'support', page_no, pages,
                  {**values, 'tab': 'chats'}))
    return page(secret_path, 'پشتیبانی', body, 'support', _take_flash())


@admin_web_bp.route('/<path:secret_path>/support/chat/<chat_id>')
@admin_required
def admin_support_thread(secret_path, chat_id):
    chat = Chat.query.filter_by(id=chat_id, chat_type='support',
                                is_deleted=False).first()
    if not chat:
        return page(secret_path, 'پشتیبانی',
                    '<div class="empty">گفتگو یافت نشد</div>', 'support')
    csrf = _csrf_token()
    members = db.session.query(ChatMember, User).join(
        User, User.id == ChatMember.user_id).filter(
        ChatMember.chat_id == chat_id,
        ChatMember.is_deleted.is_(False)).all()
    peer = next((u for _m, u in members if not u.is_support), None)
    support_ids = {u.id for _m, u in members if u.is_support}

    messages = Message.query.filter_by(chat_id=chat_id).order_by(
        Message.created_at.asc()).limit(300).all()
    names = _names([m.sender_id for m in messages])
    bubbles = ''.join(
        f'<div class="msg {"theirs" if m.sender_id in support_ids or (peer and m.sender_id != peer.id) else "mine"}">'
        f'{e(m.content or ("[" + (m.message_type or "media") + "]"))}'
        f'<span class="meta">{e(names.get(m.sender_id, m.sender_id))} · '
        f'{_dt(m.created_at)}</span></div>'
        for m in messages) or '<div class="empty">پیامی نیست</div>'

    peer_info = ''
    if peer:
        peer_info = f"""<dl class="kv">
<dt>کاربر</dt><dd><a href="/{secret_path}/users/{peer.id}">{e(peer.display_name)}</a></dd>
<dt>یوزرنیم</dt><dd class="mono">{e(peer.username)}</dd>
<dt>موبایل</dt><dd class="mono">{e(peer.mobile_number)}</dd>
<dt>وضعیت</dt><dd>{'فعال' if peer.is_active else 'مسدود'}</dd>
<dt>عضویت</dt><dd>{_dt(peer.created_at)}</dd>
</dl>"""

    body = f"""
<div class="grid2">
<div class="card"><h2>گفتگو</h2><div class="thread">{bubbles}</div>
<form class="reply" method="post"
 action="/{secret_path}/support/chat/{chat_id}/reply">
<input type="hidden" name="csrf_token" value="{e(csrf)}">
<textarea name="content" placeholder="پاسخ خود را بنویسید…" required></textarea>
<button class="btn" type="submit">ارسال</button>
</form></div>
<div class="card"><h2>اطلاعات کاربر</h2>{peer_info or '<div class="empty">—</div>'}</div>
</div>
"""
    return page(secret_path, 'گفتگوی پشتیبانی', body, 'support', _take_flash())


@admin_web_bp.route('/<path:secret_path>/support/chat/<chat_id>/reply',
                    methods=['POST'])
@admin_required
def admin_support_reply(secret_path, chat_id):
    chat = Chat.query.filter_by(id=chat_id, chat_type='support',
                                is_deleted=False).first()
    if not chat:
        return _flash_redirect(secret_path, 'support', 'err', 'گفتگو یافت نشد')
    content = (request.form.get('content') or '').strip()
    if not content:
        return _flash_redirect(secret_path, f'support/chat/{chat_id}', 'err',
                               'متن پاسخ خالی بود')

    # Reply as the designated support account so the user sees a real sender.
    agent = User.query.filter_by(is_support=True, is_deleted=False).first()
    if not agent:
        return _flash_redirect(
            secret_path, f'support/chat/{chat_id}', 'err',
            'هیچ کاربری به‌عنوان پشتیبان تعیین نشده است. از صفحه کاربران یک نفر را پشتیبان کنید.')
    member = ChatMember.query.filter_by(chat_id=chat_id,
                                        user_id=agent.id).first()
    if member is None:
        db.session.add(ChatMember(chat_id=chat_id, user_id=agent.id,
                                  role='admin'))
    elif member.is_deleted:
        member.is_deleted = False
        member.deleted_at = None

    db.session.add(Message(chat_id=chat_id, sender_id=agent.id,
                           message_type='text', content=content[:4000]))
    chat.updated_at = datetime.utcnow()
    _audit('admin_support_reply', 'chat', chat_id)
    db.session.commit()
    return _flash_redirect(secret_path, f'support/chat/{chat_id}', 'ok',
                           'پاسخ ارسال شد')


def _support_tickets(secret_path):
    values = _args('q', 'status', 'topic')
    query = SupportTicket.query
    if values['status']:
        query = query.filter(SupportTicket.status == values['status'])
    if values['topic']:
        query = query.filter(SupportTicket.topic == values['topic'])
    if values['q']:
        like = f"%{values['q']}%"
        query = query.filter(or_(SupportTicket.message.ilike(like),
                                 SupportTicket.mobile_number.ilike(like),
                                 SupportTicket.display_name.ilike(like)))
    pagination, page_no, pages = _paginate(
        query.order_by(SupportTicket.created_at.desc()), per_page=25)

    csrf = _csrf_token()
    tone = {'open': 'badge-warn', 'in_progress': 'badge-info',
            'resolved': 'badge-ok', 'closed': 'badge-off'}
    rows = []
    for t in pagination.items:
        buttons = ' '.join(
            action_form(secret_path, f'support/tickets/{t.id}/status', label,
                        csrf, cls='btn btn-sm btn-ghost',
                        hidden={'status': value})
            for value, label in (('in_progress', 'در حال بررسی'),
                                 ('resolved', 'حل شد'), ('closed', 'بستن'))
            if t.status != value)
        rows.append(
            f'<tr><td>{e(t.topic)}</td>'
            f'<td class="mono">{e(t.mobile_number)}</td>'
            f'<td>{e(t.display_name)}</td>'
            f'<td style="max-width:340px;white-space:pre-wrap">{e(t.message[:400])}</td>'
            f'<td><span class="badge {tone.get(t.status, "badge-off")}">'
            f'{e(t.status)}</span></td>'
            f'<td class="mono">{_dt(t.created_at)}</td>'
            f'<td class="actions">{buttons}</td></tr>')

    open_tickets, threads = _support_counts()
    filters = filter_bar(secret_path, 'support', [
        ('q', 'جستجو', 'text', None),
        ('status', 'وضعیت', 'select',
         [('', 'همه')] + [(s, s) for s in TICKET_STATUSES]),
        ('topic', 'موضوع', 'select', [
            ('', 'همه'), ('code_not_received', 'کد دریافت نشد'),
            ('login_problem', 'مشکل ورود'), ('account_locked', 'حساب مسدود'),
            ('bug_report', 'گزارش اشکال'), ('abuse', 'سوءاستفاده'),
            ('other', 'سایر')]),
    ], values)
    body = (_support_tabs(secret_path, 'tickets', open_tickets, threads) +
            filters +
            '<div class="card"><h2>تیکت‌های ثبت‌شده از صفحه ورود و داخل برنامه</h2>' +
            table(['موضوع', 'شماره', 'نام', 'پیام', 'وضعیت', 'زمان', 'عملیات'],
                  rows, 'تیکتی ثبت نشده است') + '</div>' +
            pager(secret_path, 'support', page_no, pages,
                  {**values, 'tab': 'tickets'}))
    return page(secret_path, 'پشتیبانی', body, 'support', _take_flash())


@admin_web_bp.route('/<path:secret_path>/support/tickets/<ticket_id>/status',
                    methods=['POST'])
@admin_required
def update_ticket_web(secret_path, ticket_id):
    ticket = db.session.get(SupportTicket, ticket_id)
    if not ticket:
        return _flash_redirect(secret_path, 'support?tab=tickets', 'err',
                               'تیکت یافت نشد')
    status = request.form.get('status', '')
    if status not in TICKET_STATUSES:
        return _flash_redirect(secret_path, 'support?tab=tickets', 'err',
                               'وضعیت نامعتبر است')
    ticket.status = status
    ticket.updated_at = datetime.utcnow()
    if status in ('resolved', 'closed'):
        ticket.resolved_at = datetime.utcnow()
    _audit('admin_update_ticket', 'support_ticket', ticket_id,
           new_value=status)
    db.session.commit()
    return _flash_redirect(secret_path, 'support?tab=tickets', 'ok',
                           'وضعیت تیکت به‌روزرسانی شد')


# --------------------------------------------------------------------------
# reports / media / devices / security / audit
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/reports')
@admin_required
def admin_reports(secret_path):
    values = _args('status', 'reason', 'target_type')
    query = Report.query
    if values['status']:
        query = query.filter(Report.status == values['status'])
    if values['reason']:
        query = query.filter(Report.reason == values['reason'])
    if values['target_type']:
        query = query.filter(Report.target_type == values['target_type'])
    pagination, page_no, pages = _paginate(
        query.order_by(Report.created_at.desc()))
    reporters = _names([r.reporter_id for r in pagination.items])
    tone = {'pending': 'badge-warn', 'reviewed': 'badge-info',
            'action_taken': 'badge-ok', 'dismissed': 'badge-off'}
    # Point 2: every row links to a detail page where the reported chat can
    # actually be inspected and acted on. Before this the queue was read-only.
    targets = _report_targets(pagination.items)
    rows = [
        f'<tr><td>{e(reporters.get(r.reporter_id, r.reporter_id))}</td>'
        f'<td>{targets.get(r.id, e(r.target_type))}</td><td>{e(r.reason)}</td>'
        f'<td>{e((r.description or "")[:120])}</td>'
        f'<td><span class="badge {tone.get(r.status, "badge-off")}">'
        f'{e(r.status)}</span></td>'
        f'<td class="mono">{_dt(r.created_at)}</td>'
        f'<td><a class="btn btn-sm" href="/{secret_path}/reports/{r.id}">'
        f'بررسی</a></td></tr>'
        for r in pagination.items]
    filters = filter_bar(secret_path, 'reports', [
        ('status', 'وضعیت', 'select', [
            ('', 'همه'), ('pending', 'در انتظار'), ('reviewed', 'بررسی‌شده'),
            ('action_taken', 'اقدام‌شده'), ('dismissed', 'رد شده')]),
        ('target_type', 'هدف', 'select', [
            ('', 'همه'), ('user', 'کاربر'), ('group', 'گروه'),
            ('channel', 'کانال'), ('message', 'پیام')]),
        ('reason', 'دلیل', 'text', None),
    ], values)
    body = (filters + '<div class="card"><h2>گزارش‌های کاربران</h2>' +
            table(['گزارش‌دهنده', 'هدف', 'دلیل', 'توضیح', 'وضعیت', 'زمان',
                   'عملیات'],
                  rows, 'گزارشی ثبت نشده است') + '</div>' +
            pager(secret_path, 'reports', page_no, pages, values))
    return page(secret_path, 'گزارش‌ها', body, 'reports', _take_flash())



def _back_target(default='reports'):
    """Where a moderation action should return to.

    Forms rendered on the report page pass a ``back`` field so the admin lands
    back on the report instead of being thrown to a generic list.
    """
    back = (request.form.get('back') or '').strip().lstrip('/')
    # Only relative, in-panel paths — never an open redirect.
    if not back or '//' in back or ':' in back:
        return default
    return back


def _report_targets(reports):
    """Human-readable, linked target cell for each report."""
    chat_ids = {r.target_chat_id for r in reports if r.target_chat_id}
    user_ids = {r.target_user_id for r in reports if r.target_user_id}
    chats = {c.id: c for c in Chat.query.filter(Chat.id.in_(chat_ids)).all()} \
        if chat_ids else {}
    users = {u.id: u for u in User.query.filter(User.id.in_(user_ids)).all()} \
        if user_ids else {}
    out = {}
    for r in reports:
        if r.target_chat_id and r.target_chat_id in chats:
            chat = chats[r.target_chat_id]
            label = chat.title or chat.username or chat.id[:8]
            out[r.id] = (f'<span class="badge badge-info">{e(chat.chat_type)}'
                         f'</span> {e(label)}')
        elif r.target_user_id and r.target_user_id in users:
            user = users[r.target_user_id]
            out[r.id] = (f'<span class="badge">کاربر</span> '
                         f'{e(user.display_name)}')
        else:
            out[r.id] = e(r.target_type)
    return out


REPORT_STATUSES = [
    ('pending', 'در انتظار'),
    ('reviewed', 'بررسی‌شده'),
    ('action_taken', 'اقدام‌شده'),
    ('dismissed', 'رد شده'),
]


@admin_web_bp.route('/<path:secret_path>/reports/<report_id>')
@admin_required
def admin_report_detail(secret_path, report_id):
    """Point 2: inspect a report, read the reported chat, and act on it."""
    report = db.session.get(Report, report_id)
    if not report:
        return page(secret_path, 'گزارش',
                    '<div class="empty">گزارش یافت نشد</div>', 'reports')
    csrf = _csrf_token()
    reporter = db.session.get(User, report.reporter_id)
    target_user = (db.session.get(User, report.target_user_id)
                   if report.target_user_id else None)
    chat = (db.session.get(Chat, report.target_chat_id)
            if report.target_chat_id else None)
    message = (db.session.get(Message, report.target_message_id)
               if report.target_message_id else None)

    # ---- status controls -------------------------------------------------
    status_buttons = ' '.join(
        action_form(secret_path, f'reports/{report_id}/status', label, csrf,
                    cls='btn btn-sm' + (' btn-ok' if report.status == key
                                        else ' btn-ghost'),
                    hidden={'status': key})
        for key, label in REPORT_STATUSES)

    note_form = (
        f'<form method="post" class="stack" '
        f'action="/{secret_path}/reports/{report_id}/note">'
        f'<input type="hidden" name="csrf_token" value="{csrf}">'
        f'<textarea name="admin_note" rows="3" placeholder="یادداشت مدیر…">'
        f'{e(report.admin_note or "")}</textarea>'
        f'<button class="btn" type="submit">ذخیره یادداشت</button></form>')

    info = f"""<dl class="kv">
<dt>شناسه</dt><dd class="mono">{e(report.id)}</dd>
<dt>گزارش‌دهنده</dt><dd>{
    f'<a href="/{secret_path}/users/{report.reporter_id}">'
    f'{e(reporter.display_name)}</a>' if reporter else e(report.reporter_id)}</dd>
<dt>نوع هدف</dt><dd>{e(report.target_type)}</dd>
<dt>دلیل</dt><dd>{e(report.reason)}</dd>
<dt>توضیح</dt><dd>{e(report.description) or '—'}</dd>
<dt>وضعیت</dt><dd>{e(report.status)}</dd>
<dt>زمان</dt><dd class="mono">{_dt(report.created_at)}</dd>
<dt>رسیدگی</dt><dd class="mono">{_dt(report.resolved_at) or '—'}</dd>
</dl>"""

    # ---- the reported chat, with its content ----------------------------
    if chat is not None:
        members = db.session.query(ChatMember, User).join(
            User, User.id == ChatMember.user_id).filter(
            ChatMember.chat_id == chat.id,
            ChatMember.is_deleted.is_(False)).limit(50).all()
        recent = Message.query.filter_by(chat_id=chat.id).order_by(
            Message.created_at.desc()).limit(50).all()
        senders = _names([m.sender_id for m in recent])
        msg_rows = []
        for m in recent:
            preview = (ENCRYPTED_LABEL if getattr(m, 'is_encrypted', False)
                       else e((m.content or '')[:140]))
            flag = (' <span class="badge badge-bad">گزارش‌شده</span>'
                    if message is not None and m.id == message.id else '')
            control = BADGE_DELETED if m.is_deleted_for_all else action_form(
                secret_path, f'messages/{m.id}/delete', 'حذف', csrf,
                cls='btn btn-sm btn-danger',
                confirm='این پیام برای همه حذف شود؟',
                hidden={'back': f'reports/{report_id}'})
            msg_rows.append(
                f'<tr><td>{e(senders.get(m.sender_id, m.sender_id))}</td>'
                f'<td>{e(m.message_type)}</td><td>{preview}{flag}</td>'
                f'<td class="mono">{_dt(m.created_at)}</td>'
                f'<td>{control}</td></tr>')
        member_rows = [
            f'<tr><td><a href="/{secret_path}/users/{u.id}">'
            f'{e(u.display_name)}</a></td>'
            f'<td class="mono">{e(u.username)}</td><td>{e(cm.role)}</td></tr>'
            for cm, u in members]

        chat_actions = ' '.join([
            f'<a class="btn btn-ghost" href="/{secret_path}/chats/{chat.id}">'
            f'صفحه کامل چت</a>',
            action_form(secret_path, f'chats/{chat.id}/suspend',
                        'رفع تعلیق' if chat.is_suspended else 'تعلیق',
                        csrf, cls='btn btn-warn',
                        hidden={'back': f'reports/{report_id}'}),
            action_form(secret_path, f'chats/{chat.id}/delete',
                        'حذف کامل گروه/کانال', csrf, cls='btn btn-danger',
                        confirm='این گروه/کانال برای همه اعضا حذف شود؟ '
                                'این کار قابل بازگشت نیست.',
                        hidden={'back': 'reports'}),
        ])
        chat_info = f"""<dl class="kv">
<dt>نوع</dt><dd>{e(chat.chat_type)}</dd>
<dt>عنوان</dt><dd>{e(chat.title)}</dd>
<dt>یوزرنیم</dt><dd class="mono">{e(chat.username) or '—'}</dd>
<dt>توضیح</dt><dd>{e(chat.description) or '—'}</dd>
<dt>اعضا</dt><dd>{len(members)}</dd>
<dt>وضعیت</dt><dd>{'معلق' if chat.is_suspended else 'فعال'}</dd>
</dl>"""
        target_block = f"""
<div class="grid2">
<div class="card"><h2>گروه/کانال گزارش‌شده</h2>{chat_info}
<div class="actions" style="margin-top:14px">{chat_actions}</div></div>
<div class="card"><h2>اعضا</h2>
{table(['نام', 'یوزرنیم', 'نقش'], member_rows)}</div>
</div>
<div class="card"><h2>محتوای چت (۵۰ پیام اخیر)</h2>
{table(['فرستنده', 'نوع', 'محتوا', 'زمان', 'عملیات'], msg_rows,
       'پیامی وجود ندارد')}</div>"""
    elif target_user is not None:
        user_actions = ' '.join([
            f'<a class="btn btn-ghost" '
            f'href="/{secret_path}/users/{target_user.id}">پرونده کاربر</a>',
            action_form(secret_path, f'users/{target_user.id}/toggle',
                        'رفع مسدودی' if not target_user.is_active else 'مسدود',
                        csrf, cls='btn btn-danger',
                        hidden={'back': f'reports/{report_id}'}),
        ])
        target_block = (
            f'<div class="card"><h2>کاربر گزارش‌شده</h2><dl class="kv">'
            f'<dt>نام</dt><dd>{e(target_user.display_name)}</dd>'
            f'<dt>یوزرنیم</dt><dd class="mono">{e(target_user.username)}</dd>'
            f'<dt>وضعیت</dt><dd>{_presence(target_user)}</dd></dl>'
            f'<div class="actions" style="margin-top:14px">{user_actions}</div>'
            f'</div>')
    else:
        target_block = ('<div class="card"><h2>هدف گزارش</h2>'
                        '<div class="empty">هدف این گزارش دیگر موجود نیست</div>'
                        '</div>')

    reported_message = ''
    if message is not None and chat is None:
        reported_message = (
            f'<div class="card"><h2>پیام گزارش‌شده</h2>'
            f'<p class="mono">{e((message.content or "")[:400])}</p>'
            f'<div class="actions">' +
            action_form(secret_path, f'messages/{message.id}/delete',
                        'حذف پیام', csrf, cls='btn btn-danger',
                        hidden={'back': f'reports/{report_id}'}) +
            '</div></div>')

    body = f"""
<div class="grid2">
<div class="card"><h2>گزارش</h2>{info}
<div class="actions" style="margin-top:14px">{status_buttons}</div></div>
<div class="card"><h2>یادداشت مدیر</h2>{note_form}</div>
</div>
{target_block}
{reported_message}
"""
    return page(secret_path, 'بررسی گزارش', body, 'reports', _take_flash())


@admin_web_bp.route('/<path:secret_path>/reports/<report_id>/status',
                    methods=['POST'])
@admin_required
def admin_report_status(secret_path, report_id):
    report = db.session.get(Report, report_id)
    if not report:
        return _flash_redirect(secret_path, 'reports', 'err', 'گزارش یافت نشد')
    status = (request.form.get('status') or '').strip()
    if status not in {key for key, _ in REPORT_STATUSES}:
        return _flash_redirect(secret_path, f'reports/{report_id}', 'err',
                               'وضعیت نامعتبر است')
    report.status = status
    report.resolved_at = (datetime.utcnow()
                          if status in ('action_taken', 'dismissed', 'reviewed')
                          else None)
    _audit('admin_report_status', 'report', report_id, new_value=status)
    db.session.commit()
    return _flash_redirect(secret_path, f'reports/{report_id}', 'ok',
                           'وضعیت گزارش به‌روز شد')


@admin_web_bp.route('/<path:secret_path>/reports/<report_id>/note',
                    methods=['POST'])
@admin_required
def admin_report_note(secret_path, report_id):
    report = db.session.get(Report, report_id)
    if not report:
        return _flash_redirect(secret_path, 'reports', 'err', 'گزارش یافت نشد')
    report.admin_note = (request.form.get('admin_note') or '').strip()[:2000]
    _audit('admin_report_note', 'report', report_id)
    db.session.commit()
    return _flash_redirect(secret_path, f'reports/{report_id}', 'ok',
                           'یادداشت ذخیره شد')


@admin_web_bp.route('/<path:secret_path>/chats/<chat_id>/delete',
                    methods=['POST'])
@admin_required
def delete_chat_web(secret_path, chat_id):
    """Point 2: remove an abusive group/channel for everybody.

    Soft delete, matching the rest of the product: the chat disappears from
    every member's list and its messages stop being served, but the rows stay
    for audit and possible recovery.
    """
    chat = db.session.get(Chat, chat_id)
    if not chat:
        return _flash_redirect(secret_path, 'chats', 'err', 'چت یافت نشد')
    if chat.chat_type not in ('group', 'channel'):
        return _flash_redirect(
            secret_path, f'chats/{chat_id}', 'err',
            'فقط گروه و کانال از این بخش حذف می‌شوند')
    title = chat.title or chat.id
    chat.is_deleted = True
    chat.deleted_at = datetime.utcnow()
    ChatMember.query.filter_by(chat_id=chat_id).update(
        {'is_deleted': True}, synchronize_session=False)
    Message.query.filter_by(chat_id=chat_id).update(
        {'is_deleted_for_all': True}, synchronize_session=False)
    # Any report about this chat is now resolved by the deletion.
    Report.query.filter_by(target_chat_id=chat_id, status='pending').update(
        {'status': 'action_taken', 'resolved_at': datetime.utcnow()},
        synchronize_session=False)
    _audit('admin_delete_chat', 'chat', chat_id, old_value=title)
    db.session.commit()
    return _flash_redirect(secret_path, _back_target(default='chats'), 'ok',
                           f'«{title}» حذف شد')


@admin_web_bp.route('/<path:secret_path>/media')
@admin_required
def admin_media(secret_path):
    values = _args('q', 'media_type', 'from', 'to')
    query = MediaFile.query.filter(MediaFile.is_deleted.is_(False))
    if values['q']:
        query = query.filter(MediaFile.original_name.ilike(f"%{values['q']}%"))
    if values['media_type']:
        query = query.filter(MediaFile.media_type == values['media_type'])
    query = _apply_dates(query, MediaFile.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(MediaFile.created_at.desc()))
    uploaders = _names([m.uploader_id for m in pagination.items])
    total_size = db.session.query(
        func.coalesce(func.sum(MediaFile.file_size), 0)).filter(
        MediaFile.is_deleted.is_(False)).scalar() or 0
    rows = [
        f'<tr><td>{e(m.original_name)}</td><td>{e(m.media_type)}</td>'
        f'<td class="mono">{_human_bytes(m.file_size)}</td>'
        f'<td><a href="/{secret_path}/users/{m.uploader_id}">'
        f'{e(uploaders.get(m.uploader_id, m.uploader_id))}</a></td>'
        f'<td class="mono">{_dt(m.created_at)}</td></tr>'
        for m in pagination.items]
    filters = filter_bar(secret_path, 'media', [
        ('q', 'نام فایل', 'text', None),
        ('media_type', 'نوع', 'select', [
            ('', 'همه'), ('image', 'عکس'), ('video', 'ویدیو'),
            ('audio', 'صوت'), ('document', 'سند')]),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)
    body = (f'<div class="stats">{stat(pagination.total, "فایل")}'
            f'{stat(_human_bytes(total_size), "حجم کل")}</div>' + filters +
            '<div class="card"><h2>رسانه‌ها</h2>' +
            table(['نام', 'نوع', 'حجم', 'آپلودکننده', 'زمان'], rows) +
            '</div>' + pager(secret_path, 'media', page_no, pages, values))
    return page(secret_path, 'رسانه‌ها', body, 'media', _take_flash())


@admin_web_bp.route('/<path:secret_path>/devices')
@admin_required
def admin_devices(secret_path):
    values = _args('q', 'primary')
    query = UserDevice.query.filter(UserDevice.is_deleted.is_(False))
    if values['q']:
        like = f"%{values['q']}%"
        query = query.filter(or_(UserDevice.device_name.ilike(like),
                                 UserDevice.device_model.ilike(like),
                                 UserDevice.user_id == values['q']))
    if values['primary'] == 'yes':
        query = query.filter(UserDevice.is_primary.is_(True))
    pagination, page_no, pages = _paginate(
        query.order_by(UserDevice.last_active.desc()))
    owners = _names([d.user_id for d in pagination.items])
    rows = [
        f'<tr><td><a href="/{secret_path}/users/{d.user_id}">'
        f'{e(owners.get(d.user_id, d.user_id))}</a></td>'
        f'<td>{e(d.device_name)}'
        f'{" " + BADGE_PRIMARY if d.is_primary else ""}</td>'
        f'<td>{e(d.device_model)}</td><td>{e(d.os_version)}</td>'
        f'<td>{e(d.app_version)}</td>'
        f'<td class="mono">{_dt(d.last_active)}</td></tr>'
        for d in pagination.items]
    filters = filter_bar(secret_path, 'devices', [
        ('q', 'جستجو (نام دستگاه/کاربر)', 'text', None),
        ('primary', 'فقط دستگاه اصلی', 'select',
         [('', 'همه'), ('yes', 'بله')]),
    ], values)
    body = (filters + '<div class="card"><h2>دستگاه‌ها</h2>' +
            table(['کاربر', 'دستگاه', 'مدل', 'سیستم', 'نسخه', 'آخرین فعالیت'],
                  rows) + '</div>' +
            pager(secret_path, 'devices', page_no, pages, values))
    return page(secret_path, 'دستگاه‌ها', body, 'devices', _take_flash())


@admin_web_bp.route('/<path:secret_path>/security')
@admin_required
def admin_security(secret_path):
    values = _args('alert_type', 'severity', 'from', 'to')
    query = SecurityAlert.query
    if values['alert_type']:
        query = query.filter(SecurityAlert.alert_type == values['alert_type'])
    if values['severity']:
        query = query.filter(SecurityAlert.severity == values['severity'])
    query = _apply_dates(query, SecurityAlert.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(SecurityAlert.created_at.desc()))
    owners = _names([a.user_id for a in pagination.items])
    tone = {'critical': 'badge-bad', 'warning': 'badge-warn',
            'info': 'badge-info'}
    rows = [
        f'<tr><td><a href="/{secret_path}/users/{a.user_id}">'
        f'{e(owners.get(a.user_id, a.user_id))}</a></td>'
        f'<td>{e(a.alert_type)}</td><td>{e(a.title)}</td>'
        f'<td>{e(a.device_name)}</td><td class="mono">{e(a.ip_address)}</td>'
        f'<td><span class="badge {tone.get(a.severity, "badge-off")}">'
        f'{e(a.severity)}</span></td>'
        f'<td class="mono">{_dt(a.created_at)}</td></tr>'
        for a in pagination.items]
    filters = filter_bar(secret_path, 'security', [
        ('alert_type', 'نوع رویداد', 'select', [
            ('', 'همه'), ('new_device_login', 'ورود دستگاه جدید'),
            ('login_code_requested', 'درخواست کد ورود'),
            ('device_terminated', 'حذف دستگاه'),
            ('two_factor_enabled', 'فعال‌سازی دومرحله‌ای'),
            ('two_factor_disabled', 'غیرفعال‌سازی دومرحله‌ای'),
            ('primary_device_changed', 'تغییر دستگاه اصلی')]),
        ('severity', 'شدت', 'select', [
            ('', 'همه'), ('critical', 'بحرانی'), ('warning', 'هشدار'),
            ('info', 'اطلاع')]),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)
    body = (filters + '<div class="card"><h2>رویدادهای امنیتی حساب‌ها</h2>' +
            table(['کاربر', 'نوع', 'عنوان', 'دستگاه', 'IP', 'شدت', 'زمان'],
                  rows, 'رویدادی ثبت نشده است') + '</div>' +
            pager(secret_path, 'security', page_no, pages, values))
    return page(secret_path, 'امنیت', body, 'security', _take_flash())


@admin_web_bp.route('/<path:secret_path>/audit')
@admin_required
def admin_audit(secret_path):
    values = _args('q', 'action', 'entity_type', 'actor_id', 'ip', 'from', 'to')
    query = AuditLog.query
    if values['action']:
        query = query.filter(AuditLog.action == values['action'])
    if values['entity_type']:
        query = query.filter(AuditLog.entity_type == values['entity_type'])
    if values['actor_id']:
        query = query.filter(AuditLog.actor_id == values['actor_id'])
    if values['ip']:
        query = query.filter(AuditLog.ip_address.ilike(f"%{values['ip']}%"))
    if values['q']:
        like = f"%{values['q']}%"
        query = query.filter(or_(AuditLog.action.ilike(like),
                                 AuditLog.entity_id.ilike(like),
                                 AuditLog.new_value.ilike(like)))
    query = _apply_dates(query, AuditLog.created_at, values)
    pagination, page_no, pages = _paginate(
        query.order_by(AuditLog.created_at.desc()))

    actors = _names([l.actor_id for l in pagination.items])
    # The dropdown is built from what is actually in the log, so it can never
    # drift out of date as new actions are added.
    known_actions = [row[0] for row in db.session.query(
        AuditLog.action).group_by(AuditLog.action).order_by(
        AuditLog.action).all()]
    known_entities = [row[0] for row in db.session.query(
        AuditLog.entity_type).distinct().all() if row[0]]

    rows = [
        f'<tr><td>{e(l.action)}</td>'
        f'<td>{e(actors.get(l.actor_id, l.actor_id))}</td>'
        f'<td>{e(l.entity_type)}</td>'
        f'<td class="mono">{e((l.entity_id or "")[:14])}</td>'
        f'<td class="mono">{e(l.ip_address)}</td>'
        f'<td>{e(l.new_value)}</td>'
        f'<td class="mono">{_dt(l.created_at, "%Y-%m-%d %H:%M:%S")}</td></tr>'
        for l in pagination.items]

    filters = filter_bar(secret_path, 'audit', [
        ('q', 'جستجو', 'text', None),
        ('action', 'عملیات', 'select',
         [('', 'همه')] + [(a, a) for a in known_actions]),
        ('entity_type', 'نوع موجودیت', 'select',
         [('', 'همه')] + [(x, x) for x in sorted(known_entities)]),
        ('actor_id', 'شناسه عامل', 'text', None),
        ('ip', 'IP', 'text', None),
        ('from', 'از تاریخ', 'date', None),
        ('to', 'تا تاریخ', 'date', None),
    ], values)
    body = (filters +
            f'<div class="card"><h2>لاگ سیستم <span class="stat-label">'
            f'{pagination.total} رکورد</span></h2>' +
            table(['عملیات', 'عامل', 'نوع', 'شناسه', 'IP', 'مقدار', 'زمان'],
                  rows) + '</div>' +
            pager(secret_path, 'audit', page_no, pages, values))
    return page(secret_path, 'لاگ سیستم', body, 'audit', _take_flash())


# --------------------------------------------------------------------------
# settings: upload limits & storage policy
# --------------------------------------------------------------------------
@admin_web_bp.route('/<path:secret_path>/settings')
@admin_required
def admin_settings(secret_path):
    from app.services import app_settings
    settings = app_settings.get_upload_settings()
    auth_methods = app_settings.get_auth_methods()
    csrf = _csrf_token()
    global_cap_mb = (current_app.config.get('MAX_CONTENT_LENGTH') or 0) // (
        1024 * 1024)
    total_size = db.session.query(
        func.coalesce(func.sum(MediaFile.file_size), 0)).filter(
        MediaFile.is_deleted.is_(False)).scalar() or 0
    by_type = db.session.query(
        MediaFile.media_type, func.count(MediaFile.id),
        func.coalesce(func.sum(MediaFile.file_size), 0),
    ).filter(MediaFile.is_deleted.is_(False)).group_by(
        MediaFile.media_type).all()
    type_rows = [
        f'<tr><td>{e(app_settings.CATEGORY_LABELS.get(kind, kind))}</td>'
        f'<td>{count}</td><td>{_human_bytes(size)}</td></tr>'
        for kind, count, size in by_type]

    rows = []
    for category in app_settings.CATEGORIES:
        limit = settings['limits_mb'].get(category)
        limit_text = '' if not limit else (
            str(int(limit)) if float(limit).is_integer() else str(limit))
        checked = ' checked' if settings['enabled'].get(category, True) else ''
        rows.append(
            f'<tr><td>{e(app_settings.CATEGORY_LABELS[category])}</td>'
            f'<td><input type="number" name="limit_{category}" min="0" '
            f'max="10240" step="any" value="{e(limit_text)}" '
            f'style="width:110px;background:#0b1220;border:1px solid '
            f'var(--line);color:var(--text);border-radius:8px;padding:7px">'
            f' <span class="stat-label">مگابایت (۰ = بدون محدودیت)</span></td>'
            f'<td><input type="checkbox" name="enabled_{category}"'
            f'{checked}> مجاز</td></tr>')

    overrides = app_settings.list_user_limits()
    names = _names([item['user_id'] for item in overrides])
    override_rows = []
    for item in overrides:
        clear = action_form(
            secret_path, 'settings/user-limit', 'حذف سقف کاربر', csrf,
            cls='btn btn-sm btn-ghost',
            hidden={'user_id': item['user_id'], 'max_mb': ''})
        override_rows.append(
            f'<tr><td><a href="/{secret_path}/users/{item["user_id"]}">'
            f'{e(names.get(item["user_id"], item["user_id"]))}</a></td>'
            f'<td>{e(app_settings.format_mb(int(item["max_mb"] * 1024 * 1024)))}'
            f' مگابایت</td><td>{clear}</td></tr>')

    registration_sms = ' selected' if auth_methods['registration_method'] == 'sms' else ''
    registration_totp = ' selected' if auth_methods['registration_method'] == 'totp' else ''
    login_sms = ' selected' if auth_methods['login_priority'] == 'sms' else ''
    login_totp = ' selected' if auth_methods['login_priority'] == 'totp' else ''
    auth_policy_form = f"""
<div class="card"><h2>روش ثبت‌نام و ورود</h2>
<p class="stat-label" style="margin-bottom:12px">ثبت‌نام پیامکی، مالکیت شماره را
تأیید می‌کند. ثبت‌نام با Google Authenticator کد پیامک نمی‌فرستد و شمارهٔ واردشده
تأییدشده محسوب نمی‌شود؛ کاربر برنامه را روی دستگاه خودش ثبت و کد یک‌بارمصرف را
تأیید می‌کند. در اولویت ورود با Authenticator، حساب‌های فاقد Authenticator همچنان
می‌توانند از مسیر پیامک استفاده کنند؛ شمارهٔ تأییدشده برای حساب‌های دارای
Authenticator نیز مسیر بازیابی پیامکی است. کاربران ثبت‌نام‌شده با Authenticator
می‌توانند پس از ورود، شمارهٔ خود را برای بازیابی تأیید کنند. پنل مدیریت هرگز کدها
یا رازهای کاربران را نمایش نمی‌دهد.</p>
<form method="post" action="/{secret_path}/settings/auth-methods">
<input type="hidden" name="csrf_token" value="{csrf}">
<div class="grid2">
<label>ثبت‌نام
<select name="registration_method" style="display:block;width:100%;margin-top:6px">
<option value="sms"{registration_sms}>پیامک (SMS)</option>
<option value="totp"{registration_totp}>Google Authenticator</option>
</select></label>
<label>اولویت ورود
<select name="login_priority" style="display:block;width:100%;margin-top:6px">
<option value="sms"{login_sms}>پیامک (SMS)</option>
<option value="totp"{login_totp}>Google Authenticator</option>
</select></label>
</div><div style="margin-top:14px"><button class="btn" type="submit">ذخیره روش‌ها</button></div>
</form></div>
"""

    body = f"""
{auth_policy_form}
<div class="stats">
{stat(_human_bytes(total_size), 'حجم کل فایل‌ها')}
{stat(f'{global_cap_mb} MB', 'سقف کلی سرور (env)')}
</div>
<div class="card"><h2>محدودیت حجم آپلود</h2>
<p class="stat-label" style="margin-bottom:12px">این محدودیت‌ها فوراً و بدون
نیاز به راه‌اندازی مجدد اعمال می‌شوند. هر فایلی که از سقف دسته‌اش بزرگ‌تر
باشد — چه هنگام آپلود و چه هنگام ارسال پیام — رد می‌شود. غیرفعال کردن یک
دسته، ارسال آن نوع فایل را به‌طور کامل می‌بندد.</p>
<form method="post" action="/{secret_path}/settings">
<input type="hidden" name="csrf_token" value="{csrf}">
<table><thead><tr><th>نوع فایل</th><th>حداکثر حجم</th><th>آپلود</th></tr>
</thead><tbody>{''.join(rows)}</tbody></table>
<div style="margin-top:14px"><button class="btn" type="submit">ذخیره تنظیمات</button></div>
</form></div>
<div class="grid2">
<div class="card"><h2>حجم بر اساس نوع فایل</h2>
{table(['نوع', 'تعداد', 'حجم'], type_rows)}</div>
<div class="card"><h2>سقف اختصاصی کاربران</h2>
<p class="stat-label" style="margin-bottom:10px">سقف اختصاصی از صفحهٔ جزئیات
هر کاربر تنظیم می‌شود و هرجا سخت‌گیرانه‌تر از سقف دسته باشد، همان اعمال
می‌شود.</p>
{table(['کاربر', 'سقف', ''], override_rows, 'سقف اختصاصی ثبت نشده است')}</div>
</div>
"""
    return page(secret_path, 'تنظیمات', body, 'settings', _take_flash())


@admin_web_bp.route('/<path:secret_path>/settings', methods=['POST'])
@admin_required
def admin_settings_save(secret_path):
    from app.services import app_settings
    limits = {}
    enabled = {}
    for category in app_settings.CATEGORIES:
        raw = (request.form.get(f'limit_{category}') or '').strip()
        if raw == '':
            limits[category] = 0
        else:
            try:
                limits[category] = float(raw)
            except ValueError:
                return _flash_redirect(
                    secret_path, 'settings', 'err',
                    f'مقدار حجم «{app_settings.CATEGORY_LABELS[category]}» نامعتبر است')
        enabled[category] = request.form.get(f'enabled_{category}') == 'on'
    try:
        app_settings.save_upload_settings(limits_mb=limits, enabled=enabled)
    except ValueError as error:
        return _flash_redirect(secret_path, 'settings', 'err', str(error))
    _audit('admin_update_upload_settings', 'settings', 'uploads',
           new_value=str(limits))
    db.session.commit()
    return _flash_redirect(secret_path, 'settings', 'ok',
                           'تنظیمات آپلود ذخیره شد')


@admin_web_bp.route('/<path:secret_path>/settings/auth-methods', methods=['POST'])
@admin_required
def admin_auth_methods_save(secret_path):
    from app.services import app_settings
    try:
        policy = app_settings.save_auth_methods(
            registration_method=request.form.get('registration_method', ''),
            login_priority=request.form.get('login_priority', ''),
        )
    except ValueError as error:
        return _flash_redirect(secret_path, 'settings', 'err', str(error))
    _audit('admin_update_auth_methods', 'settings', 'authentication',
           new_value=str(policy))
    db.session.commit()
    return _flash_redirect(secret_path, 'settings', 'ok',
                           'روش ثبت‌نام و ورود ذخیره شد')


@admin_web_bp.route('/<path:secret_path>/settings/user-limit', methods=['POST'])
@admin_required
def admin_user_upload_limit(secret_path):
    from app.services import app_settings
    user_id = (request.form.get('user_id') or '').strip()
    user = db.session.get(User, user_id) if user_id else None
    if not user:
        return _flash_redirect(secret_path, 'settings', 'err',
                               'کاربر یافت نشد')
    raw = (request.form.get('max_mb') or '').strip()
    try:
        if raw == '':
            app_settings.set_user_limit_mb(user_id, None)
            message = 'سقف اختصاصی کاربر حذف شد'
        else:
            cap = app_settings.set_user_limit_mb(user_id, float(raw))
            message = (f'سقف اختصاصی کاربر روی '
                       f'{app_settings.format_mb(int(cap * 1024 * 1024))} '
                       f'مگابایت تنظیم شد')
    except (TypeError, ValueError):
        return _flash_redirect(secret_path, f'users/{user_id}', 'err',
                               'مقدار سقف حجم نامعتبر است')
    _audit('admin_set_user_upload_limit', 'user', user_id, new_value=raw)
    db.session.commit()
    back = (request.form.get('back') or '').strip()
    target = f'users/{user_id}' if back == 'user' else 'settings'
    return _flash_redirect(secret_path, target, 'ok', message)
