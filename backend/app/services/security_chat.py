"""Point 7: a dedicated one-way "Security Support" service chat.

Telegram delivers login codes and security warnings through a verified service
account, not through Saved Messages. Mixing them into Saved Messages was wrong
for two reasons: the user's own notes got polluted with system text, and
because Saved Messages is writable the "official" warnings looked forgeable.

This module owns a per-user chat of type ``security``:

* exactly one member (the user), who may read but never post,
* every message is authored by the chat itself (``sender_id`` is the user, but
  ``is_service`` marks it as system-generated),
* it is created on demand, so existing accounts get one the first time a code
  or alert is delivered.

``chat_permissions.can_send`` refuses this chat type, which is what makes it
one-way.
"""
from datetime import datetime

from app import db
from app.models.chat import Chat, ChatMember
from app.models.message import Message

SECURITY_CHAT_TYPE = 'security'
SECURITY_CHAT_TITLE = 'پشتیبانی امنیتی'
SECURITY_CHAT_TITLE_EN = 'Security Support'


def find_security_chat(user_id):
    """The user's security chat, or None when it has not been created yet."""
    member = ChatMember.query.join(Chat, Chat.id == ChatMember.chat_id).filter(
        ChatMember.user_id == user_id,
        ChatMember.is_deleted.is_(False),
        Chat.chat_type == SECURITY_CHAT_TYPE,
        Chat.is_deleted.is_(False),
    ).first()
    if member is None:
        return None
    return db.session.get(Chat, member.chat_id)


def ensure_security_chat(user_id):
    """Get-or-create the security chat so delivery always has a target."""
    chat = find_security_chat(user_id)
    if chat is not None:
        return chat
    chat = Chat(
        chat_type=SECURITY_CHAT_TYPE,
        title=SECURITY_CHAT_TITLE,
        created_by=user_id,
        # Service chats are never public and cannot be joined.
        is_public=False,
    )
    db.session.add(chat)
    db.session.flush()
    db.session.add(ChatMember(chat_id=chat.id, user_id=user_id, role='member'))
    return chat


def post_security_message(user_id, body, *, created_at=None):
    """Append a system message to the user's Security Support chat.

    Returns the created Message, or None when the user no longer exists.
    """
    if not body:
        return None
    chat = ensure_security_chat(user_id)
    if chat is None:
        return None
    message = Message(
        chat_id=chat.id,
        sender_id=user_id,
        message_type='text',
        content=body,
        created_at=created_at or datetime.utcnow(),
    )
    # Marks the row as authored by the system rather than by the member, so
    # clients can render the verified-service styling.
    if hasattr(Message, 'is_service'):
        message.is_service = True
    db.session.add(message)
    chat.updated_at = datetime.utcnow()
    return message
