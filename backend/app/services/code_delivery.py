"""Where a login code is delivered: in-app first, SMS as the fallback.

Telegram does not text you when you are already signed in somewhere: it sends
the code to your other Telegram sessions and only falls back to SMS when there
is nowhere to deliver it. This module implements that decision and the in-app
delivery itself (Point 3).

In-app delivery writes the code into the account's own Saved Messages chat,
which every signed-in device of that account already polls. The code therefore
appears on the trusted device within one poll interval, never leaves our
infrastructure, and costs no SMS credit.
"""
from datetime import datetime, timedelta

from app import db
from app.services.security_chat import (
    ensure_security_chat,
    post_security_message,
)
from app.models.chat import Chat, ChatMember
from app.models.message import Message
from app.models.user import UserDevice, UserSession

# A session is only a viable delivery target if it has actually been used
# recently; a phone that has been off for a month must not swallow the code.
ACTIVE_DEVICE_WINDOW = timedelta(days=14)

DELIVERY_IN_APP = 'in_app'
DELIVERY_SMS = 'sms'


def active_delivery_devices(user_id):
    """Signed-in devices recent enough to receive an in-app code."""
    cutoff = datetime.utcnow() - ACTIVE_DEVICE_WINDOW
    devices = UserDevice.query.filter(
        UserDevice.user_id == user_id,
        UserDevice.is_deleted.is_(False),
        UserDevice.is_active.is_(True),
        UserDevice.last_active.isnot(None),
        UserDevice.last_active >= cutoff,
    ).all()
    if not devices:
        return []
    live_ids = {
        row.device_id for row in UserSession.query.filter(
            UserSession.user_id == user_id,
            UserSession.is_active.is_(True),
            UserSession.expires_at > datetime.utcnow(),
        ).all()
    }
    return [d for d in devices if d.id in live_ids]


def choose_delivery_channel(user_id):
    """`in_app` when the account has a live trusted session, else `sms`."""
    return DELIVERY_IN_APP if active_delivery_devices(user_id) else DELIVERY_SMS


def _saved_chat(user_id):
    member = ChatMember.query.join(Chat, Chat.id == ChatMember.chat_id).filter(
        ChatMember.user_id == user_id,
        ChatMember.is_deleted.is_(False),
        Chat.chat_type == 'saved',
        Chat.is_deleted.is_(False),
    ).first()
    if member is None:
        return None
    return db.session.get(Chat, member.chat_id)


def ensure_saved_chat(user_id):
    """Saved Messages, created on demand so delivery always has a target."""
    chat = _saved_chat(user_id)
    if chat is not None:
        return chat
    chat = Chat(chat_type='saved', title='پیام‌های ذخیره‌شده',
                created_by=user_id)
    db.session.add(chat)
    db.session.flush()
    db.session.add(ChatMember(chat_id=chat.id, user_id=user_id, role='owner'))
    return chat


def deliver_code_in_app(user, code, *, ip_address=None, device_label=None):
    """Post the login code to the account's Security Support chat.

    Point 7: this used to land in Saved Messages, which mixed system security
    text into the user's own notes and looked forgeable because that chat is
    writable. It now goes to the dedicated read-only service chat.

    Returns True when the message was written. The caller keeps the SMS path
    as a fallback so a delivery failure can never strand the user.
    """
    chat = ensure_security_chat(user.id)
    if chat is None:
        return False
    where = f'\nدستگاه درخواست‌کننده: {device_label}' if device_label else ''
    origin = f'\nIP: {ip_address}' if ip_address else ''
    body = (
        f'🔐 کد ورود شما: {code}\n\n'
        'این کد برای ورود به حساب شما درخواست شده است و فقط چند دقیقه اعتبار دارد.'
        f'{where}{origin}\n\n'
        '⚠️ اگر شما این درخواست را نداده‌اید، این کد را با هیچ‌کس در میان نگذارید '
        'و از بخش «دستگاه‌ها و نشست‌ها» دستگاه‌های ناشناس را حذف کنید.'
    )
    post_security_message(user.id, body)
    return True
