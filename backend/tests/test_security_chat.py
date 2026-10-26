"""Point 7: security notices live in a one-way "Security Support" chat.

They used to be written into Saved Messages, which mixed system text into the
user's own notes and — because Saved Messages is writable — made official
warnings look forgeable.
"""
from app import db
from app.models.chat import Chat
from app.models.message import Message
from app.services.security_alerts import record_alert
from app.services.security_chat import (
    SECURITY_CHAT_TYPE,
    ensure_security_chat,
    find_security_chat,
    post_security_message,
)


def _user(app, uid='sec-u1'):
    from app.models.user import User
    with app.app_context():
        db.session.add(User(id=uid, email=f'{uid}@e.t', username=uid,
                            display_name=uid, password_hash='x',
                            totp_secret='JBSWY3DPEHPK3PXP'))
        db.session.commit()
    return uid


def test_the_chat_is_created_on_demand_exactly_once(app):
    uid = _user(app)
    with app.app_context():
        assert find_security_chat(uid) is None
        first = ensure_security_chat(uid)
        db.session.commit()
        second = ensure_security_chat(uid)
        db.session.commit()
        assert first.id == second.id
        assert first.chat_type == SECURITY_CHAT_TYPE
        assert Chat.query.filter_by(chat_type=SECURITY_CHAT_TYPE).count() == 1


def test_alerts_are_mirrored_into_the_chat_not_saved_messages(app):
    uid = _user(app)
    with app.app_context():
        record_alert(uid, 'new_device_login', 'ورود جدید',
                     body='a new device signed in', severity='critical',
                     device_name='Pixel 7', ip_address='203.0.113.9')
        db.session.commit()
        # Nothing went to Saved Messages.
        assert Chat.query.filter_by(chat_type='saved').count() == 0
        chat = find_security_chat(uid)
        assert chat is not None
        messages = Message.query.filter_by(chat_id=chat.id).all()
        assert len(messages) == 1
        body = messages[0].content
        assert 'ورود جدید' in body
        assert 'a new device signed in' in body
        assert 'Pixel 7' in body and '203.0.113.9' in body


def test_post_to_chat_false_records_the_alert_without_a_message(app):
    uid = _user(app)
    with app.app_context():
        record_alert(uid, 'new_device_login', 'ورود جدید',
                     post_to_chat=False)
        db.session.commit()
        assert find_security_chat(uid) is None


def test_the_chat_is_read_only_for_its_member(app):
    uid = _user(app)
    with app.app_context():
        from app.services.chat_permissions import can_send
        chat = ensure_security_chat(uid)
        db.session.commit()
        for kind in ('text', 'image', 'voice', 'file', 'sticker', 'poll'):
            assert can_send(chat, uid, kind) is False


def test_the_member_may_still_clear_their_own_notices(app):
    uid = _user(app)
    with app.app_context():
        from app.services.chat_permissions import can_delete
        chat = ensure_security_chat(uid)
        message = post_security_message(uid, 'hello')
        db.session.commit()
        assert can_delete(chat, uid, message) is True


def test_api_refuses_a_member_post_but_serves_the_history(app, client, auth):
    from flask_jwt_extended import create_access_token
    uid = _user(app, 'sec-api')
    with app.app_context():
        post_security_message(uid, '🔴 security notice')
        db.session.commit()
        chat_id = find_security_chat(uid).id
        token = create_access_token(identity=uid,
                                    additional_claims={'device_id': 'd1'})
    headers = {'Authorization': f'Bearer {token}'}

    listed = client.get('/api/v1/chats/', headers=headers)
    assert listed.status_code == 200
    entry = next(c for c in listed.json['chats'] if c['id'] == chat_id)
    assert entry['chat_type'] == SECURITY_CHAT_TYPE
    assert entry['is_read_only'] is True
    # Server-authored messages still raise the unread badge.
    assert entry['unread_count'] == 1

    history = client.get(f'/api/v1/messages/{chat_id}', headers=headers)
    assert history.status_code == 200
    assert len(history.json['messages']) == 1

    blocked = client.post('/api/v1/messages/', headers=headers,
                          json={'chat_id': chat_id, 'content': 'reply'})
    assert blocked.status_code == 403
