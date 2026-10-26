"""Point 4: the first device to sign in owns the account.

No other device may remove it, and only it may enable two-step verification or
lock the archive — otherwise whoever logs in second could fence the real owner
out of their own account.
"""
import re

import pyotp
from flask_jwt_extended import create_access_token

from app import db
from app.models.message import Message
from app.models.user import PhoneVerification, User, UserDevice


def device(device_id):
    return {
        'device_id': device_id,
        'model': 'Test Phone',
        'os': 'Android',
        'device_name': device_id,
    }


def register(client, mobile='09121234567'):
    return client.post('/api/v1/auth/register', json={
        'email': 'owner@example.test',
        'password': 'Password-123!',
        'display_name': 'Owner',
        'mobile_number': mobile,
        'username': 'owner',
        'terms_accepted': True,
        'terms_version': 1,
        'device_info': device('first-phone'),
    })


def latest_code(app, delivered):
    with app.app_context():
        message = Message.query.filter(
            Message.content.like('%کد ورود شما%'),
        ).order_by(Message.created_at.desc()).first()
        challenge = PhoneVerification.query.order_by(
            PhoneVerification.created_at.desc()).first()
        if message and challenge and message.created_at >= challenge.created_at:
            match = re.search(r'کد ورود شما: (\d{6})', message.content or '')
            if match:
                return match.group(1)
    return delivered[-1][1]


def sign_in(app, client, delivered, device_id):
    """Complete a phone login on `device_id` and return its access token."""
    requested = client.post('/api/v1/auth/request-phone-code', json={
        'mobile_number': '09121234567',
        'device_info': device(device_id),
    })
    assert requested.status_code == 202
    verified = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': requested.json['verification_id'],
        'code': latest_code(app, delivered),
        'device_info': device(device_id),
    })
    assert verified.status_code == 200, verified.json
    return verified


def bootstrap(app, client):
    """Register + verify, leaving the first device signed in as primary."""
    delivered = []
    app.config['SMS_SENDER'] = lambda mobile, code: delivered.append((mobile, code))
    registration = register(client)
    assert registration.status_code == 201
    first = client.post('/api/v1/auth/verify-phone', json={
        'verification_id': registration.json['verification_id'],
        'code': delivered[-1][1],
        'device_info': device('first-phone'),
    })
    assert first.status_code == 200
    return delivered, first


def test_first_device_becomes_primary_and_later_logins_do_not(app, client):
    delivered, first = bootstrap(app, client)
    assert first.json['is_primary_device'] is True
    assert first.json['became_primary'] is True

    second = sign_in(app, client, delivered, 'second-phone')
    assert second.json['is_primary_device'] is False
    assert second.json['became_primary'] is False

    with app.app_context():
        primaries = UserDevice.query.filter_by(
            is_primary=True, is_deleted=False).all()
        assert len(primaries) == 1
        assert primaries[0].device_name == 'first-phone'


def test_a_secondary_device_cannot_remove_the_primary_device(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')

    second_headers = {'Authorization': f"Bearer {second.json['access_token']}"}
    listed = client.get('/api/v1/devices/', headers=second_headers)
    assert listed.status_code == 200
    primary = next(d for d in listed.json['devices'] if d['is_primary'])
    assert primary['can_terminate'] is False

    denied = client.post(
        f"/api/v1/devices/{primary['id']}/terminate", headers=second_headers)
    assert denied.status_code == 403
    assert denied.json['code'] == 'cannot_terminate_primary'

    # And it must still be there, still usable.
    with app.app_context():
        owner = UserDevice.query.filter_by(is_primary=True).first()
        assert owner.is_deleted is False


def test_terminate_others_from_a_secondary_device_spares_the_primary(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')
    second_headers = {'Authorization': f"Bearer {second.json['access_token']}"}

    swept = client.post('/api/v1/devices/terminate-others',
                        headers=second_headers, json={})
    assert swept.status_code == 200
    assert swept.json['skipped_primary'] is True
    with app.app_context():
        owner = UserDevice.query.filter_by(is_primary=True).first()
        assert owner.is_deleted is False


def test_the_primary_device_may_remove_itself_and_hand_over_ownership(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')
    first_headers = {'Authorization': f"Bearer {first.json['access_token']}"}

    transferred = client.post(
        '/api/v1/devices/primary/transfer', headers=first_headers,
        json={'device_id': second.json['device_id']})
    assert transferred.status_code == 200
    assert transferred.json['primary_device_id'] == second.json['device_id']

    with app.app_context():
        primaries = UserDevice.query.filter_by(
            is_primary=True, is_deleted=False).all()
        assert len(primaries) == 1
        assert primaries[0].id == second.json['device_id']


def test_only_the_primary_device_may_transfer_ownership(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')
    second_headers = {'Authorization': f"Bearer {second.json['access_token']}"}

    denied = client.post(
        '/api/v1/devices/primary/transfer', headers=second_headers,
        json={'device_id': second.json['device_id']})
    assert denied.status_code == 403
    assert denied.json['code'] == 'primary_device_required'


def test_only_the_primary_device_may_enable_two_factor(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')
    second_headers = {'Authorization': f"Bearer {second.json['access_token']}"}
    first_headers = {'Authorization': f"Bearer {first.json['access_token']}"}

    denied = client.post('/api/v1/auth/2fa/setup',
                         headers=second_headers, json={})
    assert denied.status_code == 403
    assert denied.json['code'] == 'primary_device_required'

    allowed = client.post('/api/v1/auth/2fa/setup',
                          headers=first_headers, json={})
    assert allowed.status_code == 200
    secret = allowed.json['totp_secret']

    # Even holding a valid secret, the secondary device cannot switch it on.
    blocked = client.post('/api/v1/auth/2fa/enable', headers=second_headers,
                          json={'code': pyotp.TOTP(secret).now()})
    assert blocked.status_code == 403

    enabled = client.post('/api/v1/auth/2fa/enable', headers=first_headers,
                          json={'code': pyotp.TOTP(secret).now()})
    assert enabled.status_code == 200
    assert enabled.json['user']['is_2fa_enabled'] is True


def test_only_the_primary_device_may_lock_the_archive(app, client):
    delivered, first = bootstrap(app, client)
    second = sign_in(app, client, delivered, 'second-phone')
    second_headers = {'Authorization': f"Bearer {second.json['access_token']}"}
    first_headers = {'Authorization': f"Bearer {first.json['access_token']}"}

    denied = client.post('/api/v1/users/me/archive-pin',
                         headers=second_headers, json={'pin': '1234'})
    assert denied.status_code == 403
    assert denied.json['code'] == 'primary_device_required'

    allowed = client.post('/api/v1/users/me/archive-pin',
                          headers=first_headers, json={'pin': '1234'})
    assert allowed.status_code == 200
    assert allowed.json['has_archive_pin'] is True

    # Removing it is equally restricted.
    blocked = client.post('/api/v1/users/me/archive-pin/remove',
                          headers=second_headers, json={'pin': '1234'})
    assert blocked.status_code == 403


def test_a_legacy_token_without_a_device_claim_is_not_treated_as_primary(app, client):
    """An old token must not become a bypass for the primary-device rule."""
    bootstrap(app, client)
    with app.app_context():
        user = User.query.filter_by(email='owner@example.test').one()
        legacy = create_access_token(identity=user.id)
    denied = client.post('/api/v1/auth/2fa/setup',
                         headers={'Authorization': f'Bearer {legacy}'},
                         json={})
    assert denied.status_code == 403


def test_accounts_without_any_primary_device_are_not_locked_out(app, client, auth):
    """Pre-existing accounts keep working until a primary device is recorded."""
    with app.app_context():
        assert UserDevice.query.filter_by(user_id='alice').count() == 0
    response = client.post('/api/v1/users/me/archive-pin',
                           headers=auth('alice'), json={'pin': '4321'})
    assert response.status_code == 200
