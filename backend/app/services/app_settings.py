"""Operator-controlled upload limits (admin panel → app behaviour).

The owner runs on cPanel shared hosting, so a handful of users uploading
huge videos can exhaust disk and inode quotas. The panel therefore controls,
per media category:

* a maximum file size in megabytes (``0`` = unlimited), and
* whether that category may be uploaded at all.

A per-user cap can additionally override the category limits for one account
(the stricter of the two always wins). Everything lives in the
``app_settings`` table so it can change without a redeploy; when the table
does not exist yet (installation not upgraded) the defaults apply and no
request ever fails because of the settings store.
"""
import json
import time

from app import db
from app.models.settings import AppSetting

CATEGORIES = ('image', 'video', 'audio', 'voice', 'file')

CATEGORY_LABELS = {
    'image': 'عکس',
    'video': 'ویدیو',
    'audio': 'موسیقی و فایل صوتی',
    'voice': 'پیام صوتی',
    'file': 'فایل',
}

# Defaults keep the previous behaviour (the old global ceiling was 50 MB)
# while protecting shared hosting from the most common abuse: images and
# voice notes have no reason to be tens of megabytes.
DEFAULT_LIMITS_MB = {
    'image': 10.0,
    'video': 50.0,
    'audio': 20.0,
    'voice': 10.0,
    'file': 50.0,
}

IMAGE_EXTS = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'svg', 'heic', 'heif',
}
VIDEO_EXTS = {
    'mp4', 'mov', 'webm', 'mkv', 'avi', 'flv', 'm4v', '3gp', 'mpeg', 'mpg',
    'ogv',
}
AUDIO_EXTS = {
    'mp3', 'ogg', 'm4a', 'wav', 'flac', 'aac', 'wma', 'opus', 'aiff', 'amr',
}

_KEY_LIMITS = 'upload_limits_mb'
_KEY_ENABLED = 'upload_enabled'
_KEY_USER_PREFIX = 'user_upload_limit_mb:'

_CACHE_TTL_SECONDS = 15
_cache = {'at': 0.0, 'limits': None, 'enabled': None, 'scope': None}


def _cache_scope():
    """Identify the database the cache belongs to (tests use many)."""
    try:
        return str(db.engine.url)
    except Exception:
        return None


# --------------------------------------------------------------------------
# storage helpers (fail-soft: a missing table must never break uploads)
# --------------------------------------------------------------------------
def _read(key):
    try:
        row = db.session.get(AppSetting, key)
        return row.value if row is not None else None
    except Exception:
        try:
            db.session.rollback()
        except Exception:
            pass
        return None


def _write(key, value):
    try:
        row = db.session.get(AppSetting, key)
        if row is None:
            row = AppSetting(key=key)
            db.session.add(row)
        row.value = value
        db.session.commit()
    except Exception:
        try:
            db.session.rollback()
        except Exception:
            pass
        raise
    _cache['at'] = 0.0


def _parse_mb(value):
    """A stored/admin-supplied MB value: float >= 0, or None when invalid."""
    if value is None or value == '':
        return None
    try:
        mb = float(value)
    except (TypeError, ValueError):
        return None
    if mb < 0 or mb > 10240:
        return None
    return mb


# --------------------------------------------------------------------------
# public settings
# --------------------------------------------------------------------------
def get_upload_settings():
    """{'limits_mb': {...}, 'enabled': {...}} with defaults filled in."""
    now = time.monotonic()
    scope = _cache_scope()
    if (_cache['limits'] is not None and _cache['scope'] == scope
            and now - _cache['at'] < _CACHE_TTL_SECONDS):
        return {'limits_mb': dict(_cache['limits']),
                'enabled': dict(_cache['enabled'])}
    limits = dict(DEFAULT_LIMITS_MB)
    raw = _read(_KEY_LIMITS)
    if raw:
        try:
            stored = json.loads(raw)
            if isinstance(stored, dict):
                for category in CATEGORIES:
                    mb = _parse_mb(stored.get(category))
                    if mb is not None:
                        limits[category] = mb
        except (TypeError, ValueError):
            pass
    enabled = {category: True for category in CATEGORIES}
    raw = _read(_KEY_ENABLED)
    if raw:
        try:
            stored = json.loads(raw)
            if isinstance(stored, dict):
                for category in CATEGORIES:
                    if category in stored:
                        enabled[category] = bool(stored[category])
        except (TypeError, ValueError):
            pass
    _cache.update(at=now, limits=limits, enabled=enabled, scope=scope)
    return {'limits_mb': dict(limits), 'enabled': dict(enabled)}


def save_upload_settings(limits_mb=None, enabled=None):
    """Persist panel changes. Unknown keys are ignored, values validated."""
    current = get_upload_settings()
    if limits_mb is not None:
        merged = dict(current['limits_mb'])
        for category in CATEGORIES:
            if category in (limits_mb or {}):
                mb = _parse_mb(limits_mb.get(category))
                if mb is None:
                    raise ValueError(f'حد حجم «{category}» نامعتبر است')
                merged[category] = mb
        _write(_KEY_LIMITS, json.dumps(merged))
        current['limits_mb'] = merged
    if enabled is not None:
        merged = dict(current['enabled'])
        for category in CATEGORIES:
            if category in (enabled or {}):
                merged[category] = bool(enabled[category])
        _write(_KEY_ENABLED, json.dumps(merged))
        current['enabled'] = merged
    return current


def uploads_enabled(category):
    if category not in CATEGORIES:
        return True
    return get_upload_settings()['enabled'].get(category, True)


# --------------------------------------------------------------------------
# per-user overrides
# --------------------------------------------------------------------------
def user_limit_mb(user_id):
    """The admin-set per-user cap in MB, or None when the user has none."""
    if not user_id:
        return None
    return _parse_mb(_read(f'{_KEY_USER_PREFIX}{user_id}'))


def set_user_limit_mb(user_id, mb):
    """Set (or, with None/0, clear) one user's upload cap. Returns the cap."""
    if mb is None or mb == '' or float(mb or 0) <= 0:
        try:
            row = db.session.get(AppSetting, f'{_KEY_USER_PREFIX}{user_id}')
            if row is not None:
                db.session.delete(row)
                db.session.commit()
        except Exception:
            try:
                db.session.rollback()
            except Exception:
                pass
        return None
    parsed = _parse_mb(mb)
    if parsed is None:
        raise ValueError('حد حجم کاربر نامعتبر است')
    _write(f'{_KEY_USER_PREFIX}{user_id}', str(parsed))
    return parsed


def list_user_limits():
    """All per-user caps as [{'user_id': ..., 'max_mb': ...}]."""
    try:
        rows = AppSetting.query.filter(
            AppSetting.key.like(f'{_KEY_USER_PREFIX}%')).all()
    except Exception:
        try:
            db.session.rollback()
        except Exception:
            pass
        return []
    out = []
    for row in rows:
        mb = _parse_mb(row.value)
        if mb is not None:
            out.append({
                'user_id': row.key[len(_KEY_USER_PREFIX):],
                'max_mb': mb,
            })
    return out


# --------------------------------------------------------------------------
# category resolution + enforcement
# --------------------------------------------------------------------------
def category_for_extension(ext):
    ext = (ext or '').lower().lstrip('.')
    if ext in IMAGE_EXTS:
        return 'image'
    if ext in VIDEO_EXTS:
        return 'video'
    if ext in AUDIO_EXTS:
        return 'audio'
    return 'file'


def category_for_upload(filename, mime_type=None, declared=None):
    """Category of an incoming upload.

    The client may declare what it is sending (a recorded voice note is an
    ``.m4a`` file, indistinguishable from music by extension alone); explicit
    declarations win, then the extension, then the MIME type.
    """
    declared = (declared or '').strip().lower()
    if declared in CATEGORIES:
        return declared
    ext = ''
    if filename and '.' in filename:
        ext = filename.rsplit('.', 1)[1].lower()
    category = category_for_extension(ext)
    if category != 'file':
        return category
    mime = (mime_type or '').lower()
    if mime.startswith('image/'):
        return 'image'
    if mime.startswith('video/'):
        return 'video'
    if mime.startswith('audio/'):
        return 'audio'
    return 'file'


def category_for_message(message_type, media=None):
    """Category of a media file being attached to a message.

    Sending is checked as well as uploading, so a file uploaded before a
    limit was lowered still cannot be attached above the current limit. A
    generic ``file`` message keeps the true category of its extension (a
    video sent "as a file" still counts against the video limit).
    """
    if message_type == 'voice':
        return 'voice'
    if message_type in ('image', 'sticker', 'gif'):
        return 'image'
    if message_type in ('video', 'video_note', 'round_video'):
        return 'video'
    if message_type in ('audio', 'music'):
        return 'audio'
    if media is not None:
        name = getattr(media, 'original_name', '') or ''
        ext = name.rsplit('.', 1)[1] if '.' in name else ''
        by_ext = category_for_extension(ext)
        if by_ext != 'file':
            return by_ext
        by_type = getattr(media, 'media_type', None)
        if by_type in CATEGORIES:
            return by_type
    return 'file'


def effective_limit_bytes(category, user_id=None):
    """The byte ceiling for a category/user, or None when unlimited.

    The stricter of the category limit and the per-user cap wins.
    """
    if category not in CATEGORIES:
        return None
    limits = []
    category_mb = get_upload_settings()['limits_mb'].get(category)
    if category_mb:
        limits.append(float(category_mb))
    override = user_limit_mb(user_id)
    if override:
        limits.append(float(override))
    if not limits:
        return None
    return int(min(limits) * 1024 * 1024)


def format_mb(limit_bytes):
    mb = (limit_bytes or 0) / (1024 * 1024)
    return str(int(mb)) if float(mb).is_integer() else f'{mb:.1f}'


def limit_error_payload(category, limit_bytes):
    label = CATEGORY_LABELS.get(category, 'فایل')
    return {
        'error': (f'حجم فایل بیش از حد مجاز است. حداکثر حجم مجاز برای '
                  f'{label} {format_mb(limit_bytes)} مگابایت است.'),
        'code': 'file_too_large',
        'category': category,
        'limit_bytes': limit_bytes,
        'limit_mb': (limit_bytes or 0) / (1024 * 1024),
    }


def disabled_error_payload(category):
    label = CATEGORY_LABELS.get(category, 'فایل')
    return {
        'error': f'ارسال {label} توسط مدیریت غیرفعال شده است.',
        'code': 'uploads_disabled',
        'category': category,
    }


def check_size(category, size_bytes, user_id=None):
    """None when the size is allowed, otherwise the error payload."""
    limit = effective_limit_bytes(category, user_id)
    if limit is not None and (size_bytes or 0) > limit:
        return limit_error_payload(category, limit)
    return None


def public_limits(user_id=None):
    """Effective per-category limits, as exposed to the mobile client."""
    settings = get_upload_settings()
    out = {}
    for category in CATEGORIES:
        limit = effective_limit_bytes(category, user_id)
        out[category] = {
            'enabled': settings['enabled'].get(category, True),
            'limit_bytes': limit,
            'limit_mb': (limit / (1024 * 1024)) if limit else None,
        }
    return out

# --------------------------------------------------------------------------
# Authentication delivery policy
# --------------------------------------------------------------------------
_AUTH_METHODS_KEY = 'auth_methods'
_DEFAULT_AUTH_METHODS = {
    'registration_method': 'sms',
    'login_priority': 'sms',
}
_AUTH_METHODS_CACHE_TTL = 15
_auth_methods_cache = {'at': 0.0, 'scope': None, 'value': None}


def get_auth_methods():
    """Current public auth policy, with safe SMS-first defaults.

    A missing/unavailable settings table never blocks sign-in: the established
    phone/SMS path remains the default until the owner explicitly changes it.
    """
    now = time.monotonic()
    scope = _cache_scope()
    cached = _auth_methods_cache
    if (cached['value'] is not None and cached['scope'] == scope and
            now - cached['at'] < _AUTH_METHODS_CACHE_TTL):
        return dict(cached['value'])

    methods = dict(_DEFAULT_AUTH_METHODS)
    raw = _read(_AUTH_METHODS_KEY)
    if raw:
        try:
            saved = json.loads(raw)
        except (TypeError, ValueError):
            saved = None
        if isinstance(saved, dict):
            if saved.get('registration_method') in ('sms', 'totp'):
                methods['registration_method'] = saved['registration_method']
            if saved.get('login_priority') in ('sms', 'totp'):
                methods['login_priority'] = saved['login_priority']
    _auth_methods_cache.update(at=now, scope=scope, value=dict(methods))
    return methods


def save_auth_methods(*, registration_method, login_priority):
    """Validate and persist the admin-selected registration/login paths."""
    if registration_method not in ('sms', 'totp'):
        raise ValueError('Invalid registration method')
    if login_priority not in ('sms', 'totp'):
        raise ValueError('Invalid login priority')
    policy = {
        'registration_method': registration_method,
        'login_priority': login_priority,
    }
    _write(_AUTH_METHODS_KEY, json.dumps(policy))
    _auth_methods_cache.update(at=0.0, scope=None, value=None)
    return policy
