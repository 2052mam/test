"""Point 4: polling must recover instead of freezing inside groups/channels.

The chat screen polls `GET /messages/<chat_id>?after_id=<last seen>` every few
seconds. When that cursor message was hard-deleted the endpoint answered 404
forever, so the poll never advanced and new messages only appeared after
leaving the chat and coming back.
"""
import pytest

from app import db
from app.models.chat import Chat, ChatMember
from app.models.message import Message
from app.models.user import User


@pytest.fixture()
def channel(app):
    from datetime import datetime
    with app.app_context():
        db.session.add(User(id='poll-u', email='p@e.t', username='pollu',
                            display_name='Poll U', password_hash='x',
                            totp_secret='JBSWY3DPEHPK3PXP'))
        db.session.add(Chat(id='poll-chan', chat_type='channel',
                            title='Poll Channel', created_by='poll-u'))
        db.session.flush()
        db.session.add(ChatMember(chat_id='poll-chan', user_id='poll-u',
                                  role='owner'))
        for index in range(3):
            db.session.add(Message(
                id=f'pm{index}', chat_id='poll-chan', sender_id='poll-u',
                message_type='text', content=f'message {index}',
                created_at=datetime(2026, 1, 1, 10, index)))
        db.session.commit()
    return 'poll-chan'


def _headers(user_id='poll-u'):
    from flask_jwt_extended import create_access_token
    return {'Authorization': 'Bearer ' + create_access_token(
        identity=user_id, additional_claims={'device_id': 'd1'})}


def test_a_normal_poll_returns_only_newer_messages(app, client, channel):
    with app.app_context():
        headers = _headers()
    response = client.get(f'/api/v1/messages/{channel}?after_id=pm0',
                          headers=headers)
    assert response.status_code == 200
    assert [m['id'] for m in response.json['messages']] == ['pm1', 'pm2']
    assert response.json.get('cursor_reset') is not True


def test_a_hard_deleted_cursor_no_longer_freezes_the_poll(app, client,
                                                          channel):
    """The regression: this used to 404 on every poll, forever."""
    with app.app_context():
        headers = _headers()
        db.session.delete(db.session.get(Message, 'pm1'))
        db.session.commit()

    response = client.get(f'/api/v1/messages/{channel}?after_id=pm1',
                          headers=headers)
    assert response.status_code == 200
    # The client is told to replace its cursor rather than append blindly.
    assert response.json['cursor_reset'] is True
    assert response.json['messages']


def test_after_since_recovers_the_right_slice_of_history(app, client,
                                                         channel):
    with app.app_context():
        headers = _headers()
        db.session.delete(db.session.get(Message, 'pm1'))
        db.session.commit()

    response = client.get(
        f'/api/v1/messages/{channel}'
        '?after_id=pm1&after_since=2026-01-01T10:00:00Z', headers=headers)
    assert response.status_code == 200
    assert response.json['cursor_reset'] is True
    # Only what the client has not seen, based on the timestamp fallback.
    assert [m['id'] for m in response.json['messages']] == ['pm2']


def test_a_cursor_from_another_chat_is_still_rejected(app, client, channel):
    """Recovery must not become a way to read across chat boundaries."""
    with app.app_context():
        headers = _headers()
        db.session.add(Chat(id='other-chan', chat_type='channel',
                            title='Other', created_by='poll-u'))
        db.session.flush()
        db.session.add(Message(id='other-msg', chat_id='other-chan',
                               sender_id='poll-u', message_type='text',
                               content='not yours'))
        db.session.commit()

    response = client.get(f'/api/v1/messages/{channel}?after_id=other-msg',
                          headers=headers)
    assert response.status_code == 404


def test_a_soft_deleted_cursor_simply_yields_nothing_new(app, client,
                                                         channel):
    with app.app_context():
        headers = _headers()
        db.session.get(Message, 'pm2').is_deleted_for_all = True
        db.session.commit()
    response = client.get(f'/api/v1/messages/{channel}?after_id=pm2',
                          headers=headers)
    assert response.status_code == 200
    assert response.json['messages'] == []


def test_a_missing_before_id_cursor_still_404s(app, client, channel):
    """Paging older history is a user action, not a poll: fail loudly."""
    with app.app_context():
        headers = _headers()
        db.session.delete(db.session.get(Message, 'pm1'))
        db.session.commit()
    response = client.get(f'/api/v1/messages/{channel}?before_id=pm1',
                          headers=headers)
    assert response.status_code == 404
