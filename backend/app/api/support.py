"""Support tickets, including the unauthenticated login-screen path (Point 6).

A user who never receives their SMS code cannot sign in, so they cannot use the
in-app support chat. `POST /support/tickets` therefore accepts anonymous
submissions (rate limited by IP and phone number), and the admin panel reads
them in its Support inbox.
"""
from datetime import datetime, timedelta

from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required, verify_jwt_in_request

from app import db
from app.models.audit import AuditLog
from app.models.support import TICKET_TOPICS, SupportTicket
from app.models.user import User
from app.services.timestamps import utc_iso

support_bp = Blueprint('support', __name__)

MAX_MESSAGE_LENGTH = 2000
MAX_TICKETS_PER_IP_HOUR = 5
MAX_TICKETS_PER_NUMBER_DAY = 5


def _client_ip():
    forwarded = request.headers.get('X-Forwarded-For')
    return (forwarded.split(',')[0].strip() if forwarded
            else request.remote_addr)


def _normalize_mobile(value):
    from app.api.auth import normalize_mobile_number
    return normalize_mobile_number(value)


def _optional_identity():
    """The signed-in user id, or None for the login-screen flow."""
    try:
        verify_jwt_in_request(optional=True)
        return get_jwt_identity()
    except Exception:
        return None


@support_bp.route('/topics', methods=['GET'])
def topics():
    """Topic list for the contact-support form."""
    labels = {
        'code_not_received': 'کد تأیید دریافت نشد',
        'login_problem': 'مشکل در ورود به حساب',
        'account_locked': 'حساب من مسدود/محدود شده',
        'bug_report': 'گزارش اشکال در برنامه',
        'abuse': 'گزارش سوءاستفاده',
        'other': 'موضوع دیگر',
    }
    return jsonify({
        'topics': [{'id': t, 'label': labels.get(t, t)} for t in TICKET_TOPICS],
    }), 200


@support_bp.route('/tickets', methods=['POST'])
def create_ticket():
    """Open a support ticket. Works signed-in *and* signed-out."""
    data = request.get_json(silent=True) or {}
    message = (data.get('message') or '').strip()
    if not message:
        return jsonify({'error': 'متن پیام را بنویسید'}), 400
    if len(message) > MAX_MESSAGE_LENGTH:
        return jsonify({
            'error': f'متن پیام حداکثر {MAX_MESSAGE_LENGTH} کاراکتر است',
        }), 400

    topic = data.get('topic') or 'other'
    if topic not in TICKET_TOPICS:
        return jsonify({'error': 'موضوع نامعتبر است'}), 400

    user_id = _optional_identity()
    mobile_number = _normalize_mobile(data.get('mobile_number'))
    display_name = (data.get('display_name') or '').strip()[:150] or None

    if user_id:
        user = User.query.filter_by(id=user_id, is_deleted=False).first()
        if user:
            mobile_number = mobile_number or user.mobile_number
            display_name = display_name or user.display_name
    elif not mobile_number:
        # Anonymous tickets need a way back to the reporter.
        return jsonify({
            'error': 'برای پیگیری، شماره موبایل خود را وارد کنید',
        }), 400

    ip_address = _client_ip()
    hour_ago = datetime.utcnow() - timedelta(hours=1)
    if ip_address:
        recent_ip = SupportTicket.query.filter(
            SupportTicket.ip_address == ip_address,
            SupportTicket.created_at >= hour_ago,
        ).count()
        if recent_ip >= MAX_TICKETS_PER_IP_HOUR:
            return jsonify({
                'error': 'تعداد درخواست‌های پشتیبانی از این اتصال بیش از حد مجاز است. کمی بعد تلاش کنید.',
            }), 429
    if mobile_number:
        day_ago = datetime.utcnow() - timedelta(days=1)
        recent_number = SupportTicket.query.filter(
            SupportTicket.mobile_number == mobile_number,
            SupportTicket.created_at >= day_ago,
        ).count()
        if recent_number >= MAX_TICKETS_PER_NUMBER_DAY:
            return jsonify({
                'error': 'برای این شماره امروز چند درخواست ثبت شده است. لطفاً منتظر پاسخ بمانید.',
            }), 429

    ticket = SupportTicket(
        user_id=user_id,
        mobile_number=mobile_number,
        display_name=display_name,
        topic=topic,
        message=message,
        ip_address=ip_address,
        user_agent=request.headers.get('User-Agent'),
        app_version=(data.get('app_version') or '')[:50] or None,
        platform=(data.get('platform') or '')[:40] or None,
    )
    db.session.add(ticket)
    db.session.add(AuditLog(
        actor_id=user_id or 'anonymous',
        action='support_ticket_created',
        entity_type='support_ticket',
        entity_id=ticket.id,
        ip_address=ip_address,
        user_agent=request.headers.get('User-Agent'),
    ))
    db.session.commit()
    return jsonify({
        'ok': True,
        'ticket_id': ticket.id,
        'status': ticket.status,
        'message': 'درخواست شما ثبت شد. پشتیبانی در اسرع وقت پاسخ می‌دهد.',
        'created_at': utc_iso(ticket.created_at),
    }), 201


@support_bp.route('/tickets/mine', methods=['GET'])
@jwt_required()
def my_tickets():
    """A signed-in user's own tickets and their status."""
    user_id = get_jwt_identity()
    user = User.query.filter_by(id=user_id, is_deleted=False).first()
    query = SupportTicket.query.filter(SupportTicket.user_id == user_id)
    if user and user.mobile_number:
        query = SupportTicket.query.filter(
            db.or_(
                SupportTicket.user_id == user_id,
                SupportTicket.mobile_number == user.mobile_number,
            )
        )
    tickets = query.order_by(SupportTicket.created_at.desc()).limit(50).all()
    return jsonify({
        'tickets': [t.to_dict(include_contact=False) for t in tickets],
    }), 200
