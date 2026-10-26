"""Points 5 and 6: the support inbox and the comprehensive admin API."""
from datetime import datetime, timedelta

from app import db
from app.models.audit import AuditLog
from app.models.chat import Chat, ChatMember
from app.models.message import Message
from app.models.support import SupportTicket
from app.models.user import User, UserDevice, UserSession


def make_admin(app, name='alice'):
    with app.app_context():
        user = db.session.get(User, name)
        user.is_admin = True
        db.session.commit()


def make_support_thread(app, requester='bob'):
    """A user↔support conversation, as the app's /chats/support creates it."""
    with app.app_context():
        support_user = User(
            id='support-agent', email='support@example.test',
            username='support', display_name='Support',
            password_hash='unused', totp_secret='JBSWY3DPEHPK3PXP',
            is_support=True)
        db.session.add(support_user)
        chat = Chat(id='support-chat', chat_type='support',
                    title='پشتیبانی', created_by=requester)
        db.session.add(chat)
        db.session.flush()
        db.session.add_all([
            ChatMember(chat_id=chat.id, user_id=requester, role='member'),
            ChatMember(chat_id=chat.id, user_id='support-agent', role='admin'),
        ])
        db.session.add(Message(
            chat_id=chat.id, sender_id=requester, message_type='text',
            content='کد ورود برای من نمی‌آید، کمک کنید'))
        db.session.commit()
        return chat.id


# ---------------------------------------------------------------- Point 6 --
def test_anyone_can_open_a_ticket_without_being_signed_in(client):
    """The whole point: a user who cannot log in must still reach support."""
    response = client.post('/api/v1/support/tickets', json={
        'topic': 'code_not_received',
        'mobile_number': '09121234567',
        'message': 'کد تأیید برای من ارسال نمی‌شود',
        'app_version': '1.4.0',
        'platform': 'android',
    })
    assert response.status_code == 201
    assert response.json['ok'] is True
    assert response.json['ticket_id']


def test_an_anonymous_ticket_requires_a_way_to_reach_the_reporter(client):
    response = client.post('/api/v1/support/tickets', json={
        'topic': 'other', 'message': 'سلام'})
    assert response.status_code == 400


def test_ticket_validation_rejects_empty_text_and_bad_topics(client):
    assert client.post('/api/v1/support/tickets', json={
        'mobile_number': '09121234567', 'message': '   ',
    }).status_code == 400
    assert client.post('/api/v1/support/tickets', json={
        'mobile_number': '09121234567', 'message': 'x',
        'topic': 'nonsense',
    }).status_code == 400


def test_tickets_are_rate_limited_per_number(client):
    for index in range(5):
        response = client.post('/api/v1/support/tickets', json={
            'mobile_number': '09121234567',
            'message': f'مشکل شماره {index}'})
        assert response.status_code == 201
    flooded = client.post('/api/v1/support/tickets', json={
        'mobile_number': '09121234567', 'message': 'باز هم'})
    assert flooded.status_code == 429


def test_a_signed_in_user_sees_their_own_tickets(client, auth):
    client.post('/api/v1/support/tickets', headers=auth('bob'),
                json={'message': 'مشکل من', 'topic': 'bug_report'})
    mine = client.get('/api/v1/support/tickets/mine', headers=auth('bob'))
    assert mine.status_code == 200
    assert len(mine.json['tickets']) == 1
    # The contact block is admin-only information.
    assert 'ip_address' not in mine.json['tickets'][0]


def test_support_topics_are_published_for_the_form(client):
    response = client.get('/api/v1/support/topics')
    assert response.status_code == 200
    ids = [t['id'] for t in response.json['topics']]
    assert 'code_not_received' in ids


# ---------------------------------------------------------------- Point 5 --
def test_the_admin_api_is_closed_to_ordinary_users(client, auth):
    for path in ('/api/v1/admin/dashboard', '/api/v1/admin/users',
                 '/api/v1/admin/support/tickets', '/api/v1/admin/audit',
                 '/api/v1/admin/media', '/api/v1/admin/devices',
                 '/api/v1/admin/security/alerts'):
        assert client.get(path, headers=auth('bob')).status_code == 403


def test_the_admin_api_requires_authentication_at_all(client):
    assert client.get('/api/v1/admin/dashboard').status_code == 401


def test_the_dashboard_reports_totals_growth_and_backlog(app, client, auth):
    make_admin(app)
    client.post('/api/v1/support/tickets', json={
        'mobile_number': '09121234567', 'message': 'کمک'})
    response = client.get('/api/v1/admin/dashboard', headers=auth('alice'))
    assert response.status_code == 200
    body = response.json
    assert body['totals']['users'] == 3
    assert body['moderation']['open_tickets'] == 1
    assert len(body['series']) == 14
    assert 'private' in body['chat_types']
    assert 'storage' in body and 'bytes' in body['storage']
    # Legacy flat keys stay available for older consumers.
    assert body['users'] == body['totals']['users']


def test_users_can_be_filtered_by_status_role_and_text(app, client, auth):
    make_admin(app)
    with app.app_context():
        db.session.get(User, 'bob').is_active = False
        db.session.get(User, 'carol').is_limited = True
        db.session.commit()

    banned = client.get('/api/v1/admin/users?status=banned',
                        headers=auth('alice'))
    assert [u['id'] for u in banned.json['users']] == ['bob']

    limited = client.get('/api/v1/admin/users?status=limited',
                         headers=auth('alice'))
    assert [u['id'] for u in limited.json['users']] == ['carol']

    admins = client.get('/api/v1/admin/users?role=admin',
                        headers=auth('alice'))
    assert [u['id'] for u in admins.json['users']] == ['alice']

    searched = client.get('/api/v1/admin/users?q=carol', headers=auth('alice'))
    assert [u['id'] for u in searched.json['users']] == ['carol']

    # Pagination metadata is present and consistent.
    paged = client.get('/api/v1/admin/users?per_page=2', headers=auth('alice'))
    assert paged.json['per_page'] == 2
    assert paged.json['total'] == 3
    assert paged.json['pages'] == 2
    assert paged.json['has_next'] is True


def test_user_detail_gathers_everything_about_one_account(app, client, auth,
                                                          make_message):
    make_admin(app)
    make_message('m1', sender_id='bob')
    response = client.get('/api/v1/admin/users/bob', headers=auth('alice'))
    assert response.status_code == 200
    assert response.json['user']['id'] == 'bob'
    assert response.json['stats']['messages'] == 1
    assert response.json['chats'][0]['id'] == 'chat'
    assert response.json['recent_messages'][0]['id'] == 'm1'


def test_banning_a_user_also_kills_their_live_sessions(app, client, auth):
    make_admin(app)
    with app.app_context():
        device = UserDevice(id='dev-bob', user_id='bob',
                            device_fingerprint='fp-bob')
        db.session.add(device)
        db.session.add(UserSession(
            user_id='bob', device_id='dev-bob', refresh_token='rt-bob',
            expires_at=datetime.utcnow() + timedelta(days=1)))
        db.session.commit()

    response = client.post('/api/v1/admin/users/bob/ban',
                           headers=auth('alice'), json={'reason': 'spam'})
    assert response.status_code == 200
    with app.app_context():
        assert db.session.get(User, 'bob').is_active is False
        assert UserSession.query.filter_by(
            user_id='bob', is_active=True).count() == 0
        assert db.session.get(UserDevice, 'dev-bob').is_active is False

    client.post('/api/v1/admin/users/bob/unban', headers=auth('alice'))
    with app.app_context():
        assert db.session.get(User, 'bob').is_active is True


def test_an_admin_cannot_ban_or_demote_themselves(app, client, auth):
    make_admin(app)
    assert client.post('/api/v1/admin/users/alice/ban',
                       headers=auth('alice')).status_code == 400
    assert client.post('/api/v1/admin/users/alice/role', headers=auth('alice'),
                       json={'is_admin': False}).status_code == 400


def test_limiting_a_user_sets_an_expiry_and_can_be_undone(app, client, auth):
    make_admin(app)
    limited = client.post('/api/v1/admin/users/bob/limit',
                          headers=auth('alice'),
                          json={'days': 3, 'reason': 'spam'})
    assert limited.status_code == 200
    assert limited.json['limited_until']
    with app.app_context():
        assert db.session.get(User, 'bob').is_limited is True

    client.post('/api/v1/admin/users/bob/unlimit', headers=auth('alice'))
    with app.app_context():
        assert db.session.get(User, 'bob').is_limited is False


def test_roles_can_be_granted_and_revoked(app, client, auth):
    make_admin(app)
    response = client.post('/api/v1/admin/users/bob/role',
                           headers=auth('alice'),
                           json={'is_support': True, 'is_admin': True})
    assert response.status_code == 200
    with app.app_context():
        bob = db.session.get(User, 'bob')
        assert bob.is_admin is True and bob.is_support is True
    bad = client.post('/api/v1/admin/users/bob/role', headers=auth('alice'),
                      json={'is_admin': 'yes'})
    assert bad.status_code == 400


def test_chats_can_be_filtered_suspended_and_inspected(app, client, auth,
                                                       make_message):
    make_admin(app)
    make_message('m1')
    private_only = client.get('/api/v1/admin/chats?chat_type=private',
                              headers=auth('alice'))
    assert private_only.json['total'] == 2
    assert private_only.json['chats'][0]['members'] >= 1

    suspended = client.post('/api/v1/admin/chats/chat/suspend',
                            headers=auth('alice'),
                            json={'is_suspended': True, 'reason': 'abuse'})
    assert suspended.status_code == 200
    filtered = client.get('/api/v1/admin/chats?is_suspended=true',
                          headers=auth('alice'))
    assert [c['id'] for c in filtered.json['chats']] == ['chat']

    detail = client.get('/api/v1/admin/chats/chat', headers=auth('alice'))
    assert detail.status_code == 200
    assert detail.json['chat']['suspension_reason'] == 'abuse'
    assert detail.json['stats']['messages'] == 1
    assert {m['user_id'] for m in detail.json['members']} == {'alice', 'bob'}


def test_messages_can_be_filtered_by_chat_sender_type_text_and_date(
        app, client, auth, make_message):
    make_admin(app)
    make_message('m1', content='hello world', sender_id='alice')
    make_message('m2', content='secret plans', sender_id='bob',
                 message_type='image')

    by_sender = client.get('/api/v1/admin/messages?sender_id=bob',
                           headers=auth('alice'))
    assert [m['id'] for m in by_sender.json['messages']] == ['m2']
    assert by_sender.json['messages'][0]['sender_name'] == 'Bob'

    by_type = client.get('/api/v1/admin/messages?message_type=image',
                         headers=auth('alice'))
    assert [m['id'] for m in by_type.json['messages']] == ['m2']

    by_text = client.get('/api/v1/admin/messages?q=hello',
                         headers=auth('alice'))
    assert [m['id'] for m in by_text.json['messages']] == ['m1']

    future = client.get('/api/v1/admin/messages?from=2030-01-01',
                        headers=auth('alice'))
    assert future.json['messages'] == []


def test_encrypted_message_bodies_are_never_shown_as_plain_text(
        app, client, auth, make_message):
    make_admin(app)
    make_message('m1', content='Y2lwaGVydGV4dA==', is_encrypted=True)
    response = client.get('/api/v1/admin/messages', headers=auth('alice'))
    body = next(m for m in response.json['messages'] if m['id'] == 'm1')
    assert 'Y2lwaGVydGV4dA' not in body['content']


def test_an_admin_can_delete_a_message_for_everyone(app, client, auth,
                                                    make_message):
    make_admin(app)
    make_message('m1')
    response = client.delete('/api/v1/admin/messages/m1',
                             headers=auth('alice'))
    assert response.status_code == 200
    with app.app_context():
        assert db.session.get(Message, 'm1').is_deleted_for_all is True


def test_the_audit_log_is_filterable_and_lists_its_own_actions(
        app, client, auth):
    make_admin(app)
    client.post('/api/v1/admin/users/bob/ban', headers=auth('alice'))
    client.post('/api/v1/admin/users/bob/unban', headers=auth('alice'))

    actions = client.get('/api/v1/admin/audit/actions', headers=auth('alice'))
    assert 'admin_ban_user' in [a['action'] for a in actions.json['actions']]

    filtered = client.get('/api/v1/admin/audit?action=admin_ban_user',
                          headers=auth('alice'))
    assert filtered.json['total'] == 1
    assert filtered.json['logs'][0]['actor_name'] == 'Alice'

    multi = client.get(
        '/api/v1/admin/audit?action=admin_ban_user,admin_unban_user',
        headers=auth('alice'))
    assert multi.json['total'] == 2

    by_entity = client.get('/api/v1/admin/audit?entity_id=bob',
                           headers=auth('alice'))
    assert by_entity.json['total'] == 2


def test_the_support_inbox_lists_tickets_with_status_filters(app, client, auth):
    make_admin(app)
    client.post('/api/v1/support/tickets', json={
        'mobile_number': '09121234567', 'topic': 'code_not_received',
        'message': 'کد نمی‌آید'})

    inbox = client.get('/api/v1/admin/support/tickets', headers=auth('alice'))
    assert inbox.status_code == 200
    assert inbox.json['total'] == 1
    assert inbox.json['counts']['open'] == 1
    ticket_id = inbox.json['tickets'][0]['id']
    # Admins do get the contact details they need to answer.
    assert inbox.json['tickets'][0]['mobile_number'] == '+989121234567'

    updated = client.post(f'/api/v1/admin/support/tickets/{ticket_id}',
                          headers=auth('alice'),
                          json={'status': 'resolved',
                                'admin_note': 'شماره اشتباه بود'})
    assert updated.status_code == 200
    assert updated.json['ticket']['status'] == 'resolved'

    open_only = client.get('/api/v1/admin/support/tickets?status=open',
                           headers=auth('alice'))
    assert open_only.json['total'] == 0
    by_topic = client.get(
        '/api/v1/admin/support/tickets?topic=code_not_received',
        headers=auth('alice'))
    assert by_topic.json['total'] == 1


def test_admins_can_read_the_support_chats_users_sent(app, client, auth):
    """The capability the old panel was missing entirely."""
    make_admin(app)
    chat_id = make_support_thread(app)

    threads = client.get('/api/v1/admin/support/chats', headers=auth('alice'))
    assert threads.status_code == 200
    assert threads.json['total'] == 1
    thread = threads.json['threads'][0]
    assert thread['chat_id'] == chat_id
    assert thread['user']['id'] == 'bob'
    assert thread['messages_from_user'] == 1
    assert 'کد ورود' in thread['last_message']['content']

    messages = client.get(f'/api/v1/admin/support/chats/{chat_id}/messages',
                          headers=auth('alice'))
    assert messages.status_code == 200
    assert messages.json['messages'][0]['sender_name'] == 'Bob'


def test_an_admin_can_reply_inside_a_support_thread(app, client, auth):
    make_admin(app)
    chat_id = make_support_thread(app)
    reply = client.post(f'/api/v1/admin/support/chats/{chat_id}/reply',
                        headers=auth('alice'),
                        json={'content': 'شماره شما بررسی شد.'})
    assert reply.status_code == 201
    with app.app_context():
        # The reply is a real message in the user's thread, and the admin is
        # now a member so normal permission checks keep working.
        assert Message.query.filter_by(
            chat_id=chat_id, sender_id='alice').count() == 1
        assert ChatMember.query.filter_by(
            chat_id=chat_id, user_id='alice', is_deleted=False).count() == 1
    empty = client.post(f'/api/v1/admin/support/chats/{chat_id}/reply',
                        headers=auth('alice'), json={'content': '  '})
    assert empty.status_code == 400


def test_media_and_devices_are_listable_with_filters(app, client, auth, upload):
    make_admin(app)
    upload('bob')
    with app.app_context():
        db.session.add(UserDevice(
            id='dev-1', user_id='bob', device_fingerprint='fp-1',
            device_name='Bob Phone', is_primary=True))
        db.session.commit()

    media = client.get('/api/v1/admin/media?media_type=image',
                       headers=auth('alice'))
    assert media.status_code == 200
    assert media.json['total'] == 1
    assert media.json['media'][0]['uploader_name'] == 'Bob'

    devices = client.get('/api/v1/admin/devices?is_primary=true',
                         headers=auth('alice'))
    assert devices.json['total'] == 1
    assert devices.json['devices'][0]['device_name'] == 'Bob Phone'


def test_install_wide_security_alerts_are_visible_to_admins(app, client, auth):
    make_admin(app)
    from app.services.security_alerts import record_alert
    with app.app_context():
        record_alert('bob', 'new_device_login', 'ورود جدید',
                     severity='critical')
        db.session.commit()
    response = client.get('/api/v1/admin/security/alerts?severity=critical',
                          headers=auth('alice'))
    assert response.status_code == 200
    assert response.json['total'] == 1
    assert response.json['alerts'][0]['user_name'] == 'Bob'


def test_list_endpoints_reject_nonsense_paging_without_crashing(app, client,
                                                                auth):
    make_admin(app)
    response = client.get('/api/v1/admin/users?page=abc&per_page=99999',
                          headers=auth('alice'))
    assert response.status_code == 200
    assert response.json['page'] == 1
    assert response.json['per_page'] <= 200
