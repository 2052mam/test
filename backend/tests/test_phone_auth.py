from datetime import datetime, timedelta
import re

import pyotp

from app import db
from app.models.message import Message
from app.models.user import PhoneVerification, User


def latest_code(app, delivered):
    """The most recent code, whichever channel actually carried it.

    Like Telegram, an account that still has a live session receives its login
    code *inside the app* (Saved Messages) instead of by SMS, so a test can no
    longer assume the SMS sender saw it.
    """
    with app.app_context():
        message = Message.query.filter(
            Message.content.like('%کد ورود شما%'),
        ).order_by(Message.created_at.desc()).first()
        in_app_code = None
        if message:
            match = re.search(r'کد ورود شما: (\d{6})', message.content or '')
            if match:
                in_app_code = (match.group(1), message.created_at)
    if in_app_code and not delivered:
        return in_app_code[0]
    if in_app_code:
        # Both channels have been used at some point; the in-app copy is only
        # newer when the most recent request was delivered in-app.
        with app.app_context():
            challenge = PhoneVerification.query.order_by(
                PhoneVerification.created_at.desc()).first()
        if challenge is not None and in_app_code[1] >= challenge.created_at:
            return in_app_code[0]
    return delivered[-1][1]


def device(device_id='phone-test-device'):
    return {
        'device_id': device_id,
        'model': 'Test Phone',
        'os': 'Android',
        'device_name': 'Test Phone',
    }


def register(client, mobile='09121234567', **extra):
    body = {
        'email': 'phone-user@example.test',
        'password': 'Password-123!',
        'display_name': 'Phone User',
        'mobile_number': mobile,
        'username': 'phone_user',
        'terms_accepted': True,
        'terms_version': 1,
        'device_info': device(),
    }
    body.update(extra)
    return client.post('/api/v1/auth/register', json=body)


def test_registration_requires_a_phone_and_never_returns_a_totp_secret(client):
    response = register(client, mobile='not a phone')
    assert response.status_code == 400
    assert 'totp_secret' not in response.json


def test_phone_registration_sends_code_activates_account_and_creates_session(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))

    response = register(client)
    assert response.status_code == 201
    assert set(response.json).isdisjoint({'totp_secret', 'totp_uri'})
    assert response.json['mobile_number'].startswith('+989')
    assert len(delivered) == 1
    assert delivered[0][0] == '+989121234567'

    with app.app_context():
        user = User.query.filter_by(email='phone-user@example.test').one()
        assert user.is_active is False
        assert user.mobile_number == '+989121234567'
        assert user.mobile_verified_at is None
        assert user.is_2fa_enabled is False
        assert PhoneVerification.query.filter_by(user_id=user.id).count() == 1

    verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': response.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })
    assert verified.status_code == 200
    assert verified.json['access_token']
    assert verified.json['refresh_token']
    assert verified.json['user']['mobile_number'] == '+989121234567'
    assert verified.json['user']['is_2fa_enabled'] is False

    with app.app_context():
        user = User.query.filter_by(email='phone-user@example.test').one()
        challenge = db.session.get(PhoneVerification, response.json['verification_id'])
        assert user.is_active is True
        assert user.mobile_verified_at is not None
        assert challenge.consumed_at is not None
        assert delivered[-1][1] not in challenge.code_hash


def test_phone_login_is_primary_and_unknown_numbers_go_to_registration(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    registration = register(client)
    verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': registration.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })
    assert verified.status_code == 200

    known = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '+989121234567',
    })
    unknown = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '+989121234568',
    })
    assert known.status_code == 202
    assert known.json['registration_required'] is False
    # Telegram parity: this account already has a live session, so the code is
    # delivered inside the app and costs no SMS.
    assert known.json['delivery_channel'] == 'in_app'
    assert known.json['sent_in_app'] is True
    # An unregistered number is never sent a code; it must register first.
    assert unknown.status_code == 200
    assert unknown.json['registration_required'] is True
    assert 'verification_id' not in unknown.json
    # Neither the unknown number nor the in-app login consumed an SMS.
    assert len(delivered) == 1

    signed_in = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': known.json['verification_id'],
        'code': latest_code(app, delivered),
        'device_info': device('second-device'),
    })
    assert signed_in.status_code == 200
    assert signed_in.json['user']['id'] == verified.json['user']['id']

    fake = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': 'not-a-real-challenge',
        'code': '000000',
        'device_info': device(),
    })
    assert fake.status_code == 401


def test_check_phone_tells_the_login_screen_to_open_registration(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    registration = register(client)
    client.post('/api/v1/auth/verify-phone', json={
        'verification_id': registration.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })

    existing = client.post('/api/v1/auth/check-phone', json={
        'mobile_number': '09121234567',
    })
    assert existing.status_code == 200
    assert existing.json['registered'] is True
    assert existing.json['registration_required'] is False

    fresh = client.post('/api/v1/auth/check-phone', json={
        'mobile_number': '09129999999',
    })
    assert fresh.status_code == 200
    assert fresh.json['registration_required'] is True
    # Checking a number must never trigger an SMS.
    assert len(delivered) == 1

    assert client.post('/api/v1/auth/check-phone', json={
        'mobile_number': 'not-a-number',
    }).status_code == 400


def test_unverified_registration_still_requires_registration_to_login(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    assert register(client).status_code == 201  # never verified
    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
    })
    assert requested.status_code == 200
    assert requested.json['registration_required'] is True
    assert len(delivered) == 1


def test_resend_invalidates_the_previous_sms_code(app, client):
    delivered = []
    app.config.update(
        SMS_SENDER=lambda mobile, code: delivered.append((mobile, code)),
        PHONE_CODE_RESEND_SECONDS=0,
    )
    first = register(client)
    assert first.status_code == 201
    first_code = delivered[-1][1]
    second = client.post('/api/v1/auth/resend-phone-code', json={
        'verification_id': first.json['verification_id'],
    })
    assert second.status_code == 202
    assert second.json['verification_id'] != first.json['verification_id']

    stale = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': first.json['verification_id'],
        'code': first_code,
        'device_info': device(),
    })
    assert stale.status_code == 401
    current = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': second.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })
    assert current.status_code == 200


def test_optional_google_authenticator_follows_sms_verification(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    registration = register(client)
    first_login = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': registration.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })
    assert first_login.status_code == 200
    headers = {'Authorization': f"Bearer {first_login.json['access_token']}"}

    setup = client.post('/api/v1/auth/2fa/setup', headers=headers, json={})
    assert setup.status_code == 200
    secret = setup.json['totp_secret']
    assert setup.json['totp_uri'].startswith('otpauth://totp/')

    enabled = client.post('/api/v1/auth/2fa/enable', headers=headers, json={
        'code': pyotp.TOTP(secret).now(),
    })
    assert enabled.status_code == 200
    assert enabled.json['user']['is_2fa_enabled'] is True

    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
    })
    assert requested.status_code == 202
    sms_verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': requested.json['verification_id'],
        'code': latest_code(app, delivered),
        'device_info': device('two-factor-device'),
    })
    assert sms_verified.status_code == 200
    assert sms_verified.json == {
        'require_2fa': True,
        'verification_id': requested.json['verification_id'],
        'message': 'کد Google Authenticator را وارد کنید.',
    }

    completed = client.post('/api/v1/auth/verify-login-2fa', json={
        'verification_id': requested.json['verification_id'],
        'code': pyotp.TOTP(secret).now(),
        'device_info': device('two-factor-device'),
    })
    assert completed.status_code == 200
    assert completed.json['access_token']

    reused = client.post('/api/v1/auth/verify-login-2fa', json={
        'verification_id': requested.json['verification_id'],
        'code': pyotp.TOTP(secret).now(),
        'device_info': device('two-factor-device'),
    })
    assert reused.status_code == 401


def test_codes_expire_and_old_email_login_still_works(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    response = register(client)
    with app.app_context():
        challenge = db.session.get(PhoneVerification, response.json['verification_id'])
        challenge.expires_at = datetime.utcnow() - timedelta(seconds=1)
        db.session.commit()
    expired = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': response.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device(),
    })
    assert expired.status_code == 410

    with app.app_context():
        legacy = User(
            id='legacy-phone-auth',
            email='legacy@example.test',
            username='legacy_phone_auth',
            display_name='Legacy',
            totp_secret='JBSWY3DPEHPK3PXP',
            is_2fa_enabled=True,
        )
        legacy.set_password('LegacyPass-123!')
        db.session.add(legacy)
        db.session.commit()
        code = pyotp.TOTP(legacy.totp_secret).now()
    old_login = client.post('/api/v1/auth/login', json={
        'email': 'legacy@example.test',
        'password': 'LegacyPass-123!',
        'totp_code': code,
        'device_info': device('legacy-device'),
    })
    assert old_login.status_code == 200
    assert old_login.json['user']['id'] == 'legacy-phone-auth'


def test_resend_rate_limit_and_totp_setup_requires_a_session(app, client):
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    response = register(client)
    too_soon = client.post('/api/v1/auth/resend-phone-code', json={
        'verification_id': response.json['verification_id'],
    })
    assert too_soon.status_code == 429
    assert client.post('/api/v1/auth/2fa/setup', json={}).status_code in {401, 422}


def test_authenticator_registration_is_private_and_activates_only_after_totp(app, client):
    from app.services import app_settings

    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    with app.app_context():
        app_settings.save_auth_methods(
            registration_method='totp', login_priority='totp')

    registration = register(client, email='totp-register@example.test',
                            username='totp_register')
    assert registration.status_code == 201
    assert registration.json['verification_method'] == 'totp'
    assert registration.json['totp_secret']
    assert registration.json['totp_uri'].startswith('otpauth://totp/')
    assert not delivered
    with app.app_context():
        user = User.query.filter_by(email='totp-register@example.test').one()
        assert user.is_active is False
        assert user.mobile_verified_at is None
        assert user.is_2fa_enabled is False

    verified = client.post('/api/v1/auth/verify-totp-registration', json={
        'verification_id': registration.json['verification_id'],
        'code': pyotp.TOTP(registration.json['totp_secret']).now(),
        'device_info': device('totp-registration-device'),
    })
    assert verified.status_code == 200
    assert verified.json['access_token']
    with app.app_context():
        user = User.query.filter_by(email='totp-register@example.test').one()
        challenge = db.session.get(PhoneVerification,
                                  registration.json['verification_id'])
        assert user.is_active is True
        assert user.is_2fa_enabled is True
        # TOTP proves authenticator possession, never ownership of the phone.
        assert user.mobile_verified_at is None
        assert challenge.consumed_at is not None

    login = client.post('/api/v1/auth/login', json={
        'email': 'totp-register@example.test',
        'password': 'Password-123!',
        'totp_code': pyotp.TOTP(registration.json['totp_secret']).now(),
        'device_info': device('totp-password-login'),
    })
    assert login.status_code == 200


def test_totp_priority_keeps_sms_fallback_for_users_without_totp(app, client):
    from app.services import app_settings

    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    with app.app_context():
        app_settings.save_auth_methods(
            registration_method='sms', login_priority='totp')
        user = User(
            id='sms-fallback-user', email='sms-fallback@example.test',
            username='sms_fallback', display_name='SMS fallback',
            mobile_number='+989121234567', mobile_verified_at=datetime.utcnow(),
            totp_secret=pyotp.random_base32(), is_2fa_enabled=False,
        )
        user.set_password('Password-123!')
        db.session.add(user)
        db.session.commit()

    password_login = client.post('/api/v1/auth/login', json={
        'email': 'sms-fallback@example.test', 'password': 'Password-123!',
        'device_info': device('sms-fallback-device'),
    })
    assert password_login.status_code == 400
    assert password_login.json['require_phone'] is True

    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '+989121234567',
    })
    assert requested.status_code == 202
    assert delivered
    verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': requested.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device('sms-fallback-device'),
    })
    assert verified.status_code == 200
    assert verified.json['access_token']


def test_totp_registration_owner_can_verify_phone_for_sms_recovery(app, client):
    from app.services import app_settings

    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    with app.app_context():
        app_settings.save_auth_methods(
            registration_method='totp', login_priority='totp')
    registration = register(client, email='totp-recovery@example.test',
                            username='totp_recovery')
    signed_in = client.post('/api/v1/auth/verify-totp-registration', json={
        'verification_id': registration.json['verification_id'],
        'code': pyotp.TOTP(registration.json['totp_secret']).now(),
        'device_info': device('totp-recovery-device'),
    })
    headers = {'Authorization': f"Bearer {signed_in.json['access_token']}"}

    # Recovery actions require the account owner's authenticated session.
    assert client.post('/api/v1/auth/request-phone-recovery-code').status_code in {401, 422}
    sent = client.post('/api/v1/auth/request-phone-recovery-code',
                       headers=headers, json={})
    assert sent.status_code == 202
    assert sent.json['mobile_number'].startswith('+989')
    assert delivered
    verified = client.post('/api/v1/auth/verify-phone-recovery',
                           headers=headers, json={
        'verification_id': sent.json['verification_id'],
        'code': delivered[-1][1],
    })
    assert verified.status_code == 200
    with app.app_context():
        user = User.query.filter_by(email='totp-recovery@example.test').one()
        assert user.mobile_verified_at is not None

    # Once verified, SMS is a user-controlled fallback if the authenticator is
    # unavailable; the login response never includes the code or secret.
    login_code = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '+989121234567',
    })
    assert login_code.status_code == 202
    fallback = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': login_code.json['verification_id'],
        'code': latest_code(app, delivered),
        'device_info': device('totp-sms-fallback'),
    })
    assert fallback.status_code == 200
    assert fallback.json['access_token']
    assert 'totp_secret' not in fallback.json


def test_auth_methods_endpoint_exposes_policy_but_no_secrets(app, client):
    from app.services import app_settings

    with app.app_context():
        app_settings.save_auth_methods(
            registration_method='totp', login_priority='totp')
    response = client.get('/api/v1/auth/methods')
    assert response.status_code == 200
    assert response.json == {
        'registration_method': 'totp', 'login_priority': 'totp',
    }
    assert 'secret' not in response.get_data(as_text=True).lower()
