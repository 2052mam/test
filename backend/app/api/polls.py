"""Telegram-style polls and quizzes.

Creating a poll produces a normal ``message_type == 'poll'`` message, so the
poll travels through the existing history, polling, notification, pin and
delete flows untouched.  Votes are stored server side and always recomputed,
never trusted from the client.
"""
from datetime import datetime

from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required

from app import db
from app.models.audit import AuditLog
from app.models.chat import Chat, ChatMember
from app.models.message import Message, MessageStatus
from app.models.poll import (
    POLL_MAX_EXPLANATION,
    POLL_MAX_OPTION,
    POLL_MAX_OPTIONS,
    POLL_MAX_QUESTION,
    POLL_MIN_OPTIONS,
    Poll,
    PollOption,
    PollVote,
    serialize_poll,
)
from app.services.chat_permissions import can_send, membership
from app.services.message_payloads import serialize_messages, user_in_chat
from app.services.request_validation import validate_object_body

polls_bp = Blueprint('polls', __name__)

polls_bp.before_request(validate_object_body)


def _client_ip():
    return request.headers.get('X-Forwarded-For', request.remote_addr)


def _poll_for_viewer(poll_id, user_id):
    """Return (poll, message) only when the viewer may see this poll."""
    poll = Poll.query.filter_by(id=poll_id, is_deleted=False).first()
    if poll is None:
        return None, None, (jsonify({'error': 'نظرسنجی یافت نشد'}), 404)
    if not user_in_chat(user_id, poll.chat_id):
        return None, None, (jsonify({'error': 'دسترسی ندارید'}), 403)
    message = Message.query.filter_by(
        poll_id=poll.id, is_deleted=False, is_deleted_for_all=False,
    ).first()
    return poll, message, None


@polls_bp.route('/', methods=['POST'])
@jwt_required()
def create_poll():
    """Create a poll/quiz and post it as a message in the chat."""
    user_id = get_jwt_identity()
    data = request.get_json(silent=True) or {}

    chat_id = data.get('chat_id')
    question = (data.get('question') or '').strip()
    raw_options = data.get('options')
    poll_type = (data.get('poll_type') or 'regular').strip().lower()
    is_anonymous = bool(data.get('is_anonymous', True))
    allows_multiple = bool(data.get('allows_multiple_answers', False))
    explanation = (data.get('explanation') or '').strip()[:POLL_MAX_EXPLANATION] or None
    reply_to_id = data.get('reply_to_id')

    if not chat_id:
        return jsonify({'error': 'chat_id الزامی است'}), 400
    if not question:
        return jsonify({'error': 'متن سؤال الزامی است'}), 400
    if len(question) > POLL_MAX_QUESTION:
        return jsonify({'error': f'سؤال حداکثر {POLL_MAX_QUESTION} کاراکتر است'}), 400
    if poll_type not in ('regular', 'quiz'):
        return jsonify({'error': 'نوع نظرسنجی نامعتبر است'}), 400
    if not isinstance(raw_options, list):
        return jsonify({'error': 'گزینه‌ها نامعتبر هستند'}), 400

    options = []
    for item in raw_options:
        text = (item.get('text') if isinstance(item, dict) else item)
        text = (text or '').strip() if isinstance(text, str) else ''
        if not text:
            continue
        if len(text) > POLL_MAX_OPTION:
            return jsonify({'error': f'هر گزینه حداکثر {POLL_MAX_OPTION} کاراکتر است'}), 400
        options.append({
            'text': text,
            'is_correct': bool(item.get('is_correct')) if isinstance(item, dict) else False,
        })
    if len(options) < POLL_MIN_OPTIONS:
        return jsonify({'error': f'حداقل {POLL_MIN_OPTIONS} گزینه لازم است'}), 400
    if len(options) > POLL_MAX_OPTIONS:
        return jsonify({'error': f'حداکثر {POLL_MAX_OPTIONS} گزینه مجاز است'}), 400

    # Quizzes have exactly one correct answer and never allow multiple votes.
    correct_index = data.get('correct_option_index')
    if poll_type == 'quiz':
        if correct_index is not None:
            try:
                correct_index = int(correct_index)
            except (TypeError, ValueError):
                return jsonify({'error': 'گزینه صحیح نامعتبر است'}), 400
            if correct_index < 0 or correct_index >= len(options):
                return jsonify({'error': 'گزینه صحیح نامعتبر است'}), 400
            for index, option in enumerate(options):
                option['is_correct'] = index == correct_index
        if sum(1 for option in options if option['is_correct']) != 1:
            return jsonify({'error': 'آزمون باید دقیقاً یک گزینه صحیح داشته باشد'}), 400
        allows_multiple = False
    else:
        for option in options:
            option['is_correct'] = False
        explanation = None

    if not user_in_chat(user_id, chat_id):
        return jsonify({'error': 'دسترسی ندارید'}), 403
    chat = Chat.query.filter_by(id=chat_id, is_deleted=False).first()
    if not chat:
        return jsonify({'error': 'چت یافت نشد'}), 404
    if chat.is_suspended:
        return jsonify({'error': 'این چت توسط مدیریت تعلیق شده است'}), 403
    if chat.is_closed:
        member = membership(chat, user_id)
        if not member or member.role != 'owner':
            return jsonify({'error': 'این چت بسته شده است'}), 403
    # A poll is a text-like post: it follows the send_messages right.
    if not can_send(chat, user_id, 'text'):
        return jsonify({'error': 'ارسال پیام در این چت مجاز نیست'}), 403

    close_at = None
    raw_close = data.get('close_at')
    if raw_close:
        try:
            iso = str(raw_close).strip().replace('Z', '+00:00').replace(' ', 'T')
            close_at = datetime.fromisoformat(iso)
            if close_at.tzinfo is not None:
                import datetime as dt_module
                close_at = close_at.astimezone(dt_module.timezone.utc).replace(tzinfo=None)
        except Exception:
            return jsonify({'error': 'زمان بسته شدن نامعتبر است'}), 400
        if close_at <= datetime.utcnow():
            return jsonify({'error': 'زمان بسته شدن باید در آینده باشد'}), 400

    if reply_to_id:
        from app.services.message_payloads import visible_messages
        original = visible_messages(user_id).filter_by(
            id=reply_to_id, chat_id=chat_id,
        ).first()
        if original is None:
            return jsonify({'error': 'پیام مرجع در این چت در دسترس نیست'}), 400

    poll = Poll(
        chat_id=chat_id,
        created_by=user_id,
        question=question,
        poll_type=poll_type,
        is_anonymous=is_anonymous,
        allows_multiple_answers=allows_multiple,
        explanation=explanation,
        close_at=close_at,
    )
    db.session.add(poll)
    db.session.flush()
    for position, option in enumerate(options):
        db.session.add(PollOption(
            poll_id=poll.id,
            text=option['text'],
            position=position,
            is_correct=option['is_correct'],
        ))

    message = Message(
        chat_id=chat_id,
        sender_id=user_id,
        message_type='poll',
        content=question,
        poll_id=poll.id,
        reply_to_id=reply_to_id,
    )
    db.session.add(message)
    db.session.flush()

    db.session.add(MessageStatus(message_id=message.id, user_id=user_id, status='sent'))
    for member in ChatMember.query.filter_by(chat_id=chat_id, is_deleted=False).all():
        if member.user_id != user_id:
            db.session.add(MessageStatus(
                message_id=message.id, user_id=member.user_id,
                status='delivered', delivered_at=datetime.utcnow(),
            ))
    chat.updated_at = datetime.utcnow()
    db.session.add(AuditLog(
        actor_id=user_id, action='create_poll', entity_type='poll',
        entity_id=poll.id, ip_address=_client_ip(),
    ))
    db.session.commit()

    try:
        from flask import current_app
        from app.services.push_service import notify_new_message
        notify_new_message(current_app._get_current_object(), chat_id, user_id)
    except Exception:
        pass

    payload = serialize_messages([message], user_id, status_override='sent')[0]
    return jsonify(payload), 201


@polls_bp.route('/<poll_id>', methods=['GET'])
@jwt_required()
def get_poll(poll_id):
    user_id = get_jwt_identity()
    poll, _message, error = _poll_for_viewer(poll_id, user_id)
    if error:
        return error
    return jsonify(serialize_poll(poll, user_id)), 200


@polls_bp.route('/<poll_id>/vote', methods=['POST'])
@jwt_required()
def vote(poll_id):
    """Cast (or change) a vote. Re-voting the same option retracts it."""
    user_id = get_jwt_identity()
    poll, _message, error = _poll_for_viewer(poll_id, user_id)
    if error:
        return error
    if poll.effective_closed():
        return jsonify({'error': 'این نظرسنجی بسته شده است'}), 409

    data = request.get_json(silent=True) or {}
    raw_ids = data.get('option_ids')
    if raw_ids is None and data.get('option_id'):
        raw_ids = [data.get('option_id')]
    if not isinstance(raw_ids, list) or not raw_ids:
        return jsonify({'error': 'گزینه‌ای انتخاب نشده است'}), 400
    selected = [str(item) for item in raw_ids if isinstance(item, (str, int))]
    if not selected:
        return jsonify({'error': 'گزینه‌ای انتخاب نشده است'}), 400
    if not poll.allows_multiple_answers and len(set(selected)) > 1:
        return jsonify({'error': 'فقط یک گزینه می‌توانید انتخاب کنید'}), 400

    valid_ids = {option.id for option in poll.options.all()}
    if any(option_id not in valid_ids for option_id in selected):
        return jsonify({'error': 'گزینه نامعتبر است'}), 400

    existing = PollVote.query.filter_by(poll_id=poll.id, user_id=user_id).all()
    existing_ids = {vote.option_id for vote in existing}

    if not poll.allows_multiple_answers:
        chosen = selected[0]
        # Telegram quizzes are final: an answered quiz cannot be changed.
        if poll.is_quiz and existing_ids:
            return jsonify({'error': 'پاسخ آزمون قابل تغییر نیست'}), 409
        if existing_ids == {chosen}:
            # Tapping the same option again retracts the vote (regular polls).
            for vote_row in existing:
                db.session.delete(vote_row)
        else:
            for vote_row in existing:
                db.session.delete(vote_row)
            db.session.add(PollVote(poll_id=poll.id, option_id=chosen, user_id=user_id))
    else:
        wanted = set(selected)
        for vote_row in existing:
            if vote_row.option_id not in wanted:
                db.session.delete(vote_row)
        for option_id in wanted - existing_ids:
            db.session.add(PollVote(poll_id=poll.id, option_id=option_id, user_id=user_id))

    poll.updated_at = datetime.utcnow()
    db.session.commit()
    db.session.expire(poll)
    return jsonify(serialize_poll(poll, user_id)), 200


@polls_bp.route('/<poll_id>/retract', methods=['POST'])
@jwt_required()
def retract(poll_id):
    """Remove the viewer's votes (Telegram's "Retract vote")."""
    user_id = get_jwt_identity()
    poll, _message, error = _poll_for_viewer(poll_id, user_id)
    if error:
        return error
    if poll.effective_closed():
        return jsonify({'error': 'این نظرسنجی بسته شده است'}), 409
    if poll.is_quiz:
        return jsonify({'error': 'پاسخ آزمون قابل تغییر نیست'}), 409
    for vote_row in PollVote.query.filter_by(poll_id=poll.id, user_id=user_id).all():
        db.session.delete(vote_row)
    db.session.commit()
    db.session.expire(poll)
    return jsonify(serialize_poll(poll, user_id)), 200


@polls_bp.route('/<poll_id>/close', methods=['POST'])
@jwt_required()
def close_poll(poll_id):
    """Stop a poll. The author and chat admins may close it, like Telegram."""
    user_id = get_jwt_identity()
    poll, _message, error = _poll_for_viewer(poll_id, user_id)
    if error:
        return error
    chat = db.session.get(Chat, poll.chat_id)
    member = membership(chat, user_id) if chat else None
    is_admin = bool(member and member.role in ('owner', 'admin'))
    if poll.created_by != user_id and not is_admin:
        return jsonify({'error': 'فقط سازنده نظرسنجی می‌تواند آن را ببندد'}), 403
    if not poll.is_closed:
        poll.is_closed = True
        poll.closed_at = datetime.utcnow()
        db.session.add(AuditLog(
            actor_id=user_id, action='close_poll', entity_type='poll',
            entity_id=poll.id, ip_address=_client_ip(),
        ))
        db.session.commit()
    return jsonify(serialize_poll(poll, user_id)), 200


@polls_bp.route('/<poll_id>/voters', methods=['GET'])
@jwt_required()
def voters(poll_id):
    """Full voter list for a public (non-anonymous) poll."""
    user_id = get_jwt_identity()
    poll, _message, error = _poll_for_viewer(poll_id, user_id)
    if error:
        return error
    if poll.is_anonymous:
        return jsonify({'error': 'این نظرسنجی ناشناس است'}), 403

    from app.models.user import User
    rows = PollVote.query.filter_by(poll_id=poll.id).all()
    users = {
        u.id: u for u in User.query.filter(
            User.id.in_({row.user_id for row in rows} or {''}),
        ).all()
    }
    grouped = {}
    for row in rows:
        user = users.get(row.user_id)
        grouped.setdefault(row.option_id, []).append({
            'id': row.user_id,
            'display_name': user.display_name if user else '',
            'username': user.username if user else None,
            'avatar_url': (user.avatar_url if user and user.show_profile_photo else None),
        })
    return jsonify({
        'poll_id': poll.id,
        'options': [
            {
                'id': option.id,
                'text': option.text,
                'voters': grouped.get(option.id, []),
            }
            for option in poll.options.all()
        ],
    }), 200
