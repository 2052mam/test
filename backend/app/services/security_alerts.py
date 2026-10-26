"""Instant account-security notices and the primary-device policy.

Point 3: a login attempt from another device must reach the owner *now*, not
whenever a push tick happens to land. Alerts are rows the client already polls
for, so they show up in the chat list on the next poll (seconds, not minutes).

Point 4: the first device to sign an account in becomes the primary device.
It cannot be terminated by any other device, and only it may enable two-step
verification or set the archive lock.
"""
from datetime import datetime, timedelta

from app import db
from app.models.support import SecurityAlert
from app.models.user import UserDevice

# Only the primary device may perform these account-security changes.
PRIMARY_ONLY_ACTIONS = (
    'two_factor',
    'archive_lock',
)

PRIMARY_REQUIRED_MESSAGE = (
    'فقط دستگاه اصلی حساب می‌تواند این تنظیم امنیتی را تغییر دهد. '
    'لطفاً از دستگاه اصلی خود اقدام کنید.'
)


def ensure_primary_device(user_id, device):
    """Mark `device` primary when the account has no primary device yet.

    Called on every successful authentication, so the very first sign-in (and
    an account whose primary device was legitimately removed by itself) always
    ends up with exactly one owner device.
    """
    if device is None:
        return False
    existing = UserDevice.query.filter_by(
        user_id=user_id, is_primary=True, is_deleted=False,
    ).first()
    if existing is not None:
        return existing.id == device.id
    device.is_primary = True
    device.primary_since = datetime.utcnow()
    return True


def primary_device(user_id):
    return UserDevice.query.filter_by(
        user_id=user_id, is_primary=True, is_deleted=False,
    ).first()


def is_primary_device(user_id, device_id):
    """True when `device_id` is this account's primary device.

    Legacy tokens issued before device claims existed carry no ``device_id``.
    Those are treated as *not* primary so the restriction cannot be bypassed
    simply by presenting an old token — unless the account has no primary
    device at all, in which case nothing is being protected yet.
    """
    owner = primary_device(user_id)
    if owner is None:
        return True
    return bool(device_id) and owner.id == device_id


def record_alert(
    user_id,
    alert_type,
    title,
    *,
    body=None,
    severity='warning',
    device=None,
    device_name=None,
    device_model=None,
    ip_address=None,
    dedupe_seconds=0,
    post_to_chat=True,
):
    """Persist one security alert; returns it, or None when deduplicated.

    Point 7: besides the structured row the chat-list banner polls, the alert
    is mirrored into the user's one-way "Security Support" chat so there is a
    durable, readable history in the chat list — the way Telegram's service
    account behaves. Login codes are posted separately by `code_delivery` and
    pass ``post_to_chat=False`` to avoid a duplicate.
    """
    if not user_id:
        return None
    if dedupe_seconds:
        since = datetime.utcnow() - timedelta(seconds=dedupe_seconds)
        recent = SecurityAlert.query.filter(
            SecurityAlert.user_id == user_id,
            SecurityAlert.alert_type == alert_type,
            SecurityAlert.created_at >= since,
        ).first()
        if recent is not None:
            return None
    alert = SecurityAlert(
        user_id=user_id,
        alert_type=alert_type,
        title=title,
        body=body,
        severity=severity,
        device_id=device.id if device is not None else None,
        device_name=device_name or (device.device_name if device is not None else None),
        device_model=device_model or (device.device_model if device is not None else None),
        ip_address=ip_address,
    )
    db.session.add(alert)
    if post_to_chat:
        _mirror_to_security_chat(alert)
    return alert


def _mirror_to_security_chat(alert):
    """Write a human-readable copy of `alert` into the service chat."""
    try:
        from app.services.security_chat import post_security_message

        icon = {'critical': '🔴', 'warning': '⚠️'}.get(alert.severity, 'ℹ️')
        lines = [f'{icon} {alert.title}']
        if alert.body:
            lines.append('')
            lines.append(alert.body)
        details = []
        if alert.device_name:
            details.append(f'دستگاه: {alert.device_name}')
        if alert.ip_address:
            details.append(f'IP: {alert.ip_address}')
        details.append(
            'زمان: ' + datetime.utcnow().strftime('%Y/%m/%d %H:%M UTC'))
        lines.append('')
        lines.append('\n'.join(details))
        post_security_message(alert.user_id, '\n'.join(lines))
    except Exception:  # pragma: no cover - never break the caller
        from flask import current_app
        current_app.logger.exception(
            'Could not mirror a security alert into the service chat.')


def unread_alerts(user_id, limit=20):
    return SecurityAlert.query.filter_by(
        user_id=user_id, is_dismissed=False,
    ).order_by(SecurityAlert.created_at.desc()).limit(limit).all()
