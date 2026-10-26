"""Firebase Cloud Messaging wake-up ticks (data-only, content never leaves us).

Role in the notification stack: FCM is the EXTERNAL wake-up. When Android
would never wake our own code (restricted bucket, hibernation, aggressive
OEM force-stop), a high-priority FCM tick still wakes the app via Play
Services. The tick carries no message content — just ``{kind, chat_id}`` —
and the client funnels every tick into ``GET /notifications/pending``,
the same authoritative feed the keep-alive service and WorkManager poll.
Previews are rendered locally, so Google infra only ever sees
"something changed", and collapsed/duplicate ticks are harmless.

Fully optional: without ``FCM_PROJECT_ID`` + service-account credentials
every function below is a silent no-op and the app runs on local polling.
``google-auth``/``requests`` are imported lazily so the backend (and its
test-suite) runs with or without them installed.
"""
import json
import logging
import os
import threading
import time

log = logging.getLogger(__name__)

_FCM_TIMEOUT_SECONDS = 5
_token_cache = {'token': None, 'expires_at': 0.0}
_cache_lock = threading.Lock()
_MAX_OAUTH_ATTEMPTS = 3
_OAUTH_RETRY_BACKOFF_SECONDS = 0.25
_FCM_CREDENTIAL_RECHECK_SECONDS = 300
_FCM_CREDENTIAL_LOG_INTERVAL_SECONDS = 300
_cached_credential_error = None
_cached_credential_error_until = 0.0
_last_credential_error_log = 0.0
_credential_error_lock = threading.Lock()


class FCMRefreshTransportError(RuntimeError):
    """The OAuth endpoint could not be reached after bounded retries."""


class FCMCredentialsError(RuntimeError):
    """The configured service-account credentials are invalid or unusable."""


def _config():
    return {
        'project_id': os.getenv('FCM_PROJECT_ID', ''),
        'account_file': os.getenv('FCM_SERVICE_ACCOUNT_FILE', ''),
        'account_json': os.getenv('FCM_SERVICE_ACCOUNT_JSON', ''),
    }


def push_configured():
    """True when the server can actually send FCM ticks."""
    cfg = _config()
    if not cfg['project_id']:
        return False
    if cfg['account_json']:
        return True
    return bool(cfg['account_file'] and os.path.exists(cfg['account_file']))


def _service_account_info():
    cfg = _config()
    if cfg['account_json']:
        return json.loads(cfg['account_json'])
    with open(cfg['account_file'], 'r', encoding='utf-8') as fh:
        return json.load(fh)


def _is_transient_oauth_transport_error(error):
    """Recognize connection drops/timeouts without masking OAuth rejections."""
    try:
        import requests
        transient_types = (
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
            TimeoutError,
            ConnectionError,
        )
    except ImportError:  # pragma: no cover - requests is a backend dependency
        transient_types = (TimeoutError, ConnectionError)

    pending = [error]
    seen = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, transient_types):
            return True
        if isinstance(current, OSError):
            # RemoteDisconnected and socket-level disconnects are OSErrors.
            return True
        if current.__cause__ is not None:
            pending.append(current.__cause__)
        if current.__context__ is not None:
            pending.append(current.__context__)
        pending.extend(arg for arg in current.args if isinstance(arg, BaseException))
    return False


def _google_credential_error_message(error):
    """Return actionable OAuth diagnostics without logging credential material."""
    message = str(error).lower()
    if 'invalid_grant' in message and 'signature' in message:
        return (
            'Google rejected the service-account signing key (invalid_grant). '
            'Rotate the JSON key and verify the server clock.'
        )
    if 'invalid_grant' in message:
        return (
            'Google rejected the service-account grant (invalid_grant). '
            'Verify the key is active, the service account is enabled, and the server clock is correct.'
        )
    if 'unauthorized_client' in message:
        return (
            'Google denied OAuth access for this service account (unauthorized_client). '
            'Verify the account and Firebase project configuration.'
        )
    if 'invalid_scope' in message:
        return 'Google rejected the FCM OAuth scope (invalid_scope).'
    return (
        'Google rejected the service-account credentials. Verify the JSON key is active, '
        'the account is enabled, and the configured Firebase project matches.'
    )


class _BoundedOAuthRequest:
    """Keep google-auth's refresh HTTP calls bounded, including retries."""
    def __init__(self, request):
        self._request = request

    def __call__(self, *args, **kwargs):
        kwargs['timeout'] = _FCM_TIMEOUT_SECONDS
        return self._request(*args, **kwargs)


def _refresh_credentials(credentials, request, *, sleep=time.sleep):
    bounded_request = _BoundedOAuthRequest(request)
    for attempt in range(_MAX_OAUTH_ATTEMPTS):
        try:
            credentials.refresh(bounded_request)
            return
        except Exception as exc:
            if not _is_transient_oauth_transport_error(exc):
                raise
            if attempt + 1 == _MAX_OAUTH_ATTEMPTS:
                raise FCMRefreshTransportError(
                    f'OAuth token endpoint unreachable after {attempt + 1} attempts'
                ) from exc
            sleep(_OAUTH_RETRY_BACKOFF_SECONDS * (2 ** attempt))


def _access_token():
    """OAuth2 token for the FCM HTTP v1 API, cached until near-expiry."""
    global _cached_credential_error, _cached_credential_error_until
    now = time.time()
    with _cache_lock:
        if _token_cache['token'] and _token_cache['expires_at'] > now + 60:
            return _token_cache['token']
        if _cached_credential_error and _cached_credential_error_until > now:
            raise FCMCredentialsError(_cached_credential_error)
        _cached_credential_error = None
        _cached_credential_error_until = 0.0
    try:
        from google.auth.exceptions import RefreshError
        from google.auth.transport.requests import Request
        from google.oauth2 import service_account
    except ImportError as exc:
        raise FCMCredentialsError('google-auth is not installed') from exc
    try:
        info = _service_account_info()
        credentials = service_account.Credentials.from_service_account_info(
            info,
            scopes=['https://www.googleapis.com/auth/firebase.messaging'],
        )
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise FCMCredentialsError('service-account configuration is invalid') from exc
    try:
        _refresh_credentials(credentials, Request())
    except FCMRefreshTransportError:
        raise
    except RefreshError as exc:
        message = _google_credential_error_message(exc)
        with _cache_lock:
            _cached_credential_error = message
            _cached_credential_error_until = time.time() + _FCM_CREDENTIAL_RECHECK_SECONDS
        raise FCMCredentialsError(message) from exc
    with _cache_lock:
        _cached_credential_error = None
        _cached_credential_error_until = 0.0
        _token_cache['token'] = credentials.token
        _token_cache['expires_at'] = now + 3300
    return credentials.token


def _post_fcm(url, headers, payload):
    """Seam for tests: the only raw HTTP call in this module."""
    import requests
    return requests.post(
        url, headers=headers, json=payload, timeout=_FCM_TIMEOUT_SECONDS,
    )


def _is_unregistered(status_code, body_text):
    if status_code in (400, 404):
        lowered = (body_text or '').upper()
        return 'UNREGISTERED' in lowered or 'NOT_FOUND' in lowered
    return False


def _log_credential_error_once(error):
    """Keep a bad key from flooding logs while keeping the first diagnosis."""
    global _last_credential_error_log
    now = time.monotonic()
    with _credential_error_lock:
        if now - _last_credential_error_log < _FCM_CREDENTIAL_LOG_INTERVAL_SECONDS:
            return
        _last_credential_error_log = now
    log.error(
        'FCM tick skipped (service-account credentials): %s; '
        'next credential check in at most %s seconds',
        error,
        _FCM_CREDENTIAL_RECHECK_SECONDS,
    )


def send_tick(tokens, data, collapse_key=None):
    """POST one data-only tick per token. Returns (delivered, stale_tokens).

    Never raises: delivery failures are logged and stale (UNREGISTERED)
    tokens are returned so the caller can purge them.
    """
    tokens = [t for t in dict.fromkeys(tokens or []) if t]
    if not tokens or not push_configured():
        return 0, []
    try:
        access_token = _access_token()
        project_id = _config()['project_id']
    except FCMRefreshTransportError as exc:
        log.warning('FCM tick skipped (OAuth transport): %s', exc)
        return 0, []
    except FCMCredentialsError as exc:
        _log_credential_error_once(exc)
        return 0, []
    except Exception as exc:
        log.warning('FCM token refresh failed (unclassified): %s', exc)
        return 0, []
    url = (
        'https://fcm.googleapis.com/v1/projects/'
        f'{project_id}/messages:send'
    )
    headers = {
        'Authorization': f'Bearer {access_token}',
        'Content-Type': 'application/json',
    }
    string_data = {str(k): str(v) for k, v in (data or {}).items()}
    delivered, stale = 0, []
    for token in tokens:
        message = {
            'token': token,
            'data': string_data,
            'android': {'priority': 'HIGH'},
        }
        if collapse_key:
            message['android']['collapse_key'] = collapse_key
        try:
            res = _post_fcm(url, headers, {'message': message})
            if 200 <= res.status_code < 300:
                delivered += 1
            elif _is_unregistered(res.status_code, res.text):
                stale.append(token)
            else:
                log.warning(
                    'FCM tick failed (%s): %s',
                    res.status_code, (res.text or '')[:200],
                )
        except Exception as exc:
            log.warning('FCM tick error: %s', exc)
    return delivered, stale


def _purge_tokens(app, stale_tokens):
    """Delete dead FCM tokens so we stop buzzing corpses. Best-effort."""
    if not stale_tokens:
        return
    try:
        from app import db
        from app.models.user import UserDevice
        with app.app_context():
            UserDevice.query.filter(
                UserDevice.push_token.in_(stale_tokens),
            ).update(
                {'push_token': None, 'push_platform': None},
                synchronize_session=False,
            )
            db.session.commit()
    except Exception as exc:
        log.warning('FCM token purge failed: %s', exc)


def _send_async(app, tokens, data, collapse_key=None):
    def run():
        _, stale = send_tick(tokens, data, collapse_key=collapse_key)
        _purge_tokens(app, stale)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()


def recipient_tokens(chat_id, sender_id):
    """FCM tokens that should buzz for a new message in [chat_id].

    Skips the sender, muted members, devices with notifications off and
    rows without a token. Imported lazily to keep module import light.
    """
    from app.models.chat import ChatMember
    from app.models.user import UserDevice
    members = ChatMember.query.filter_by(
        chat_id=chat_id, is_deleted=False,
    ).all()
    targets = [
        m.user_id for m in members
        if m.user_id != sender_id and not m.is_muted
    ]
    if not targets:
        return []
    devices = UserDevice.query.filter(
        UserDevice.user_id.in_(targets),
        UserDevice.is_deleted.is_(False),
        UserDevice.notifications_enabled.is_(True),
        UserDevice.push_token.isnot(None),
    ).all()
    return [d.push_token for d in devices if d.push_token]


def notify_new_message(app, chat_id, sender_id):
    """Fire a wake-up tick after a message lands. Never raises, never
    blocks the request: token lookup is one cheap query, HTTP runs in a
    daemon thread."""
    try:
        if not push_configured():
            return
        tokens = recipient_tokens(chat_id, sender_id)
        if not tokens:
            return
        _send_async(
            app, tokens,
            {'kind': 'tick', 'chat_id': str(chat_id)},
            collapse_key=f'chat-{chat_id}',
        )
    except Exception as exc:
        log.warning('FCM notify failed: %s', exc)


def notify_test(app, user_id):
    """Self-test tick to the caller's own devices. Returns delivered count
    (synchronous: the settings screen awaits the result)."""
    from app.models.user import UserDevice
    tokens = [
        d.push_token for d in UserDevice.query.filter(
            UserDevice.user_id == user_id,
            UserDevice.is_deleted.is_(False),
            UserDevice.push_token.isnot(None),
        ).all() if d.push_token
    ]
    if not tokens or not push_configured():
        return 0
    delivered, stale = send_tick(
        tokens, {'kind': 'test'}, collapse_key='self-test',
    )
    try:
        _purge_tokens(app, stale)
    except Exception:
        pass
    return delivered
