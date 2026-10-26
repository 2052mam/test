"""Point 3: in-app code delivery and instant login alerts."""
import re
from datetime import datetime, timedelta

from app import db
from app.models.chat import Chat, ChatMember
from app.models.message import Message
from app.models.support import SecurityAlert
from app.models.user import PhoneVerification, User, UserDevice, UserSession

from tests.test_primary_device import bootstrap, device, latest_code


def in_app_codes(app):
    with app.app_context():
        messages = Message.query.filter(
            Message.content.like('%کد ورود شما%'),
        ).order_by(Message.created_at.asc()).all()
        return [re.search(r'کد ورود شما: (\d{6})', m.content).group(1)
                for m in messages]


def test_registration_always_uses_sms(app, client):
    """A brand-new account has nowhere in-app to deliver to."""
    delivered, _first = bootstrap(app, client)
    assert len(delivered) == 1
    assert in_app_codes(app) == []


def test_a_signed_in_account_receives_its_login_code_in_the_app(app, client):
    delivered, _first = bootstrap(app, client)
    sms_before = len(delivered)

    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
        'device_info': device('second-phone'),
    })
    assert requested.status_code == 202
    assert requested.json['delivery_channel'] == 'in_app'
    assert requested.json['sent_in_app'] is True
    # No SMS credit was spent.
    assert len(delivered) == sms_before
    codes = in_app_codes(app)
    assert len(codes) == 1

    # And the in-app code really works.
    verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': requested.json['verification_id'],
        'code': codes[-1],
        'device_info': device('second-phone'),
    })
    assert verified.status_code == 200


def test_the_in_app_message_warns_and_names_the_requesting_device(app, client):
    bootstrap(app, client)
    client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
        'device_info': device('attacker-phone'),
    })
    with app.app_context():
        message = Message.query.filter(
            Message.content.like('%کد ورود شما%')).first()
    assert 'attacker-phone' in message.content
    assert 'در میان نگذارید' in message.content


def test_sms_is_used_when_no_live_session_exists(app, client):
    delivered, _first = bootstrap(app, client)
    with app.app_context():
        # Simulate the only phone being logged out / long dormant.
        UserSession.query.update({'is_active': False},
                                 synchronize_session=False)
        db.session.commit()
    sms_before = len(delivered)

    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
    })
    assert requested.status_code == 202
    assert requested.json['delivery_channel'] == 'sms'
    assert len(delivered) == sms_before + 1


def test_a_long_dormant_device_does_not_swallow_the_code(app, client):
    delivered, _first = bootstrap(app, client)
    with app.app_context():
        UserDevice.query.update(
            {'last_active': datetime.utcnow() - timedelta(days=60)},
            synchronize_session=False)
        db.session.commit()
    sms_before = len(delivered)
    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
    })
    assert requested.json['delivery_channel'] == 'sms'
    assert len(delivered) == sms_before + 1


def test_the_user_can_force_sms_when_the_other_device_is_unreachable(app, client):
    """In-app delivery must never become a lockout."""
    # This flow legitimately issues several codes in a row; the hourly cap is
    # not what is under test here.
    app.config['PHONE_CODE_MAX_PER_HOUR'] = 20
    app.config['PHONE_CODE_MAX_PER_IP_HOUR'] = 50
    # The 60s anti-flood cooldown still applies to a forced resend (that is
    # intended); it is simply not what this test is about.
    app.config['PHONE_CODE_RESEND_SECONDS'] = 0
    delivered, _first = bootstrap(app, client)
    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
    })
    assert requested.json['delivery_channel'] == 'in_app'
    sms_before = len(delivered)

    resent = client.post('/api/v1/auth/resend-phone-code', json={
        'verification_id': requested.json['verification_id'],
        'force_sms': True,
    })
    assert resent.status_code == 202
    assert resent.json['delivery_channel'] == 'sms'
    assert len(delivered) == sms_before + 1


def test_requesting_a_code_immediately_raises_an_alert(app, client):
    delivered, first = bootstrap(app, client)
    headers = {'Authorization': f"Bearer {first.json['access_token']}"}

    client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
        'device_info': device('unknown-phone'),
    })
    feed = client.get('/api/v1/security/alerts', headers=headers)
    assert feed.status_code == 200
    kinds = [a['alert_type'] for a in feed.json['alerts']]
    assert 'login_code_requested' in kinds
    assert feed.json['unread'] >= 1


def test_a_completed_new_device_login_raises_a_critical_alert(app, client):
    delivered, first = bootstrap(app, client)
    headers = {'Authorization': f"Bearer {first.json['access_token']}"}
    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
        'device_info': device('second-phone'),
    })
    client.post('/api/v1/auth/verify-phone', json={
        'verification_id': requested.json['verification_id'],
        'code': latest_code(app, delivered),
        'device_info': device('second-phone'),
    })
    feed = client.get('/api/v1/security/alerts', headers=headers)
    alert = next(a for a in feed.json['alerts']
                 if a['alert_type'] == 'new_device_login')
    assert alert['severity'] == 'critical'
    assert 'second-phone' in (alert['body'] or '')


def test_repeated_code_requests_do_not_spam_the_alert_feed(app, client):
    delivered, first = bootstrap(app, client)
    headers = {'Authorization': f"Bearer {first.json['access_token']}"}
    for _ in range(3):
        client.post('/api/v1/auth/request-phone-code', json={
            'mobile_number': '09121234567',
        })
    feed = client.get('/api/v1/security/alerts', headers=headers)
    requested = [a for a in feed.json['alerts']
                 if a['alert_type'] == 'login_code_requested']
    assert len(requested) == 1


def test_alerts_can_be_read_and_dismissed(app, client):
    delivered, first = bootstrap(app, client)
    headers = {'Authorization': f"Bearer {first.json['access_token']}"}
    client.post('/api/v1/auth/request-phone-code',
                json={'mobile_number': '09121234567'})

    feed = client.get('/api/v1/security/alerts', headers=headers)
    total = len(feed.json['alerts'])
    assert feed.json['unread'] == total
    alert_id = feed.json['alerts'][0]['id']

    assert client.post(f'/api/v1/security/alerts/{alert_id}/read',
                       headers=headers).status_code == 200
    after_read = client.get('/api/v1/security/alerts', headers=headers)
    # Reading one alert clears exactly one; the rest stay unread.
    assert after_read.json['unread'] == total - 1
    # A read alert is still listed until it is dismissed.
    assert len(after_read.json['alerts']) == total

    assert client.post('/api/v1/security/alerts/read-all',
                       headers=headers).status_code == 200
    assert client.get('/api/v1/security/alerts',
                      headers=headers).json['unread'] == 0

    assert client.post(f'/api/v1/security/alerts/{alert_id}/dismiss',
                       headers=headers).status_code == 200
    after_dismiss = client.get('/api/v1/security/alerts', headers=headers)
    assert len(after_dismiss.json['alerts']) == total - 1
    assert alert_id not in [a['id'] for a in after_dismiss.json['alerts']]


def test_alerts_are_private_to_their_owner(app, client, auth):
    delivered, first = bootstrap(app, client)
    client.post('/api/v1/auth/request-phone-code',
                json={'mobile_number': '09121234567'})
    other = client.get('/api/v1/security/alerts', headers=auth('bob'))
    assert other.status_code == 200
    assert other.json['alerts'] == []


def test_enabling_and_disabling_two_factor_is_alerted(app, client):
    import pyotp

    delivered, first = bootstrap(app, client)
    headers = {'Authorization': f"Bearer {first.json['access_token']}"}
    secret = client.post('/api/v1/auth/2fa/setup', headers=headers,
                         json={}).json['totp_secret']
    client.post('/api/v1/auth/2fa/enable', headers=headers,
                json={'code': pyotp.TOTP(secret).now()})
    client.post('/api/v1/auth/2fa/disable', headers=headers,
                json={'code': pyotp.TOTP(secret).now()})

    feed = client.get('/api/v1/security/alerts', headers=headers)
    kinds = [a['alert_type'] for a in feed.json['alerts']]
    assert 'two_factor_enabled' in kinds
    assert 'two_factor_disabled' in kinds
    critical = next(a for a in feed.json['alerts']
                    if a['alert_type'] == 'two_factor_disabled')
    assert critical['severity'] == 'critical'
