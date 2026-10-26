"""Authentication and phone-verification endpoints.

A mobile number is the primary sign-in identifier for accounts created after
this update.  SMS codes are generated and verified only by the backend; the
Flutter client neither embeds SMS.ir credentials nor receives a raw code.
"""
from __future__ import annotations

from datetime import datetime, timedelta
import hashlib
import hmac
import re
import secrets
import uuid

from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import (
    create_access_token,
    create_refresh_token,
    get_jwt,
    get_jwt_identity,
    jwt_required,
)
from sqlalchemy import func

from app import db
from app.models.audit import AuditLog
from app.models.user import PhoneVerification, User, UserDevice, UserSession
from app.services.code_delivery import (
    DELIVERY_IN_APP,
    DELIVERY_SMS,
    choose_delivery_channel,
    deliver_code_in_app,
)
from app.services.security_alerts import (
    ensure_primary_device,
    is_primary_device,
    PRIMARY_REQUIRED_MESSAGE,
    record_alert,
)
from app.services.sms_ir import SmsDeliveryError, send_verification_code


auth_bp = Blueprint('auth', __name__)

PHONE_CODE_PURPOSE_REGISTER = 'registration'
PHONE_CODE_PURPOSE_LOGIN = 'login'
PHONE_CODE_LENGTH = 6


class AuthFlowError(Exception):
    def __init__(self, message: str, status_code: int = 400, **payload):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.payload = payload


def _error(error: AuthFlowError):
    return jsonify({'error': error.message, **error.payload}), error.status_code


def get_client_ip() -> str | None:
    # A trusted reverse proxy may append an X-Forwarded-For chain.  The first
    # address is the originating client, and avoids overflowing the DB column.
    forwarded = request.headers.get('X-Forwarded-For')
    return (forwarded.split(',')[0].strip() if forwarded else request.remote_addr)


def _as_device_info(value) -> dict:
    return value if isinstance(value, dict) else {}


def create_device_fingerprint(data: dict) -> str:
    raw = f"{data.get('device_id', '')}-{data.get('model', '')}-{data.get('os', '')}-{data.get('mac', '')}"
    return hashlib.sha256(raw.encode()).hexdigest()


def normalize_mobile_number(value) -> str | None:
    """Normalize common local and international input to E.164.

    SMS.ir is commonly used with Iranian mobile numbers, so the familiar
    ``09xxxxxxxxx`` and ``9xxxxxxxxx`` forms are normalized to ``+98…``. Any
    other valid E.164 mobile number is retained, which keeps the app's account
    model country-code ready if the configured provider supports it.
    """
    if not isinstance(value, str):
        return None
    compact = re.sub(r'[\s()\-.]', '', value)
    if compact.startswith('00'):
        compact = '+' + compact[2:]
    if re.fullmatch(r'09\d{9}', compact):
        compact = '+98' + compact[1:]
    elif re.fullmatch(r'9\d{9}', compact):
        compact = '+98' + compact
    elif re.fullmatch(r'98\d{10}', compact):
        compact = '+' + compact
    if not re.fullmatch(r'\+[1-9]\d{7,14}', compact):
        return None
    return compact


def _mask_mobile(mobile_number: str) -> str:
    if len(mobile_number) <= 6:
        return mobile_number
    return f'{mobile_number[:4]}••••{mobile_number[-3:]}'


def _code_digest(challenge_id: str, code: str) -> str:
    # A plain SHA-256 of a 6-digit code is brute-forceable.  Keying the digest
    # with the server secret means a leaked database cannot validate guesses.
    secret = current_app.config['SECRET_KEY'].encode('utf-8')
    message = f'phone-code:{challenge_id}:{code}'.encode('utf-8')
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def _new_code() -> str:
    return f'{secrets.randbelow(10 ** PHONE_CODE_LENGTH):0{PHONE_CODE_LENGTH}d}'


def _challenge_or_error(
    challenge_id: object, *, allow_expired: bool = False,
) -> PhoneVerification:
    if not isinstance(challenge_id, str):
        raise AuthFlowError('درخواست تأیید نامعتبر است', 400)
    challenge = db.session.get(PhoneVerification, challenge_id)
    if not challenge or challenge.revoked_at or challenge.consumed_at:
        raise AuthFlowError('کد تأیید نامعتبر یا منقضی شده است', 401)
    if challenge.expires_at <= datetime.utcnow() and not allow_expired:
        raise AuthFlowError('کد تأیید منقضی شده است. دوباره درخواست کنید.', 410)
    return challenge


def _enforce_send_limit(mobile_number: str, purpose: str, ip_address: str | None) -> None:
    now = datetime.utcnow()
    hour_ago = now - timedelta(hours=1)
    recent = PhoneVerification.query.filter(
        PhoneVerification.mobile_number == mobile_number,
        PhoneVerification.created_at >= hour_ago,
    ).order_by(PhoneVerification.created_at.desc()).all()
    # A registration code must not block an immediate *login* request, but a
    # resend cannot be used to flood the same number.
    latest_same_purpose = next((item for item in recent if item.purpose == purpose), None)
    if latest_same_purpose:
        resend_after = int(current_app.config['PHONE_CODE_RESEND_SECONDS'])
        elapsed = (now - latest_same_purpose.created_at).total_seconds()
        if elapsed < resend_after:
            retry_after = max(1, resend_after - int(elapsed))
            raise AuthFlowError(
                'لطفاً پیش از درخواست دوباره کمی صبر کنید.', 429,
                retry_after_seconds=retry_after,
            )
    if len(recent) >= int(current_app.config['PHONE_CODE_MAX_PER_HOUR']):
        raise AuthFlowError('تعداد درخواست کد برای این شماره بیش از حد مجاز است.', 429)

    if ip_address:
        ip_count = PhoneVerification.query.filter(
            PhoneVerification.ip_address == ip_address,
            PhoneVerification.created_at >= hour_ago,
        ).count()
        if ip_count >= int(current_app.config['PHONE_CODE_MAX_PER_IP_HOUR']):
            raise AuthFlowError('تعداد درخواست کد از این اتصال بیش از حد مجاز است.', 429)


def _issue_phone_code(
    user: User,
    purpose: str,
    *,
    device_label: str | None = None,
    force_sms: bool = False,
) -> tuple[PhoneVerification, str]:
    """Create and deliver exactly one valid challenge for a user/purpose.

    Delivery follows Telegram: an account that still has a live, recently used
    session receives the code **inside the app** (Saved Messages, which every
    signed-in device polls) and no SMS is sent. Only when there is nowhere to
    deliver in-app — a fresh phone, a long-dormant account, registration — do
    we fall back to SMS. If in-app delivery fails for any reason we still fall
    back to SMS, so a user can never be locked out by this optimisation.

    Returns the challenge and the channel actually used ('in_app' | 'sms').
    """
    now = datetime.utcnow()
    ip_address = get_client_ip()
    _enforce_send_limit(user.mobile_number, purpose, ip_address)

    # Only the newest code can be used.  A stale SMS cannot complete a login.
    PhoneVerification.query.filter(
        PhoneVerification.user_id == user.id,
        PhoneVerification.purpose == purpose,
        PhoneVerification.consumed_at.is_(None),
        PhoneVerification.revoked_at.is_(None),
    ).update({PhoneVerification.revoked_at: now}, synchronize_session=False)

    challenge = PhoneVerification(
        id=str(uuid.uuid4()),
        user_id=user.id,
        mobile_number=user.mobile_number,
        purpose=purpose,
        code_hash='',
        expires_at=now + timedelta(seconds=int(current_app.config['PHONE_CODE_TTL_SECONDS'])),
        ip_address=ip_address,
        created_at=now,
    )
    code = _new_code()
    challenge.code_hash = _code_digest(challenge.id, code)
    db.session.add(challenge)
    db.session.flush()

    # SMS-backed registration/recovery always uses SMS. Authenticator-based
    # registration has its own flow and does not call this helper.
    channel = DELIVERY_SMS
    if purpose == PHONE_CODE_PURPOSE_LOGIN and not force_sms:
        channel = choose_delivery_channel(user.id)

    delivered_in_app = False
    if channel == DELIVERY_IN_APP:
        try:
            delivered_in_app = deliver_code_in_app(
                user, code, ip_address=ip_address, device_label=device_label,
            )
        except Exception:
            current_app.logger.exception(
                'In-app code delivery failed; falling back to SMS.')
            delivered_in_app = False
    if not delivered_in_app:
        channel = DELIVERY_SMS
        # Send before committing the challenge. If SMS.ir is unavailable, the
        # transaction rolls back and the user is never left with an unusable
        # code.
        send_verification_code(user.mobile_number, code)

    db.session.add(AuditLog(
        actor_id=user.id,
        action='phone_verification_sent',
        entity_type='phone_verification',
        entity_id=challenge.id,
        ip_address=ip_address,
        user_agent=request.headers.get('User-Agent'),
        new_value=channel,
    ))
    # Point 3: the owner must learn about a login attempt immediately, even
    # if the attempt never completes. This lands in the chat list banner on
    # the next poll.
    if purpose == PHONE_CODE_PURPOSE_LOGIN:
        record_alert(
            user.id,
            'login_code_requested',
            'درخواست کد ورود به حساب شما',
            body=(
                'کد ورود برای حساب شما درخواست شد'
                + (f' از {device_label}' if device_label else '')
                + '. اگر شما نبودید، فوراً تأیید دو مرحله‌ای را فعال کنید.'
            ),
            severity='warning',
            ip_address=ip_address,
            dedupe_seconds=60,
            # The in-app code delivery writes its own, richer chat message;
            # a second "a code was requested" post would be noise.
            post_to_chat=(channel != DELIVERY_IN_APP),
        )
    return challenge, channel


def _device_label(device_info: dict) -> str | None:
    """Short human label for the device asking for a code ("Pixel 7, Android 14")."""
    parts = [
        device_info.get('device_name'),
        device_info.get('model'),
        device_info.get('os'),
    ]
    label = '، '.join(str(p).strip() for p in parts if p and str(p).strip())
    return label or None


def _issue_phone_code_via_sms(
    user: User, purpose: str,
) -> tuple[PhoneVerification, str]:
    """Force SMS delivery.

    The verification screen offers "send by SMS instead" for the case where the
    other device is lost, off, or the user simply cannot reach it. Without this
    escape hatch, in-app delivery would be a lockout risk.
    """
    return _issue_phone_code(user, purpose, force_sms=True)


def _register_or_update_device(user: User, device_info: dict) -> tuple[UserDevice, bool]:
    """Apply the existing three-account-per-device and device-limit policy."""
    fingerprint = create_device_fingerprint(device_info)
    device = UserDevice.query.filter_by(
        user_id=user.id,
        device_fingerprint=fingerprint,
        is_deleted=False,
    ).first()
    is_new_device = False
    if device is None:
        # A terminated (soft-deleted) device that signs in again must revive
        # its own row: the (user_id, fingerprint) unique key forbids a
        # second row, and reviving keeps the audit trail intact.
        deleted = UserDevice.query.filter_by(
            user_id=user.id,
            device_fingerprint=fingerprint,
            is_deleted=True,
        ).first()
        if deleted is not None:
            deleted.is_deleted = False
            deleted.deleted_at = None
            deleted.is_active = True
            deleted.last_active = datetime.utcnow()
            deleted.device_name = device_info.get('device_name') or deleted.device_name
            deleted.device_model = device_info.get('model') or deleted.device_model
            deleted.os_version = device_info.get('os') or deleted.os_version
            deleted.app_version = device_info.get('app_version') or deleted.app_version
            deleted.user_agent = request.headers.get('User-Agent')
            return deleted, True
    if not device:
        # Preserve the product's original rule: no more than three accounts
        # may use a single stable device fingerprint.
        accounts_on_device = db.session.query(func.count(func.distinct(UserDevice.user_id))).filter(
            UserDevice.device_fingerprint == fingerprint,
            UserDevice.is_deleted == False,
        ).scalar() or 0
        if accounts_on_device >= current_app.config['MAX_ACCOUNTS_PER_DEVICE']:
            raise AuthFlowError(
                'حداکثر ۳ اکانت روی این دستگاه مجاز است. حتی بعد از حذف اپلیکیشن این محدودیت برقرار است.',
                403,
            )
        device_count = UserDevice.query.filter_by(user_id=user.id, is_deleted=False).count()
        if device_count >= current_app.config['MAX_ACCOUNTS_PER_DEVICE']:
            raise AuthFlowError('حداکثر ۳ دستگاه برای این اکانت مجاز است.', 403)
        device = UserDevice(
            user_id=user.id,
            device_fingerprint=fingerprint,
            mac_address=device_info.get('mac_address') or device_info.get('mac'),
            device_name=device_info.get('device_name'),
            device_model=device_info.get('model'),
            os_version=device_info.get('os'),
            app_version=device_info.get('app_version'),
            user_agent=request.headers.get('User-Agent'),
        )
        db.session.add(device)
        is_new_device = True
    elif device.last_active and (
        datetime.utcnow() - device.last_active
    ).total_seconds() > 30 * 24 * 3600:
        is_new_device = True
    device.last_active = datetime.utcnow()
    return device, is_new_device


def _add_new_device_warning(user: User, device: UserDevice, device_info: dict) -> None:
    """Point 7: post the new-device warning to the Security Support chat.

    Previously this went to Saved Messages, which the user complained about:
    security notices belong in their own one-way service chat, the way
    Telegram does it, not mixed into personal notes.
    """
    try:
        from app.services.security_chat import post_security_message

        ip_address = get_client_ip() or ''
        device_name = device_info.get('device_name') or device.device_name or 'دستگاه جدید'
        model = device_info.get('model') or device.device_model or ''
        warning = (
            f'⚠️ ورود جدید به حساب شما\n\nدستگاه: {device_name} ({model})\n'
            f'IP: {ip_address}\nزمان: {datetime.utcnow().strftime("%Y/%m/%d %H:%M UTC")}\n\n'
            'اگر این شما نبودید، فوراً رمز عبور خود را تغییر دهید و دستگاه‌های ناشناس را از بخش مدیریت دستگاه‌ها حذف کنید.'
        )
        post_security_message(user.id, warning)
    except Exception:
        # A notification failure must never break a successful authentication.
        current_app.logger.exception('Could not create the security-chat warning.')


def _create_authenticated_session(
    user: User,
    device_info: dict,
    *,
    audit_action: str = 'user_login',
) -> dict:
    device, is_new_device = _register_or_update_device(user, device_info)
    user.is_online = True
    user.last_seen = datetime.utcnow()
    # The device id travels inside the JWT so that terminating the device
    # revokes its tokens immediately via the blocklist loader (Item 4).
    # Flush first: a brand-new device has no id until it is persisted.
    db.session.flush()
    claims = {'device_id': device.id}
    access = create_access_token(
        identity=user.id, expires_delta=timedelta(hours=24),
        additional_claims=claims,
    )
    refresh = create_refresh_token(
        identity=user.id, expires_delta=timedelta(days=30),
        additional_claims=claims,
    )
    db.session.add(UserSession(
        user_id=user.id,
        device_id=device.id,
        refresh_token=refresh,
        ip_address=get_client_ip(),
        expires_at=datetime.utcnow() + timedelta(days=30),
    ))
    db.session.add(AuditLog(
        actor_id=user.id,
        action=audit_action,
        entity_type='user',
        entity_id=user.id,
        ip_address=get_client_ip(),
        user_agent=request.headers.get('User-Agent'),
        device_fingerprint=device.device_fingerprint,
    ))
    # Point 4: the first device ever to sign in owns the account.
    became_primary = ensure_primary_device(user.id, device)
    if is_new_device:
        _add_new_device_warning(user, device, device_info)
        # Point 3: an instant, structured alert the chat list can show on its
        # very next poll, rather than only a Saved-Messages text.
        record_alert(
            user.id,
            'new_device_login',
            'ورود جدید به حساب شما',
            # _add_new_device_warning already wrote the chat message.
            post_to_chat=False,
            body=(
                f'دستگاه: {_device_label(device_info) or device.device_name or "ناشناس"}\n'
                f'IP: {get_client_ip() or "نامشخص"}\n'
                'اگر این شما نبودید، فوراً این دستگاه را حذف کنید.'
            ),
            severity='critical',
            device=device,
            ip_address=get_client_ip(),
        )

    return {
        'access_token': access,
        'refresh_token': refresh,
        'user': user.to_dict(include_private=True),
        'new_device': is_new_device,
        'device_id': device.id,
        'is_primary_device': bool(device.is_primary),
        'became_primary': became_primary and bool(device.is_primary),
    }


def _verify_challenge_code(challenge: PhoneVerification, code: object) -> None:
    if not isinstance(code, str) or not re.fullmatch(r'\d{6}', code):
        raise AuthFlowError('کد ۶ رقمی نامعتبر است', 401)
    if not hmac.compare_digest(challenge.code_hash, _code_digest(challenge.id, code)):
        challenge.attempts += 1
        if challenge.attempts >= int(current_app.config['PHONE_CODE_MAX_ATTEMPTS']):
            challenge.revoked_at = datetime.utcnow()
            db.session.commit()
            raise AuthFlowError('تعداد تلاش‌های ناموفق بیش از حد مجاز است. کد جدید درخواست کنید.', 429)
        db.session.commit()
        raise AuthFlowError('کد تأیید نادرست است', 401)


@auth_bp.route('/methods', methods=['GET'])
def auth_methods():
    """Public, non-secret login/registration policy for client routing."""
    from app.services import app_settings
    return jsonify(app_settings.get_auth_methods()), 200


@auth_bp.route('/register', methods=['POST'])
def register():
    """Create an inactive account and start the configured verification flow."""
    data = request.get_json(silent=True) or {}
    email = (data.get('email') or '').strip().lower()
    password = data.get('password') or ''
    username_raw = (data.get('username') or '').strip().lower()
    username = username_raw or None
    display_name = (data.get('display_name') or '').strip()
    mobile_number = normalize_mobile_number(data.get('mobile_number'))
    device_info = _as_device_info(data.get('device_info'))
    try:
        terms_version = int(data.get('terms_version', 0) or 0)
    except (TypeError, ValueError):
        terms_version = 0

    if not email or not password or not display_name or not mobile_number:
        return jsonify({'error': 'نام، ایمیل، رمز عبور و شماره موبایل الزامی هستند'}), 400
    if not re.match(r'^[\w\.-]+@[\w\.-]+\.\w+$', email):
        return jsonify({'error': 'ایمیل نامعتبر است'}), 400
    if len(password) < 8:
        return jsonify({'error': 'رمز عبور باید حداقل ۸ کاراکتر باشد'}), 400
    if username is not None and not re.match(r'^[a-z0-9_]{3,30}$', username):
        return jsonify({'error': 'نام کاربری فقط حروف کوچک، عدد و _ (۳ تا ۳۰ کاراکتر)'}), 400

    existing_email = User.query.filter_by(email=email, is_deleted=False).first()
    existing_mobile = User.query.filter_by(mobile_number=mobile_number, is_deleted=False).first()
    if existing_email and existing_email.is_active:
        return jsonify({'error': 'این ایمیل قبلاً ثبت شده'}), 409
    if existing_mobile and existing_mobile.is_active and existing_mobile.id != (existing_email.id if existing_email else None):
        return jsonify({'error': 'این شماره موبایل قبلاً ثبت شده'}), 409
    if existing_email and existing_mobile and existing_email.id != existing_mobile.id:
        return jsonify({'error': 'ایمیل یا شماره موبایل در انتظار تأیید دیگری است'}), 409

    existing_username = None
    if username is not None:
        existing_username = User.query.filter_by(username=username, is_deleted=False).first()
        if existing_username and existing_username.is_active and existing_username.id != (existing_email.id if existing_email else None):
            return jsonify({'error': 'این نام کاربری قبلاً گرفته شده'}), 409
        if existing_username and existing_email and existing_username.id != existing_email.id:
            return jsonify({'error': 'این نام کاربری در انتظار تأیید دیگری است'}), 409

    terms_accepted = bool(data.get('terms_accepted'))
    user = existing_email or existing_mobile
    if user is None:
        user = User(
            email=email,
            mobile_number=mobile_number,
            username=username,
            display_name=display_name,
            is_active=False,
            is_2fa_enabled=False,
            terms_version=(terms_version or 1) if terms_accepted else 0,
            terms_accepted_at=datetime.utcnow() if terms_accepted else None,
        )
        user.set_password(password)
        user.generate_totp_secret()
        db.session.add(user)
    else:
        # An unverified registration has no usable session. Restarting it with
        # the same email/mobile is safe and avoids orphaned pending accounts.
        user.email = email
        user.mobile_number = mobile_number
        user.username = username
        user.display_name = display_name
        user.mobile_verified_at = None
        user.is_active = False
        user.is_2fa_enabled = False
        user.terms_version = (terms_version or 1) if terms_accepted else 0
        user.terms_accepted_at = datetime.utcnow() if terms_accepted else None
        user.set_password(password)
        user.generate_totp_secret()

    from app.services import app_settings
    registration_method = app_settings.get_auth_methods()['registration_method']
    try:
        db.session.flush()
        if registration_method == 'totp':
            # The authenticator is enrolled by the user during this request;
            # no SMS is sent and the phone remains explicitly unverified.
            _enforce_send_limit(mobile_number, 'registration_totp', get_client_ip())
            now = datetime.utcnow()
            challenge_id = str(uuid.uuid4())
            challenge = PhoneVerification(
                id=challenge_id, user_id=user.id,
                mobile_number=mobile_number, purpose='registration_totp',
                code_hash=_code_digest(challenge_id, secrets.token_hex(16)),
                expires_at=now + timedelta(seconds=int(
                    current_app.config['PHONE_CODE_TTL_SECONDS'])),
                ip_address=get_client_ip(), created_at=now,
            )
            db.session.add(challenge)
            verification = {
                'verification_method': 'totp',
                'totp_secret': user.totp_secret,
                'totp_uri': user.get_totp_uri(),
            }
        else:
            challenge, delivery_channel = _issue_phone_code(
                user, PHONE_CODE_PURPOSE_REGISTER)
            verification = {
                'verification_method': 'sms',
                'delivery_channel': delivery_channel,
            }
        db.session.add(AuditLog(
            actor_id=user.id,
            action='user_register',
            entity_type='user',
            entity_id=user.id,
            ip_address=get_client_ip(),
            user_agent=request.headers.get('User-Agent'),
            device_fingerprint=create_device_fingerprint(device_info),
            new_value=registration_method,
        ))
        db.session.commit()
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except SmsDeliveryError:
        db.session.rollback()
        current_app.logger.warning('Could not deliver registration verification SMS.')
        return jsonify({'error': 'ارسال پیامک تأیید موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503
    except Exception:
        db.session.rollback()
        current_app.logger.exception('Could not start account registration.')
        return jsonify({'error': 'ثبت‌نام موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503

    return jsonify({
        'message': ('برای فعال‌سازی، کد Google Authenticator را وارد کنید.'
                    if registration_method == 'totp'
                    else 'کد تأیید به شماره موبایل شما ارسال شد.'),
        'verification_id': challenge.id,
        'mobile_number': _mask_mobile(mobile_number),
        'expires_in_seconds': int(current_app.config['PHONE_CODE_TTL_SECONDS']),
        **verification,
    }), 201


@auth_bp.route('/verify-totp-registration', methods=['POST'])
def verify_totp_registration():
    """Activate a pending TOTP-enrolled account without sending an SMS."""
    data = request.get_json(silent=True) or {}
    try:
        challenge = _challenge_or_error(data.get('verification_id'))
        if challenge.purpose != 'registration_totp' or challenge.verified_at:
            raise AuthFlowError('درخواست ثبت‌نام نامعتبر است', 401)
        user = User.query.filter_by(
            id=challenge.user_id, is_deleted=False, is_active=False,
        ).first()
        if user is None or not user.verify_totp(data.get('code')):
            challenge.attempts += 1
            if challenge.attempts >= int(current_app.config['PHONE_CODE_MAX_ATTEMPTS']):
                challenge.revoked_at = datetime.utcnow()
                db.session.commit()
                raise AuthFlowError('تلاش‌های ناموفق بیش از حد مجاز است. ثبت‌نام را دوباره آغاز کنید.', 429)
            db.session.commit()
            raise AuthFlowError('کد Google Authenticator نادرست است', 401)

        user.is_active = True
        user.is_2fa_enabled = True
        # Deliberately do not mark mobile_verified_at: this registration path
        # proves authenticator possession, not control of the supplied phone.
        challenge.verified_at = datetime.utcnow()
        challenge.consumed_at = datetime.utcnow()
        db.session.add(AuditLog(
            actor_id=user.id, action='totp_registration_verified',
            entity_type='user', entity_id=user.id,
            ip_address=get_client_ip(),
            user_agent=request.headers.get('User-Agent'),
        ))
        response = _create_authenticated_session(
            user, _as_device_info(data.get('device_info')),
            audit_action='user_register_login_totp',
        )
        db.session.commit()
        return jsonify(response), 200
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except Exception:
        db.session.rollback()
        current_app.logger.exception('Could not verify TOTP registration.')
        return jsonify({'error': 'تأیید ثبت‌نام موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503


def _is_registered_number(mobile_number: str) -> bool:
    """True only for a fully registered, phone-verified, active account."""
    user = User.query.filter_by(
        mobile_number=mobile_number,
        is_deleted=False,
        is_active=True,
    ).first()
    return bool(user and user.mobile_verified_at)


@auth_bp.route('/check-phone', methods=['POST'])
def check_phone():
    """Tell the login screen whether a number must register first.

    Telegram sends the code only for numbers that already exist; a brand new
    number is taken straight to the sign-up form. The client calls this before
    requesting a code so no SMS is ever sent to an unregistered number.
    """
    data = request.get_json(silent=True) or {}
    mobile_number = normalize_mobile_number(data.get('mobile_number'))
    if not mobile_number:
        return jsonify({'error': 'شماره موبایل نامعتبر است'}), 400
    registered = _is_registered_number(mobile_number)
    return jsonify({
        'registered': registered,
        'registration_required': not registered,
        'mobile_number': mobile_number,
        'masked_mobile_number': _mask_mobile(mobile_number),
    }), 200


@auth_bp.route('/request-phone-code', methods=['POST'])
def request_phone_code():
    """Start a phone-primary login for an existing account.

    A number that has never completed registration is NOT sent a code: the
    response asks the client to open the registration screen instead, exactly
    like Telegram's "create a new account" step.
    """
    data = request.get_json(silent=True) or {}
    mobile_number = normalize_mobile_number(data.get('mobile_number'))
    if not mobile_number:
        return jsonify({'error': 'شماره موبایل نامعتبر است'}), 400

    if not _is_registered_number(mobile_number):
        return jsonify({
            'registration_required': True,
            'registered': False,
            'message': 'این شماره هنوز ثبت‌نام نکرده است. لطفاً ابتدا ثبت‌نام کنید.',
            'mobile_number': mobile_number,
            'masked_mobile_number': _mask_mobile(mobile_number),
        }), 200

    user = User.query.filter_by(
        mobile_number=mobile_number,
        is_deleted=False,
        is_active=True,
    ).first()

    device_label = _device_label(_as_device_info(data.get('device_info')))
    try:
        challenge, delivery_channel = _issue_phone_code(
            user, PHONE_CODE_PURPOSE_LOGIN, device_label=device_label)
        db.session.commit()
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except SmsDeliveryError:
        db.session.rollback()
        current_app.logger.warning('Could not deliver login verification SMS.')
        # Do not disclose a valid account through a provider delivery failure.
        return jsonify({'error': 'ارسال پیامک تأیید موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503

    in_app = delivery_channel == DELIVERY_IN_APP
    return jsonify({
        'registration_required': False,
        'registered': True,
        'message': (
            'کد ورود به برنامه‌ی شما روی دستگاه دیگرتان ارسال شد.'
            if in_app else 'کد تأیید پیامک شد.'
        ),
        'verification_id': challenge.id,
        'mobile_number': _mask_mobile(mobile_number),
        'delivery_channel': delivery_channel,
        'sent_in_app': in_app,
        'expires_in_seconds': int(current_app.config['PHONE_CODE_TTL_SECONDS']),
        'resend_after_seconds': int(
            current_app.config['PHONE_CODE_RESEND_SECONDS']),
    }), 202


@auth_bp.route('/resend-phone-code', methods=['POST'])
def resend_phone_code():
    data = request.get_json(silent=True) or {}
    try:
        old = _challenge_or_error(data.get('verification_id'), allow_expired=True)
        if old.verified_at:
            raise AuthFlowError('این درخواست قبلاً تأیید شده است.', 409)
        user = User.query.filter_by(id=old.user_id, is_deleted=False).first()
        if not user or (old.purpose == PHONE_CODE_PURPOSE_LOGIN and not user.is_active):
            raise AuthFlowError('کد تأیید نامعتبر یا منقضی شده است', 401)
        force_sms = bool(data.get('force_sms'))
        if force_sms:
            challenge, delivery_channel = _issue_phone_code_via_sms(
                user, old.purpose)
        else:
            challenge, delivery_channel = _issue_phone_code(user, old.purpose)
        db.session.commit()
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except SmsDeliveryError:
        db.session.rollback()
        current_app.logger.warning('Could not resend phone verification SMS.')
        return jsonify({'error': 'ارسال پیامک تأیید موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503

    in_app = delivery_channel == DELIVERY_IN_APP
    return jsonify({
        'message': (
            'کد جدید در برنامه روی دستگاه دیگر شما ارسال شد.'
            if in_app else 'کد جدید پیامک شد.'
        ),
        'verification_id': challenge.id,
        'mobile_number': _mask_mobile(challenge.mobile_number),
        'delivery_channel': delivery_channel,
        'sent_in_app': in_app,
        'expires_in_seconds': int(current_app.config['PHONE_CODE_TTL_SECONDS']),
        'resend_after_seconds': int(
            current_app.config['PHONE_CODE_RESEND_SECONDS']),
    }), 202


@auth_bp.route('/verify-phone', methods=['POST'])
def verify_phone():
    """Validate an SMS code and either authenticate or request optional TOTP."""
    data = request.get_json(silent=True) or {}
    try:
        challenge = _challenge_or_error(data.get('verification_id'))
        _verify_challenge_code(challenge, data.get('code'))
        user = User.query.filter_by(id=challenge.user_id, is_deleted=False).first()
        if not user:
            raise AuthFlowError('کد تأیید نامعتبر یا منقضی شده است', 401)

        if challenge.purpose == PHONE_CODE_PURPOSE_REGISTER:
            user.is_active = True
            user.mobile_verified_at = datetime.utcnow()
            challenge.verified_at = datetime.utcnow()
            challenge.consumed_at = datetime.utcnow()
            db.session.add(AuditLog(
                actor_id=user.id,
                action='phone_registration_verified',
                entity_type='user',
                entity_id=user.id,
                ip_address=get_client_ip(),
            ))
            response = _create_authenticated_session(
                user, _as_device_info(data.get('device_info')), audit_action='user_register_login',
            )
            db.session.commit()
            return jsonify(response), 200

        if challenge.purpose != PHONE_CODE_PURPOSE_LOGIN or not user.is_active:
            raise AuthFlowError('کد تأیید نامعتبر یا منقضی شده است', 401)

        challenge.verified_at = datetime.utcnow()
        from app.services import app_settings
        if (user.is_2fa_enabled and
                app_settings.get_auth_methods()['login_priority'] == 'totp'):
            # SMS is an explicit recovery/fallback route when the admin chose
            # authenticator-first. It requires a previously verified number.
            challenge.consumed_at = datetime.utcnow()
            response = _create_authenticated_session(
                user, _as_device_info(data.get('device_info')),
                audit_action='phone_fallback_login',
            )
            db.session.commit()
            return jsonify(response), 200
        if user.is_2fa_enabled:
            db.session.commit()
            return jsonify({
                'require_2fa': True,
                'verification_id': challenge.id,
                'message': 'کد Google Authenticator را وارد کنید.',
            }), 200

        challenge.consumed_at = datetime.utcnow()
        response = _create_authenticated_session(
            user, _as_device_info(data.get('device_info')), audit_action='phone_login',
        )
        db.session.commit()
        return jsonify(response), 200
    except AuthFlowError as error:
        # Invalid-code attempts are committed inside _verify_challenge_code.
        # Rollback here is harmless for unchanged transactions and prevents a
        # partial session/device record from leaking after another failure.
        db.session.rollback()
        return _error(error)
    except Exception:
        db.session.rollback()
        current_app.logger.exception('Could not verify phone code.')
        return jsonify({'error': 'تأیید کد موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503


@auth_bp.route('/verify-login-2fa', methods=['POST'])
def verify_login_2fa():
    """Finish an SMS-verified login for an account with optional TOTP enabled."""
    data = request.get_json(silent=True) or {}
    try:
        challenge = _challenge_or_error(data.get('verification_id'))
        if (
            challenge.purpose != PHONE_CODE_PURPOSE_LOGIN
            or not challenge.verified_at
            or not challenge.user_id
        ):
            raise AuthFlowError('درخواست تأیید نامعتبر است', 401)
        user = User.query.filter_by(id=challenge.user_id, is_deleted=False, is_active=True).first()
        if not user or not user.is_2fa_enabled:
            raise AuthFlowError('درخواست تأیید نامعتبر است', 401)
        code = data.get('code')
        if not isinstance(code, str) or not re.fullmatch(r'\d{6}', code) or not user.verify_totp(code):
            challenge.attempts += 1
            if challenge.attempts >= int(current_app.config['PHONE_CODE_MAX_ATTEMPTS']):
                challenge.revoked_at = datetime.utcnow()
                db.session.commit()
                raise AuthFlowError('تعداد تلاش‌های ناموفق بیش از حد مجاز است. کد جدید درخواست کنید.', 429)
            db.session.commit()
            raise AuthFlowError('کد Google Authenticator نادرست است', 401)
        challenge.consumed_at = datetime.utcnow()
        response = _create_authenticated_session(
            user, _as_device_info(data.get('device_info')), audit_action='phone_login_2fa',
        )
        db.session.commit()
        return jsonify(response), 200
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except Exception:
        db.session.rollback()
        current_app.logger.exception('Could not complete two-factor phone login.')
        return jsonify({'error': 'تأیید کد موقتاً ممکن نیست. دوباره تلاش کنید.'}), 503


# ---------------------------------------------------------------------------
# Legacy password login: retained so people who registered before phone auth
# can still access and migrate naturally. New phone-verified accounts use the
# phone endpoints above and never need this path.
# ---------------------------------------------------------------------------
@auth_bp.route('/request-phone-recovery-code', methods=['POST'])
@jwt_required()
def request_phone_recovery_code():
    """Let a signed-in owner verify their saved number for future fallback."""
    user = User.query.filter_by(
        id=get_jwt_identity(), is_deleted=False, is_active=True,
    ).first()
    if not user or not user.mobile_number:
        return jsonify({'error': 'No recovery phone number is configured.'}), 400
    if user.mobile_verified_at:
        return jsonify({'already_verified': True}), 200
    try:
        challenge, _ = _issue_phone_code(
            user, 'phone_recovery', force_sms=True)
        db.session.commit()
        return jsonify({
            'verification_id': challenge.id,
            'mobile_number': _mask_mobile(user.mobile_number),
            'expires_in_seconds': int(current_app.config['PHONE_CODE_TTL_SECONDS']),
        }), 202
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)
    except SmsDeliveryError:
        db.session.rollback()
        return jsonify({'error': 'Could not send the recovery SMS. Please try again.'}), 503


@auth_bp.route('/verify-phone-recovery', methods=['POST'])
@jwt_required()
def verify_phone_recovery():
    """Verify the owner's registration phone as an SMS recovery channel."""
    data = request.get_json(silent=True) or {}
    user = User.query.filter_by(
        id=get_jwt_identity(), is_deleted=False, is_active=True,
    ).first()
    if not user:
        return jsonify({'error': 'Account not found.'}), 404
    try:
        challenge = _challenge_or_error(data.get('verification_id'))
        if (challenge.purpose != 'phone_recovery' or
                challenge.user_id != user.id or
                challenge.mobile_number != user.mobile_number):
            raise AuthFlowError('Invalid recovery request.', 401)
        _verify_challenge_code(challenge, data.get('code'))
        user.mobile_verified_at = datetime.utcnow()
        challenge.verified_at = datetime.utcnow()
        challenge.consumed_at = datetime.utcnow()
        db.session.add(AuditLog(
            actor_id=user.id, action='phone_recovery_verified',
            entity_type='user', entity_id=user.id,
            ip_address=get_client_ip(),
        ))
        db.session.commit()
        return jsonify({'verified': True}), 200
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)


@auth_bp.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True) or {}
    email = (data.get('email') or '').strip().lower()
    password = data.get('password') or ''
    code = data.get('totp_code')
    device_info = _as_device_info(data.get('device_info'))

    user = User.query.filter_by(email=email, is_deleted=False).first()
    if not user or not user.check_password(password):
        return jsonify({'error': 'ایمیل یا رمز عبور اشتباه است'}), 401
    if not user.is_active:
        return jsonify({'error': 'اکانت غیرفعال است'}), 403
    from app.services import app_settings
    login_priority = app_settings.get_auth_methods()['login_priority']
    if user.mobile_number and user.mobile_verified_at and login_priority != 'totp':
        return jsonify({
            'error': 'برای ورود، شماره موبایل و کد پیامک را وارد کنید.',
            'require_phone': True,
        }), 400
    if user.mobile_number and user.mobile_verified_at and login_priority == 'totp' and not user.is_2fa_enabled:
        return jsonify({
            'error': 'این حساب هنوز Google Authenticator را فعال نکرده است؛ با پیامک وارد شوید.',
            'require_phone': True,
        }), 400
    if user.is_2fa_enabled:
        if not code:
            return jsonify({'error': 'کد 2FA الزامی است', 'require_2fa': True}), 401
        if not user.verify_totp(code):
            return jsonify({'error': 'کد 2FA نامعتبر است'}), 401

    try:
        response = _create_authenticated_session(user, device_info)
        db.session.commit()
        return jsonify(response), 200
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)


@auth_bp.route('/verify-2fa', methods=['POST'])
def verify_2fa_register():
    """Compatibility endpoint for an incomplete registration from old clients."""
    data = request.get_json(silent=True) or {}
    user_id = data.get('user_id')
    code = data.get('code')
    user = User.query.filter_by(id=user_id, is_deleted=False).first()
    if not user:
        return jsonify({'error': 'کاربر یافت نشد'}), 404
    if user.mobile_number:
        return jsonify({'error': 'این نسخه از ثبت‌نام با شماره موبایل تأیید می‌شود.'}), 409
    if not user.verify_totp(code):
        return jsonify({'error': 'کد 2FA نامعتبر است'}), 401
    try:
        response = _create_authenticated_session(user, _as_device_info(data.get('device_info')))
        db.session.commit()
        return jsonify(response), 200
    except AuthFlowError as error:
        db.session.rollback()
        return _error(error)


def _require_primary_device(user_id: str):
    """Point 4: only the primary device may change account security.

    Returns a ready JSON error response when the caller is a secondary device,
    otherwise None. Without this, anyone who gained a second session could turn
    on two-step verification or lock the archive and shut the real owner out.
    """
    if is_primary_device(user_id, get_jwt().get('device_id')):
        return None
    return jsonify({
        'error': PRIMARY_REQUIRED_MESSAGE,
        'code': 'primary_device_required',
    }), 403


@auth_bp.route('/2fa/setup', methods=['POST'])
@jwt_required()
def setup_two_factor():
    """Return a newly generated secret only to an already authenticated owner."""
    user = User.query.filter_by(id=get_jwt_identity(), is_deleted=False).first()
    if not user:
        return jsonify({'error': 'کاربر یافت نشد'}), 404
    denied = _require_primary_device(user.id)
    if denied:
        return denied
    if user.is_2fa_enabled:
        return jsonify({'error': 'تأیید دو مرحله‌ای از قبل فعال است.'}), 409
    secret = user.generate_totp_secret()
    db.session.add(AuditLog(
        actor_id=user.id,
        action='two_factor_setup_started',
        entity_type='user',
        entity_id=user.id,
        ip_address=get_client_ip(),
    ))
    db.session.commit()
    return jsonify({
        'totp_secret': secret,
        'totp_uri': user.get_totp_uri(),
        'warning': 'کلید را در Google Authenticator ذخیره کنید. تا وارد کردن کد، فعال نمی‌شود.',
    }), 200


@auth_bp.route('/2fa/enable', methods=['POST'])
@jwt_required()
def enable_two_factor():
    data = request.get_json(silent=True) or {}
    user = User.query.filter_by(id=get_jwt_identity(), is_deleted=False).first()
    if not user:
        return jsonify({'error': 'کاربر یافت نشد'}), 404
    denied = _require_primary_device(user.id)
    if denied:
        return denied
    if user.is_2fa_enabled:
        return jsonify({'error': 'تأیید دو مرحله‌ای از قبل فعال است.'}), 409
    if not user.verify_totp(data.get('code')):
        return jsonify({'error': 'کد Google Authenticator نامعتبر است'}), 401
    user.is_2fa_enabled = True
    record_alert(
        user.id, 'two_factor_enabled', 'تأیید دو مرحله‌ای فعال شد',
        body='تأیید دو مرحله‌ای روی حساب شما فعال شد.',
        severity='info', ip_address=get_client_ip(),
    )
    db.session.add(AuditLog(
        actor_id=user.id,
        action='two_factor_enabled',
        entity_type='user',
        entity_id=user.id,
        ip_address=get_client_ip(),
    ))
    db.session.commit()
    return jsonify({'message': 'تأیید دو مرحله‌ای فعال شد.', 'user': user.to_dict(include_private=True)}), 200


@auth_bp.route('/2fa/disable', methods=['POST'])
@jwt_required()
def disable_two_factor():
    data = request.get_json(silent=True) or {}
    user = User.query.filter_by(id=get_jwt_identity(), is_deleted=False).first()
    if not user:
        return jsonify({'error': 'کاربر یافت نشد'}), 404
    denied = _require_primary_device(user.id)
    if denied:
        return denied
    if not user.is_2fa_enabled:
        return jsonify({'error': 'تأیید دو مرحله‌ای فعال نیست.'}), 409
    if not user.verify_totp(data.get('code')):
        return jsonify({'error': 'کد Google Authenticator نامعتبر است'}), 401
    user.is_2fa_enabled = False
    record_alert(
        user.id, 'two_factor_disabled', 'تأیید دو مرحله‌ای غیرفعال شد',
        body='اگر شما این کار را نکرده‌اید، فوراً حساب خود را بررسی کنید.',
        severity='critical', ip_address=get_client_ip(),
    )
    # Rotate the stored secret so an old authenticator code cannot be reused if
    # the owner re-enables the feature later.
    user.generate_totp_secret()
    db.session.add(AuditLog(
        actor_id=user.id,
        action='two_factor_disabled',
        entity_type='user',
        entity_id=user.id,
        ip_address=get_client_ip(),
    ))
    db.session.commit()
    return jsonify({'message': 'تأیید دو مرحله‌ای غیرفعال شد.', 'user': user.to_dict(include_private=True)}), 200


@auth_bp.route('/logout', methods=['POST'])
@jwt_required()
def logout():
    from flask_jwt_extended import get_jwt
    user_id = get_jwt_identity()
    claims = get_jwt()
    device_id = claims.get('device_id')
    if device_id:
        # Logging out ends this device's sessions (Telegram-like). The
        # device row stays so the 3-account limit remains enforceable.
        UserSession.query.filter_by(
            device_id=device_id, user_id=user_id, is_active=True,
        ).update({'is_active': False}, synchronize_session=False)
        device = UserDevice.query.filter_by(
            id=device_id, user_id=user_id,
        ).first()
        if device:
            device.last_active = datetime.utcnow()
            # A logged-out phone must stop buzzing. The client also clears
            # the token via /notifications/register; this covers clients
            # that never get the chance (network drop mid-logout).
            device.push_token = None
            device.push_platform = None
    user = db.session.get(User, user_id)
    if user:
        user.is_online = False
        user.last_seen = datetime.utcnow()
    db.session.add(AuditLog(
        actor_id=user_id, action='user_logout', entity_type='user',
        entity_id=user_id, ip_address=get_client_ip(),
    ))
    db.session.commit()
    return jsonify({'message': 'خروج موفق'}), 200


@auth_bp.route('/refresh', methods=['POST'])
@jwt_required(refresh=True)
def refresh():
    from flask_jwt_extended import get_jwt
    user_id = get_jwt_identity()
    claims = get_jwt()
    device_id = claims.get('device_id')
    if device_id:
        device = UserDevice.query.filter_by(
            id=device_id, user_id=user_id,
        ).first()
        if device is not None and (device.is_deleted or not device.is_active):
            return jsonify({
                'error': 'این دستگاه از حساب خارج شده است.',
                'code': 'device_terminated',
            }), 401
        session = UserSession.query.filter_by(
            device_id=device_id, user_id=user_id, is_active=True,
        ).first()
        if session is None:
            return jsonify({
                'error': 'نشست منقضی شده است. لطفاً دوباره وارد شوید.',
                'code': 'session_ended',
            }), 401
        session.last_used = datetime.utcnow()
        device.last_active = datetime.utcnow()
        db.session.commit()
        access = create_access_token(
            identity=user_id, expires_delta=timedelta(hours=24),
            additional_claims={'device_id': device_id},
        )
        return jsonify({'access_token': access}), 200
    access = create_access_token(identity=user_id, expires_delta=timedelta(hours=24))
    return jsonify({'access_token': access}), 200
