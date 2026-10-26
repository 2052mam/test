"""Comprehensive admin API (Point 5).

Everything the admin panel needs, with consistent shapes and real filtering:

* ``/dashboard``   – counters, growth series, live health, top chats, backlog
* ``/users``       – rich filters (status, role, activity, dates) + detail view,
                     ban/unban, limit/unlimit, promote/demote, force-logout
* ``/chats``       – filters by type/visibility/state + detail with members,
                     suspend/close/sponsor actions
* ``/messages``    – filters by chat, sender, type, text, date range, deleted
* ``/media``       – filters by type, uploader, size, date range
* ``/audit``       – filters by action, actor, entity, IP, date range +
                     ``/audit/actions`` for the filter dropdown
* ``/support``     – the support inbox: tickets *and* the user↔support chat
                     threads, with reply-in-thread
* ``/reports``     – moderation queue with status filters
* ``/devices``     – device/session oversight including primary-device info
* ``/security``    – recent security alerts across the whole install

Every list endpoint shares the same pagination contract
(``page``/``per_page``/``total``/``pages``) and the same sort contract
(``sort``/``order``), so the UI can treat them uniformly.
"""
from datetime import datetime, timedelta

from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required
from sqlalchemy import func, or_

from app import db
from app.models.audit import AuditLog
from app.models.chat import Chat, ChatMember
from app.models.media import MediaFile
from app.models.message import Message
from app.models.report import Report
from app.models.support import TICKET_STATUSES, SecurityAlert, SupportTicket
from app.models.user import User, UserDevice, UserSession
from app.services.timestamps import utc_iso

admin_api_bp = Blueprint('admin_api', __name__)

MAX_PER_PAGE = 200
FORBIDDEN = ({'error': 'دسترسی ادمین ندارید'}, 403)


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def require_admin():
    user_id = get_jwt_identity()
    user = User.query.filter_by(id=user_id, is_deleted=False).first()
    if not user or not user.is_admin:
        return None
    return user


def _deny():
    return jsonify(FORBIDDEN[0]), FORBIDDEN[1]


def _client_ip():
    forwarded = request.headers.get('X-Forwarded-For')
    return (forwarded.split(',')[0].strip() if forwarded
            else request.remote_addr)


def _page_args():
    try:
        page = max(1, int(request.args.get('page', 1)))
    except (TypeError, ValueError):
        page = 1
    try:
        per_page = min(max(1, int(request.args.get('per_page', 50))),
                       MAX_PER_PAGE)
    except (TypeError, ValueError):
        per_page = 50
    return page, per_page


def _parse_date(value):
    """Accept 'YYYY-MM-DD' and full ISO timestamps; None when absent/invalid."""
    raw = (value or '').strip()
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace('Z', '+00:00'))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is not None:
        import datetime as _dt
        parsed = parsed.astimezone(_dt.timezone.utc).replace(tzinfo=None)
    return parsed


def _date_range_filter(query, column):
    """Apply ?from=&to= to any timestamp column. ``to`` is inclusive by day."""
    start = _parse_date(request.args.get('from'))
    end = _parse_date(request.args.get('to'))
    if start:
        query = query.filter(column >= start)
    if end:
        # A bare date means "up to the end of that day", which is what an
        # admin typing 2026-09-18 actually expects.
        if end.hour == 0 and end.minute == 0 and end.second == 0:
            end = end + timedelta(days=1)
        query = query.filter(column < end)
    return query


def _apply_sort(query, model, allowed, default):
    field = request.args.get('sort') or default
    if field not in allowed:
        field = default
    column = getattr(model, field)
    order = (request.args.get('order') or 'desc').lower()
    return query.order_by(column.asc() if order == 'asc' else column.desc())


def _paginate(query, page, per_page):
    pagination = query.paginate(page=page, per_page=per_page, error_out=False)
    return pagination, {
        'total': pagination.total,
        'page': page,
        'per_page': per_page,
        'pages': pagination.pages,
        'has_next': pagination.has_next,
        'has_prev': pagination.has_prev,
    }


def _log(admin, action, entity_type, entity_id, **kw):
    db.session.add(AuditLog(
        actor_id=admin.id, action=action, entity_type=entity_type,
        entity_id=entity_id, ip_address=_client_ip(),
        user_agent=request.headers.get('User-Agent'),
        old_value=kw.get('old_value'), new_value=kw.get('new_value'),
    ))


def _bool_arg(name):
    """Tri-state query flag: True / False / None (no filter)."""
    raw = request.args.get(name)
    if raw is None or raw == '':
        return None
    return raw.lower() in ('1', 'true', 'yes')


def _display_names(user_ids):
    """Bulk id->name map so lists never show a bare UUID."""
    ids = {i for i in user_ids if i}
    if not ids:
        return {}
    rows = User.query.filter(User.id.in_(ids)).all()
    return {u.id: (u.display_name or u.username or u.id[:8]) for u in rows}


# --------------------------------------------------------------------------
# dashboard
# --------------------------------------------------------------------------
@admin_api_bp.route('/dashboard', methods=['GET'])
@jwt_required()
def dashboard():
    admin = require_admin()
    if not admin:
        return _deny()

    now = datetime.utcnow()
    day_ago = now - timedelta(days=1)
    week_ago = now - timedelta(days=7)
    online_cutoff = now - timedelta(seconds=60)

    totals = {
        'users': User.query.filter_by(is_deleted=False).count(),
        'chats': Chat.query.filter_by(is_deleted=False).count(),
        'messages': Message.query.filter_by(is_deleted_for_all=False).count(),
        'media': MediaFile.query.filter_by(is_deleted=False).count(),
        'devices': UserDevice.query.filter_by(is_deleted=False).count(),
        'sessions': UserSession.query.filter_by(is_active=True).count(),
    }
    live = {
        # Mirrors User.to_dict: a killed app cannot send a final offline ping,
        # so an expired heartbeat must not be counted as online.
        'online': User.query.filter(
            User.is_deleted.is_(False),
            User.is_online.is_(True),
            User.last_seen >= online_cutoff,
        ).count(),
        'new_users_24h': User.query.filter(
            User.is_deleted.is_(False), User.created_at >= day_ago).count(),
        'new_users_7d': User.query.filter(
            User.is_deleted.is_(False), User.created_at >= week_ago).count(),
        'messages_24h': Message.query.filter(
            Message.created_at >= day_ago).count(),
        'messages_7d': Message.query.filter(
            Message.created_at >= week_ago).count(),
        'logins_24h': AuditLog.query.filter(
            AuditLog.action.in_(['user_login', 'phone_login',
                                 'user_register_login']),
            AuditLog.created_at >= day_ago).count(),
    }
    moderation = {
        'pending_reports': Report.query.filter_by(status='pending').count(),
        'open_tickets': SupportTicket.query.filter(
            SupportTicket.status.in_(['open', 'in_progress'])).count(),
        'banned_users': User.query.filter_by(
            is_deleted=False, is_active=False).count(),
        'limited_users': User.query.filter_by(
            is_deleted=False, is_limited=True).count(),
        'suspended_chats': Chat.query.filter_by(
            is_deleted=False, is_suspended=True).count(),
    }
    storage_bytes = db.session.query(
        func.coalesce(func.sum(MediaFile.file_size), 0),
    ).filter(MediaFile.is_deleted.is_(False)).scalar() or 0

    # 14-day activity series for the dashboard chart.
    series = []
    for offset in range(13, -1, -1):
        day_start = (now - timedelta(days=offset)).replace(
            hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)
        series.append({
            'date': day_start.strftime('%Y-%m-%d'),
            'messages': Message.query.filter(
                Message.created_at >= day_start,
                Message.created_at < day_end).count(),
            'users': User.query.filter(
                User.created_at >= day_start,
                User.created_at < day_end,
                User.is_deleted.is_(False)).count(),
        })

    chat_types = dict(
        db.session.query(Chat.chat_type, func.count(Chat.id))
        .filter(Chat.is_deleted.is_(False)).group_by(Chat.chat_type).all()
    )
    message_types = dict(
        db.session.query(Message.message_type, func.count(Message.id))
        .filter(Message.created_at >= week_ago)
        .group_by(Message.message_type).all()
    )

    top_rows = db.session.query(
        Chat.id, Chat.title, Chat.chat_type, func.count(Message.id).label('n'),
    ).join(Message, Message.chat_id == Chat.id).filter(
        Chat.is_deleted.is_(False), Message.created_at >= week_ago,
    ).group_by(Chat.id, Chat.title, Chat.chat_type).order_by(
        func.count(Message.id).desc()).limit(10).all()

    return jsonify({
        # Flat keys kept for the original/legacy dashboard consumers.
        'users': totals['users'],
        'chats': totals['chats'],
        'messages': totals['messages'],
        'online': live['online'],
        'media': totals['media'],
        'devices': totals['devices'],
        # Structured payload for the new panel.
        'totals': totals,
        'live': live,
        'moderation': moderation,
        'storage': {
            'bytes': int(storage_bytes),
            'megabytes': round(int(storage_bytes) / (1024 * 1024), 2),
        },
        'series': series,
        'chat_types': chat_types,
        'message_types': message_types,
        'top_chats': [{
            'id': r.id, 'title': r.title or '—',
            'chat_type': r.chat_type, 'messages': int(r.n),
        } for r in top_rows],
        'server_time': utc_iso(now),
    }), 200


# --------------------------------------------------------------------------
# users
# --------------------------------------------------------------------------
@admin_api_bp.route('/users', methods=['GET'])
@jwt_required()
def list_users():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()
    q = (request.args.get('q') or '').strip()

    query = User.query
    if not _bool_arg('include_deleted'):
        query = query.filter(User.is_deleted.is_(False))
    if q:
        like = f'%{q}%'
        query = query.filter(or_(
            User.username.ilike(like),
            User.email.ilike(like),
            User.display_name.ilike(like),
            User.mobile_number.ilike(like),
            User.id == q,
        ))

    status = (request.args.get('status') or '').strip()
    if status == 'active':
        query = query.filter(User.is_active.is_(True),
                             User.is_limited.is_(False))
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

    role = (request.args.get('role') or '').strip()
    if role == 'admin':
        query = query.filter(User.is_admin.is_(True))
    elif role == 'support':
        query = query.filter(User.is_support.is_(True))
    elif role == 'user':
        query = query.filter(User.is_admin.is_(False),
                             User.is_support.is_(False))

    two_fa = _bool_arg('two_factor')
    if two_fa is not None:
        query = query.filter(User.is_2fa_enabled.is_(two_fa))

    query = _date_range_filter(query, User.created_at)
    query = _apply_sort(
        query, User,
        {'created_at', 'last_seen', 'display_name', 'username'},
        'created_at')

    pagination, meta = _paginate(query, page, per_page)
    users = []
    for u in pagination.items:
        data = u.to_dict(include_private=True)
        data.update({
            'is_active': bool(u.is_active),
            'is_limited': bool(u.is_limited),
            'limited_until': utc_iso(u.limited_until) if u.limited_until else None,
            'limited_reason': u.limited_reason,
            'is_support': bool(u.is_support),
            'is_deleted': bool(u.is_deleted),
            'devices': UserDevice.query.filter_by(
                user_id=u.id, is_deleted=False).count(),
        })
        users.append(data)
    return jsonify({'users': users, **meta}), 200


@admin_api_bp.route('/users/<user_id>', methods=['GET'])
@jwt_required()
def user_detail(user_id):
    """Everything about one account on a single screen."""
    admin = require_admin()
    if not admin:
        return _deny()
    user = db.session.get(User, user_id)
    if not user:
        return jsonify({'error': 'کاربر یافت نشد'}), 404

    devices = UserDevice.query.filter_by(
        user_id=user_id, is_deleted=False,
    ).order_by(UserDevice.last_active.desc()).all()
    memberships = db.session.query(Chat, ChatMember).join(
        ChatMember, ChatMember.chat_id == Chat.id,
    ).filter(
        ChatMember.user_id == user_id,
        ChatMember.is_deleted.is_(False),
        Chat.is_deleted.is_(False),
    ).limit(100).all()
    recent_messages = Message.query.filter_by(sender_id=user_id).order_by(
        Message.created_at.desc()).limit(20).all()
    recent_audit = AuditLog.query.filter_by(actor_id=user_id).order_by(
        AuditLog.created_at.desc()).limit(20).all()

    data = user.to_dict(include_private=True)
    data.update({
        'is_active': bool(user.is_active),
        'is_limited': bool(user.is_limited),
        'limited_until': utc_iso(user.limited_until) if user.limited_until else None,
        'limited_reason': user.limited_reason,
        'is_support': bool(user.is_support),
        'is_deleted': bool(user.is_deleted),
    })
    return jsonify({
        'user': data,
        'stats': {
            'messages': Message.query.filter_by(sender_id=user_id).count(),
            'chats': len(memberships),
            'media': MediaFile.query.filter_by(
                uploader_id=user_id, is_deleted=False).count(),
            'reports_against': Report.query.filter_by(
                target_user_id=user_id).count(),
            'reports_made': Report.query.filter_by(
                reporter_id=user_id).count(),
            'tickets': SupportTicket.query.filter_by(user_id=user_id).count(),
        },
        'devices': [{
            'id': d.id,
            'device_name': d.device_name,
            'device_model': d.device_model,
            'os_version': d.os_version,
            'app_version': d.app_version,
            'is_primary': bool(getattr(d, 'is_primary', False)),
            'is_active': bool(d.is_active),
            'last_active': utc_iso(d.last_active),
            'created_at': utc_iso(d.created_at),
        } for d in devices],
        'chats': [{
            'id': chat.id, 'title': chat.title, 'chat_type': chat.chat_type,
            'role': member.role,
        } for chat, member in memberships],
        'recent_messages': [{
            'id': m.id, 'chat_id': m.chat_id, 'message_type': m.message_type,
            'content': (m.content or '')[:200],
            'is_deleted': bool(m.is_deleted_for_all or m.is_deleted),
            'created_at': utc_iso(m.created_at),
        } for m in recent_messages],
        'recent_audit': [{
            'id': a.id, 'action': a.action, 'entity_type': a.entity_type,
            'ip_address': a.ip_address, 'created_at': utc_iso(a.created_at),
        } for a in recent_audit],
    }), 200


def _load_user_or_404(user_id):
    user = db.session.get(User, user_id)
    if not user:
        return None, (jsonify({'error': 'کاربر یافت نشد'}), 404)
    return user, None


@admin_api_bp.route('/users/<user_id>/ban', methods=['POST'])
@jwt_required()
def ban_user(user_id):
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    if user.id == admin.id:
        return jsonify({'error': 'نمی‌توانید حساب خودتان را غیرفعال کنید'}), 400
    data = request.get_json(silent=True) or {}
    user.is_active = False
    # Banning must also cut live sessions, otherwise the account keeps working
    # until its access token happens to expire.
    UserSession.query.filter_by(user_id=user.id, is_active=True).update(
        {'is_active': False}, synchronize_session=False)
    UserDevice.query.filter_by(user_id=user.id, is_deleted=False).update(
        {'is_active': False}, synchronize_session=False)
    _log(admin, 'admin_ban_user', 'user', user_id,
         new_value=(data.get('reason') or '')[:500] or None)
    db.session.commit()
    return jsonify({'ok': True, 'message': 'کاربر غیرفعال شد',
                    'is_active': False}), 200


@admin_api_bp.route('/users/<user_id>/unban', methods=['POST'])
@jwt_required()
def unban_user(user_id):
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    user.is_active = True
    UserDevice.query.filter_by(user_id=user.id, is_deleted=False).update(
        {'is_active': True}, synchronize_session=False)
    _log(admin, 'admin_unban_user', 'user', user_id)
    db.session.commit()
    return jsonify({'ok': True, 'message': 'کاربر فعال شد',
                    'is_active': True}), 200


@admin_api_bp.route('/users/<user_id>/limit', methods=['POST'])
@jwt_required()
def limit_user(user_id):
    """Telegram-style limited account: can reply, cannot start new things."""
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    data = request.get_json(silent=True) or {}
    try:
        days = max(1, min(int(data.get('days', 7)), 365))
    except (TypeError, ValueError):
        return jsonify({'error': 'days نامعتبر است'}), 400
    user.is_limited = True
    user.limited_until = datetime.utcnow() + timedelta(days=days)
    user.limited_reason = (data.get('reason') or 'نقض قوانین')[:500]
    user.limited_by = admin.id
    _log(admin, 'admin_limit_user', 'user', user_id,
         new_value=f'{days}d: {user.limited_reason}')
    db.session.commit()
    return jsonify({
        'ok': True, 'is_limited': True,
        'limited_until': utc_iso(user.limited_until),
    }), 200


@admin_api_bp.route('/users/<user_id>/unlimit', methods=['POST'])
@jwt_required()
def unlimit_user(user_id):
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    user.is_limited = False
    user.limited_until = None
    user.limited_reason = None
    user.limited_by = None
    _log(admin, 'admin_unlimit_user', 'user', user_id)
    db.session.commit()
    return jsonify({'ok': True, 'is_limited': False}), 200


@admin_api_bp.route('/users/<user_id>/role', methods=['POST'])
@jwt_required()
def set_user_role(user_id):
    """Grant/revoke admin and support roles. Body: {is_admin, is_support}."""
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    data = request.get_json(silent=True) or {}
    before = f'admin={bool(user.is_admin)},support={bool(user.is_support)}'
    if 'is_admin' in data:
        if type(data['is_admin']) is not bool:
            return jsonify({'error': 'is_admin must be boolean'}), 400
        if user.id == admin.id and not data['is_admin']:
            # Losing your own admin rights mid-session locks you out of the
            # panel with no way back in.
            return jsonify({
                'error': 'نمی‌توانید دسترسی ادمین خودتان را بردارید',
            }), 400
        user.is_admin = data['is_admin']
    if 'is_support' in data:
        if type(data['is_support']) is not bool:
            return jsonify({'error': 'is_support must be boolean'}), 400
        user.is_support = data['is_support']
    _log(admin, 'admin_set_role', 'user', user_id, old_value=before,
         new_value=f'admin={bool(user.is_admin)},support={bool(user.is_support)}')
    db.session.commit()
    return jsonify({
        'ok': True, 'is_admin': bool(user.is_admin),
        'is_support': bool(user.is_support),
    }), 200


@admin_api_bp.route('/users/<user_id>/logout-all', methods=['POST'])
@jwt_required()
def force_logout(user_id):
    """Terminate every session of an account (compromise response)."""
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    sessions = UserSession.query.filter_by(
        user_id=user.id, is_active=True).count()
    UserSession.query.filter_by(user_id=user.id, is_active=True).update(
        {'is_active': False}, synchronize_session=False)
    UserDevice.query.filter_by(user_id=user.id, is_deleted=False).update(
        {'is_active': False, 'push_token': None, 'push_platform': None},
        synchronize_session=False)
    _log(admin, 'admin_force_logout', 'user', user_id,
         new_value=str(sessions))
    db.session.commit()
    return jsonify({'ok': True, 'terminated_sessions': sessions}), 200


# --------------------------------------------------------------------------
# chats
# --------------------------------------------------------------------------
@admin_api_bp.route('/chats', methods=['GET'])
@jwt_required()
def list_chats_admin():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = Chat.query
    if not _bool_arg('include_deleted'):
        query = query.filter(Chat.is_deleted.is_(False))
    q = (request.args.get('q') or '').strip()
    if q:
        like = f'%{q}%'
        query = query.filter(or_(
            Chat.title.ilike(like), Chat.username.ilike(like), Chat.id == q))
    chat_type = (request.args.get('chat_type') or '').strip()
    if chat_type:
        query = query.filter(Chat.chat_type == chat_type)
    for arg, column in (('is_public', Chat.is_public),
                        ('is_sponsored', Chat.is_sponsored),
                        ('is_suspended', Chat.is_suspended),
                        ('is_closed', Chat.is_closed)):
        value = _bool_arg(arg)
        if value is not None:
            query = query.filter(column.is_(value))

    query = _date_range_filter(query, Chat.created_at)
    query = _apply_sort(query, Chat,
                        {'created_at', 'updated_at', 'title'}, 'created_at')
    pagination, meta = _paginate(query, page, per_page)

    chat_ids = [c.id for c in pagination.items]
    member_counts = dict(
        db.session.query(ChatMember.chat_id, func.count(ChatMember.id))
        .filter(ChatMember.chat_id.in_(chat_ids),
                ChatMember.is_deleted.is_(False))
        .group_by(ChatMember.chat_id).all()
    ) if chat_ids else {}
    message_counts = dict(
        db.session.query(Message.chat_id, func.count(Message.id))
        .filter(Message.chat_id.in_(chat_ids))
        .group_by(Message.chat_id).all()
    ) if chat_ids else {}
    owners = _display_names([c.created_by for c in pagination.items])

    chats = [{
        'id': c.id, 'chat_type': c.chat_type, 'title': c.title,
        'username': c.username, 'created_by': c.created_by,
        'created_by_name': owners.get(c.created_by),
        'is_public': bool(c.is_public),
        'is_deleted': bool(c.is_deleted),
        'is_sponsored': bool(getattr(c, 'is_sponsored', False)),
        'is_suspended': bool(getattr(c, 'is_suspended', False)),
        'is_closed': bool(getattr(c, 'is_closed', False)),
        'members': int(member_counts.get(c.id, 0)),
        'messages': int(message_counts.get(c.id, 0)),
        'sponsored_at': utc_iso(c.sponsored_at) if getattr(c, 'sponsored_at', None) else None,
        'created_at': utc_iso(c.created_at),
        'updated_at': utc_iso(c.updated_at),
    } for c in pagination.items]
    return jsonify({'chats': chats, **meta}), 200


@admin_api_bp.route('/chats/<chat_id>', methods=['GET'])
@jwt_required()
def chat_detail(chat_id):
    admin = require_admin()
    if not admin:
        return _deny()
    chat = db.session.get(Chat, chat_id)
    if not chat:
        return jsonify({'error': 'چت یافت نشد'}), 404

    members = db.session.query(ChatMember, User).join(
        User, User.id == ChatMember.user_id,
    ).filter(
        ChatMember.chat_id == chat_id, ChatMember.is_deleted.is_(False),
    ).limit(200).all()
    recent = Message.query.filter_by(chat_id=chat_id).order_by(
        Message.created_at.desc()).limit(30).all()
    senders = _display_names([m.sender_id for m in recent])

    return jsonify({
        'chat': {
            'id': chat.id, 'chat_type': chat.chat_type, 'title': chat.title,
            'username': chat.username, 'description': chat.description,
            'avatar_url': chat.avatar_url,
            'is_public': bool(chat.is_public),
            'is_deleted': bool(chat.is_deleted),
            'is_sponsored': bool(getattr(chat, 'is_sponsored', False)),
            'is_suspended': bool(getattr(chat, 'is_suspended', False)),
            'suspension_reason': getattr(chat, 'suspension_reason', None),
            'is_closed': bool(getattr(chat, 'is_closed', False)),
            'closed_reason': getattr(chat, 'closed_reason', None),
            'slow_mode_delay': chat.slow_mode_delay,
            'created_by': chat.created_by,
            'created_at': utc_iso(chat.created_at),
            'updated_at': utc_iso(chat.updated_at),
        },
        'stats': {
            'members': len(members),
            'messages': Message.query.filter_by(chat_id=chat_id).count(),
            'reports': Report.query.filter_by(target_chat_id=chat_id).count(),
        },
        'members': [{
            'user_id': u.id, 'display_name': u.display_name,
            'username': u.username, 'role': m.role,
            'is_active': bool(u.is_active),
            'joined_at': utc_iso(m.joined_at),
        } for m, u in members],
        'recent_messages': [{
            'id': m.id, 'sender_id': m.sender_id,
            'sender_name': senders.get(m.sender_id),
            'message_type': m.message_type,
            'content': (m.content or '')[:300],
            'is_deleted': bool(m.is_deleted_for_all or m.is_deleted),
            'created_at': utc_iso(m.created_at),
        } for m in recent],
    }), 200


@admin_api_bp.route('/chats/<chat_id>/suspend', methods=['POST'])
@jwt_required()
def suspend_chat(chat_id):
    """Suspend / unsuspend a group or channel. Body: {is_suspended, reason}."""
    admin = require_admin()
    if not admin:
        return _deny()
    chat = Chat.query.filter_by(id=chat_id, is_deleted=False).first()
    if not chat:
        return jsonify({'error': 'چت یافت نشد'}), 404
    data = request.get_json(silent=True) or {}
    value = data.get('is_suspended', True)
    if type(value) is not bool:
        return jsonify({'error': 'is_suspended must be boolean'}), 400
    chat.is_suspended = value
    chat.suspension_reason = (data.get('reason') or '')[:500] if value else None
    chat.suspended_at = datetime.utcnow() if value else None
    chat.suspended_by = admin.id if value else None
    _log(admin, 'admin_suspend_chat' if value else 'admin_unsuspend_chat',
         'chat', chat_id, new_value=chat.suspension_reason)
    db.session.commit()
    return jsonify({'ok': True, 'is_suspended': bool(chat.is_suspended)}), 200


@admin_api_bp.route('/chats/<chat_id>/sponsor', methods=['POST'])
@jwt_required()
def sponsor_channel(chat_id):
    """Sponsor / unsponsor a channel (general app admin only)."""
    admin = require_admin()
    if not admin:
        return _deny()
    chat = Chat.query.filter_by(id=chat_id, is_deleted=False).first()
    if not chat:
        return jsonify({'error': 'چت یافت نشد'}), 404
    if chat.chat_type != 'channel':
        return jsonify({'error': 'فقط کانال‌ها می‌توانند اسپانسر شوند'}), 400
    data = request.get_json(silent=True) or {}
    value = data.get('is_sponsored', True)
    if type(value) is not bool:
        return jsonify({'error': 'is_sponsored must be boolean'}), 400
    chat.is_sponsored = value
    chat.sponsored_at = datetime.utcnow() if value else None
    chat.sponsored_by = admin.id if value else None
    _log(admin, 'sponsor_channel' if value else 'unsponsor_channel',
         'chat', chat_id)
    db.session.commit()
    return jsonify({'ok': True, 'is_sponsored': chat.is_sponsored}), 200


@admin_api_bp.route('/sponsored', methods=['GET'])
@jwt_required()
def list_sponsored_admin():
    admin = require_admin()
    if not admin:
        return _deny()
    channels = Chat.query.filter_by(
        chat_type='channel', is_deleted=False, is_sponsored=True,
    ).order_by(Chat.sponsored_at.desc()).all()
    return jsonify({'channels': [{
        'id': c.id, 'title': c.title, 'username': c.username,
        'description': c.description, 'avatar_url': c.avatar_url,
        'is_public': bool(c.is_public), 'is_sponsored': True,
        'sponsored_at': utc_iso(c.sponsored_at) if c.sponsored_at else None,
        'sponsored_by': c.sponsored_by,
    } for c in channels]}), 200


# --------------------------------------------------------------------------
# messages & media
# --------------------------------------------------------------------------
@admin_api_bp.route('/messages', methods=['GET'])
@jwt_required()
def list_messages():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = Message.query
    chat_id = request.args.get('chat_id')
    if chat_id:
        query = query.filter(Message.chat_id == chat_id)
    sender_id = request.args.get('sender_id')
    if sender_id:
        query = query.filter(Message.sender_id == sender_id)
    message_type = request.args.get('message_type')
    if message_type:
        query = query.filter(Message.message_type == message_type)
    q = (request.args.get('q') or '').strip()
    if q:
        query = query.filter(Message.content.ilike(f'%{q}%'))
    deleted = _bool_arg('deleted')
    if deleted is True:
        query = query.filter(or_(Message.is_deleted.is_(True),
                                 Message.is_deleted_for_all.is_(True)))
    elif deleted is False:
        query = query.filter(Message.is_deleted.is_(False),
                             Message.is_deleted_for_all.is_(False))
    has_media = _bool_arg('has_media')
    if has_media is True:
        query = query.filter(Message.media_id.isnot(None))
    elif has_media is False:
        query = query.filter(Message.media_id.is_(None))

    query = _date_range_filter(query, Message.created_at)
    query = _apply_sort(query, Message, {'created_at'}, 'created_at')
    pagination, meta = _paginate(query, page, per_page)

    senders = _display_names([m.sender_id for m in pagination.items])
    chat_ids = {m.chat_id for m in pagination.items}
    chat_titles = {
        c.id: (c.title or c.chat_type)
        for c in Chat.query.filter(Chat.id.in_(chat_ids)).all()
    } if chat_ids else {}

    msgs = [{
        'id': m.id, 'chat_id': m.chat_id,
        'chat_title': chat_titles.get(m.chat_id),
        'sender_id': m.sender_id, 'sender_name': senders.get(m.sender_id),
        # Encrypted and secret content is ciphertext we cannot read, and must
        # not be presented as if it were plain text.
        'content': ('🔒 رمزگذاری‌شده' if getattr(m, 'is_encrypted', False)
                    else (m.content or '')),
        'message_type': m.message_type,
        'media_id': m.media_id,
        'is_deleted': bool(m.is_deleted),
        'is_deleted_for_all': bool(m.is_deleted_for_all),
        'is_secure': bool(getattr(m, 'is_secure', False)),
        'created_at': utc_iso(m.created_at),
    } for m in pagination.items]
    return jsonify({'messages': msgs, **meta}), 200


@admin_api_bp.route('/messages/<message_id>', methods=['DELETE'])
@jwt_required()
def admin_delete_message(message_id):
    """Remove a message for everyone (moderation)."""
    admin = require_admin()
    if not admin:
        return _deny()
    message = db.session.get(Message, message_id)
    if not message:
        return jsonify({'error': 'پیام یافت نشد'}), 404
    message.is_deleted = True
    message.is_deleted_for_all = True
    message.deleted_at = datetime.utcnow()
    message.deleted_by = admin.id
    _log(admin, 'admin_delete_message', 'message', message_id)
    db.session.commit()
    return jsonify({'ok': True}), 200


@admin_api_bp.route('/media', methods=['GET'])
@jwt_required()
def list_media():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = MediaFile.query
    if not _bool_arg('include_deleted'):
        query = query.filter(MediaFile.is_deleted.is_(False))
    media_type = request.args.get('media_type')
    if media_type:
        query = query.filter(MediaFile.media_type == media_type)
    uploader_id = request.args.get('uploader_id')
    if uploader_id:
        query = query.filter(MediaFile.uploader_id == uploader_id)
    q = (request.args.get('q') or '').strip()
    if q:
        query = query.filter(MediaFile.original_name.ilike(f'%{q}%'))
    try:
        min_size = request.args.get('min_size')
        if min_size:
            query = query.filter(MediaFile.file_size >= int(min_size))
    except (TypeError, ValueError):
        return jsonify({'error': 'min_size نامعتبر است'}), 400

    query = _date_range_filter(query, MediaFile.created_at)
    query = _apply_sort(query, MediaFile,
                        {'created_at', 'file_size'}, 'created_at')
    pagination, meta = _paginate(query, page, per_page)
    uploaders = _display_names([m.uploader_id for m in pagination.items])
    return jsonify({
        'media': [{
            'id': m.id, 'original_name': m.original_name,
            'media_type': m.media_type, 'mime_type': m.mime_type,
            'file_size': int(m.file_size or 0),
            'uploader_id': m.uploader_id,
            'uploader_name': uploaders.get(m.uploader_id),
            'is_deleted': bool(m.is_deleted),
            'created_at': utc_iso(m.created_at),
        } for m in pagination.items],
        **meta,
    }), 200


# --------------------------------------------------------------------------
# audit log
# --------------------------------------------------------------------------
@admin_api_bp.route('/audit/actions', methods=['GET'])
@jwt_required()
def audit_actions():
    """Distinct action names, so the filter dropdown is never out of date."""
    admin = require_admin()
    if not admin:
        return _deny()
    rows = db.session.query(
        AuditLog.action, func.count(AuditLog.id),
    ).group_by(AuditLog.action).order_by(func.count(AuditLog.id).desc()).all()
    entity_rows = db.session.query(AuditLog.entity_type).distinct().all()
    return jsonify({
        'actions': [{'action': a, 'count': int(n)} for a, n in rows],
        'entity_types': sorted({e[0] for e in entity_rows if e[0]}),
    }), 200


@admin_api_bp.route('/audit', methods=['GET'])
@jwt_required()
def list_audit():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = AuditLog.query
    action = (request.args.get('action') or '').strip()
    if action:
        # Comma separated groups let the UI offer "all login events" etc.
        actions = [a.strip() for a in action.split(',') if a.strip()]
        query = query.filter(AuditLog.action.in_(actions))
    actor_id = request.args.get('actor_id')
    if actor_id:
        query = query.filter(AuditLog.actor_id == actor_id)
    entity_type = request.args.get('entity_type')
    if entity_type:
        query = query.filter(AuditLog.entity_type == entity_type)
    entity_id = request.args.get('entity_id')
    if entity_id:
        query = query.filter(AuditLog.entity_id == entity_id)
    ip_address = request.args.get('ip')
    if ip_address:
        query = query.filter(AuditLog.ip_address.ilike(f'%{ip_address}%'))
    q = (request.args.get('q') or '').strip()
    if q:
        like = f'%{q}%'
        query = query.filter(or_(
            AuditLog.action.ilike(like),
            AuditLog.entity_id.ilike(like),
            AuditLog.ip_address.ilike(like),
            AuditLog.new_value.ilike(like),
        ))

    query = _date_range_filter(query, AuditLog.created_at)
    query = _apply_sort(query, AuditLog, {'created_at', 'action'},
                        'created_at')
    pagination, meta = _paginate(query, page, per_page)
    actors = _display_names([l.actor_id for l in pagination.items])
    return jsonify({
        'logs': [{
            'id': l.id, 'actor_id': l.actor_id,
            'actor_name': actors.get(l.actor_id),
            'action': l.action, 'entity_type': l.entity_type,
            'entity_id': l.entity_id, 'ip_address': l.ip_address,
            'user_agent': l.user_agent,
            'old_value': l.old_value, 'new_value': l.new_value,
            'created_at': utc_iso(l.created_at),
        } for l in pagination.items],
        **meta,
    }), 200


# --------------------------------------------------------------------------
# support inbox
# --------------------------------------------------------------------------
@admin_api_bp.route('/support/tickets', methods=['GET'])
@jwt_required()
def list_tickets():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = SupportTicket.query
    status = (request.args.get('status') or '').strip()
    if status and status != 'all':
        if status not in TICKET_STATUSES:
            return jsonify({'error': 'status نامعتبر است'}), 400
        query = query.filter(SupportTicket.status == status)
    topic = (request.args.get('topic') or '').strip()
    if topic:
        query = query.filter(SupportTicket.topic == topic)
    q = (request.args.get('q') or '').strip()
    if q:
        like = f'%{q}%'
        query = query.filter(or_(
            SupportTicket.message.ilike(like),
            SupportTicket.mobile_number.ilike(like),
            SupportTicket.display_name.ilike(like),
        ))
    query = _date_range_filter(query, SupportTicket.created_at)
    query = _apply_sort(query, SupportTicket,
                        {'created_at', 'updated_at', 'status'}, 'created_at')
    pagination, meta = _paginate(query, page, per_page)
    counts = dict(
        db.session.query(SupportTicket.status, func.count(SupportTicket.id))
        .group_by(SupportTicket.status).all()
    )
    return jsonify({
        'tickets': [t.to_dict() for t in pagination.items],
        'counts': {s: int(counts.get(s, 0)) for s in TICKET_STATUSES},
        **meta,
    }), 200


@admin_api_bp.route('/support/tickets/<ticket_id>', methods=['POST'])
@jwt_required()
def update_ticket(ticket_id):
    """Change ticket status / note / assignee."""
    admin = require_admin()
    if not admin:
        return _deny()
    ticket = db.session.get(SupportTicket, ticket_id)
    if not ticket:
        return jsonify({'error': 'تیکت یافت نشد'}), 404
    data = request.get_json(silent=True) or {}
    if 'status' in data:
        status = data['status']
        if status not in TICKET_STATUSES:
            return jsonify({'error': 'status نامعتبر است'}), 400
        ticket.status = status
        if status in ('resolved', 'closed'):
            ticket.resolved_by = admin.id
            ticket.resolved_at = datetime.utcnow()
    if 'admin_note' in data:
        ticket.admin_note = (data['admin_note'] or '')[:2000] or None
    if data.get('assign_to_me'):
        ticket.assigned_to = admin.id
    ticket.updated_at = datetime.utcnow()
    _log(admin, 'admin_update_ticket', 'support_ticket', ticket_id,
         new_value=ticket.status)
    db.session.commit()
    return jsonify({'ok': True, 'ticket': ticket.to_dict()}), 200


@admin_api_bp.route('/support/chats', methods=['GET'])
@jwt_required()
def support_chats():
    """The user↔support conversations, so admins can read what users sent.

    This is the piece the old panel was missing entirely: support chats exist
    in the app, but nothing surfaced them to an administrator.
    """
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()

    query = Chat.query.filter(
        Chat.chat_type == 'support', Chat.is_deleted.is_(False))
    query = _date_range_filter(query, Chat.created_at)
    query = query.order_by(Chat.updated_at.desc())
    pagination, meta = _paginate(query, page, per_page)

    chat_ids = [c.id for c in pagination.items]
    # The requester is the non-support member of each thread.
    rows = db.session.query(ChatMember, User).join(
        User, User.id == ChatMember.user_id,
    ).filter(
        ChatMember.chat_id.in_(chat_ids), ChatMember.is_deleted.is_(False),
    ).all() if chat_ids else []
    requester = {}
    for member, user in rows:
        if not user.is_support and member.chat_id not in requester:
            requester[member.chat_id] = user

    last_messages = {}
    unread = {}
    for cid in chat_ids:
        last = Message.query.filter_by(chat_id=cid).order_by(
            Message.created_at.desc()).first()
        if last:
            last_messages[cid] = last
        peer = requester.get(cid)
        if peer:
            unread[cid] = Message.query.filter_by(
                chat_id=cid, sender_id=peer.id).count()

    threads = []
    for c in pagination.items:
        peer = requester.get(c.id)
        last = last_messages.get(c.id)
        threads.append({
            'chat_id': c.id,
            'user': {
                'id': peer.id, 'display_name': peer.display_name,
                'username': peer.username, 'mobile_number': peer.mobile_number,
                'is_active': bool(peer.is_active),
            } if peer else None,
            'messages_from_user': int(unread.get(c.id, 0)),
            'last_message': {
                'content': (last.content or '')[:200],
                'message_type': last.message_type,
                'sender_id': last.sender_id,
                'created_at': utc_iso(last.created_at),
            } if last else None,
            'created_at': utc_iso(c.created_at),
            'updated_at': utc_iso(c.updated_at),
        })
    return jsonify({'threads': threads, **meta}), 200


@admin_api_bp.route('/support/chats/<chat_id>/messages', methods=['GET'])
@jwt_required()
def support_chat_messages(chat_id):
    """Read one support thread end to end."""
    admin = require_admin()
    if not admin:
        return _deny()
    chat = Chat.query.filter_by(
        id=chat_id, chat_type='support', is_deleted=False).first()
    if not chat:
        return jsonify({'error': 'چت پشتیبانی یافت نشد'}), 404
    page, per_page = _page_args()
    query = Message.query.filter_by(chat_id=chat_id).order_by(
        Message.created_at.asc())
    pagination, meta = _paginate(query, page, per_page)
    senders = _display_names([m.sender_id for m in pagination.items])
    return jsonify({
        'chat_id': chat_id,
        'messages': [{
            'id': m.id, 'sender_id': m.sender_id,
            'sender_name': senders.get(m.sender_id),
            'message_type': m.message_type,
            'content': m.content,
            'media_id': m.media_id,
            'is_deleted': bool(m.is_deleted_for_all or m.is_deleted),
            'created_at': utc_iso(m.created_at),
        } for m in pagination.items],
        **meta,
    }), 200


@admin_api_bp.route('/support/chats/<chat_id>/reply', methods=['POST'])
@jwt_required()
def support_chat_reply(chat_id):
    """Answer a user directly inside their support thread."""
    admin = require_admin()
    if not admin:
        return _deny()
    chat = Chat.query.filter_by(
        id=chat_id, chat_type='support', is_deleted=False).first()
    if not chat:
        return jsonify({'error': 'چت پشتیبانی یافت نشد'}), 404
    data = request.get_json(silent=True) or {}
    content = (data.get('content') or '').strip()
    if not content:
        return jsonify({'error': 'متن پاسخ را بنویسید'}), 400
    if len(content) > 4000:
        return jsonify({'error': 'متن پاسخ بیش از حد طولانی است'}), 400

    # The admin must be a member for the message to be visible/consistent
    # with every normal chat permission check in the app.
    member = ChatMember.query.filter_by(
        chat_id=chat_id, user_id=admin.id, is_deleted=False).first()
    if not member:
        revived = ChatMember.query.filter_by(
            chat_id=chat_id, user_id=admin.id).first()
        if revived:
            revived.is_deleted = False
            revived.deleted_at = None
        else:
            db.session.add(ChatMember(
                chat_id=chat_id, user_id=admin.id, role='admin'))

    message = Message(chat_id=chat_id, sender_id=admin.id,
                      message_type='text', content=content)
    db.session.add(message)
    chat.updated_at = datetime.utcnow()
    _log(admin, 'admin_support_reply', 'chat', chat_id)
    db.session.commit()
    return jsonify({
        'ok': True,
        'message': {
            'id': message.id, 'chat_id': chat_id, 'sender_id': admin.id,
            'content': content, 'message_type': 'text',
            'created_at': utc_iso(message.created_at),
        },
    }), 201


# --------------------------------------------------------------------------
# reports queue
# --------------------------------------------------------------------------
@admin_api_bp.route('/reports', methods=['GET'])
@jwt_required()
def list_reports():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()
    query = Report.query
    status = (request.args.get('status') or '').strip()
    if status and status != 'all':
        query = query.filter(Report.status == status)
    target_type = (request.args.get('target_type') or '').strip()
    if target_type:
        query = query.filter(Report.target_type == target_type)
    reason = (request.args.get('reason') or '').strip()
    if reason:
        query = query.filter(Report.reason == reason)
    query = _date_range_filter(query, Report.created_at)
    query = _apply_sort(query, Report, {'created_at', 'status'}, 'created_at')
    pagination, meta = _paginate(query, page, per_page)
    counts = dict(
        db.session.query(Report.status, func.count(Report.id))
        .group_by(Report.status).all()
    )
    return jsonify({
        'reports': [r.to_dict(include_reporter=True) for r in pagination.items],
        'counts': {k: int(v) for k, v in counts.items()},
        **meta,
    }), 200


# --------------------------------------------------------------------------
# devices & security oversight
# --------------------------------------------------------------------------
@admin_api_bp.route('/devices', methods=['GET'])
@jwt_required()
def list_devices_admin():
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()
    query = UserDevice.query
    if not _bool_arg('include_deleted'):
        query = query.filter(UserDevice.is_deleted.is_(False))
    user_id = request.args.get('user_id')
    if user_id:
        query = query.filter(UserDevice.user_id == user_id)
    primary = _bool_arg('is_primary')
    if primary is not None:
        query = query.filter(UserDevice.is_primary.is_(primary))
    q = (request.args.get('q') or '').strip()
    if q:
        like = f'%{q}%'
        query = query.filter(or_(
            UserDevice.device_name.ilike(like),
            UserDevice.device_model.ilike(like),
            UserDevice.device_fingerprint.ilike(like)))
    query = _date_range_filter(query, UserDevice.created_at)
    query = _apply_sort(query, UserDevice,
                        {'created_at', 'last_active'}, 'last_active')
    pagination, meta = _paginate(query, page, per_page)
    owners = _display_names([d.user_id for d in pagination.items])
    return jsonify({
        'devices': [{
            'id': d.id, 'user_id': d.user_id,
            'user_name': owners.get(d.user_id),
            'device_name': d.device_name, 'device_model': d.device_model,
            'os_version': d.os_version, 'app_version': d.app_version,
            'is_primary': bool(getattr(d, 'is_primary', False)),
            'is_active': bool(d.is_active), 'is_deleted': bool(d.is_deleted),
            'last_active': utc_iso(d.last_active),
            'created_at': utc_iso(d.created_at),
        } for d in pagination.items],
        **meta,
    }), 200


@admin_api_bp.route('/security/alerts', methods=['GET'])
@jwt_required()
def list_security_alerts():
    """Install-wide security events (new-device logins, 2FA changes…)."""
    admin = require_admin()
    if not admin:
        return _deny()
    page, per_page = _page_args()
    query = SecurityAlert.query
    alert_type = (request.args.get('alert_type') or '').strip()
    if alert_type:
        query = query.filter(SecurityAlert.alert_type == alert_type)
    severity = (request.args.get('severity') or '').strip()
    if severity:
        query = query.filter(SecurityAlert.severity == severity)
    user_id = request.args.get('user_id')
    if user_id:
        query = query.filter(SecurityAlert.user_id == user_id)
    query = _date_range_filter(query, SecurityAlert.created_at)
    query = query.order_by(SecurityAlert.created_at.desc())
    pagination, meta = _paginate(query, page, per_page)
    owners = _display_names([a.user_id for a in pagination.items])
    return jsonify({
        'alerts': [{
            **a.to_dict(),
            'user_id': a.user_id,
            'user_name': owners.get(a.user_id),
        } for a in pagination.items],
        **meta,
    }), 200


# --------------------------------------------------------------------------
# upload settings (per-category limits, category switches, per-user caps)
# --------------------------------------------------------------------------
@admin_api_bp.route('/settings/uploads', methods=['GET'])
@jwt_required()
def get_upload_settings_api():
    admin = require_admin()
    if not admin:
        return _deny()
    from app.services import app_settings
    settings = app_settings.get_upload_settings()
    return jsonify({
        'limits_mb': settings['limits_mb'],
        'enabled': settings['enabled'],
        'categories': list(app_settings.CATEGORIES),
        'labels': app_settings.CATEGORY_LABELS,
        'user_limits': app_settings.list_user_limits(),
    }), 200


@admin_api_bp.route('/settings/uploads', methods=['PUT', 'POST'])
@jwt_required()
def update_upload_settings_api():
    admin = require_admin()
    if not admin:
        return _deny()
    from app.services import app_settings
    data = request.get_json(silent=True) or {}
    try:
        settings = app_settings.save_upload_settings(
            limits_mb=data.get('limits_mb'), enabled=data.get('enabled'))
    except ValueError as error:
        return jsonify({'error': str(error)}), 400
    _log(admin, 'admin_update_upload_settings', 'settings', 'uploads',
         new_value=str(settings['limits_mb']))
    db.session.commit()
    return jsonify({
        'limits_mb': settings['limits_mb'],
        'enabled': settings['enabled'],
    }), 200


@admin_api_bp.route('/users/<user_id>/upload-limit', methods=['POST'])
@jwt_required()
def set_user_upload_limit_api(user_id):
    admin = require_admin()
    if not admin:
        return _deny()
    user, error = _load_user_or_404(user_id)
    if error:
        return error
    from app.services import app_settings
    data = request.get_json(silent=True) or {}
    try:
        cap = app_settings.set_user_limit_mb(user_id, data.get('max_mb'))
    except (TypeError, ValueError):
        return jsonify({'error': 'مقدار سقف حجم نامعتبر است'}), 400
    _log(admin, 'admin_set_user_upload_limit', 'user', user_id,
         new_value=str(cap))
    db.session.commit()
    return jsonify({'user_id': user_id, 'max_mb': cap}), 200
