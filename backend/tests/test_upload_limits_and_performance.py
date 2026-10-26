"""Admin upload limits (Settings) + transfer performance (ETag/gzip).

Covers the four operator controls:
* per-category size limits and category switches, enforced at upload time
  (streamed, so oversized files never land on disk) and again at send time;
* per-user caps (the stricter limit wins);
* the admin web page and admin JSON API that manage them;
* ETag/304 + gzip on the polling endpoints and the batched chat list.
"""
import gzip
import io
import os

import pytest
from flask_jwt_extended import create_access_token

from app import db
from app.models.media import MediaFile
from app.models.user import User
from app.services import app_settings

SECRET = 'sm-admin-x9k2p7'


def upload_raw(client, auth, name='alice', filename='photo.png', data=None,
               **fields):
    payload = {'file': (io.BytesIO(data or b'x' * 2048), filename)}
    payload.update(fields)
    return client.post('/api/v1/media/upload', headers=auth(name),
                       data=payload)


def set_limits(app, **kwargs):
    with app.app_context():
        app_settings.save_upload_settings(**kwargs)


# --------------------------------------------------------------------------
# upload enforcement
# --------------------------------------------------------------------------
def test_limits_endpoint_reports_defaults(client, auth):
    response = client.get('/api/v1/media/limits', headers=auth('alice'))
    assert response.status_code == 200
    limits = response.json['limits']
    assert set(limits) == {'image', 'video', 'audio', 'voice', 'file'}
    assert limits['image']['limit_mb'] == 10.0
    assert limits['image']['enabled'] is True


def test_upload_below_limit_still_works(client, auth, upload):
    media_id, _ = upload()
    assert media_id


def test_oversized_upload_is_rejected_and_never_stored(app, client, auth):
    set_limits(app, limits_mb={'image': 0.001})  # ~1 KB
    response = upload_raw(client, auth, data=b'x' * 8192)
    assert response.status_code == 413
    assert response.json['code'] == 'file_too_large'
    assert response.json['category'] == 'image'
    with app.app_context():
        assert MediaFile.query.count() == 0
        upload_dir = app.config['UPLOAD_FOLDER']
        assert os.listdir(upload_dir) == []


def test_upload_exactly_at_the_limit_is_accepted(app, client, auth):
    data = b'x' * 2048
    set_limits(app, limits_mb={'image': len(data) / (1024 * 1024)})
    response = upload_raw(client, auth, data=data)
    assert response.status_code == 201


def test_disabled_category_is_rejected(app, client, auth):
    set_limits(app, enabled={'video': False})
    response = upload_raw(client, auth, filename='clip.mp4', data=b'x' * 64)
    assert response.status_code == 403
    assert response.json['code'] == 'uploads_disabled'
    assert response.json['category'] == 'video'


def test_declared_voice_notes_use_the_voice_limit(app, client, auth):
    set_limits(app, limits_mb={'voice': 0.001, 'audio': 50.0})
    response = upload_raw(
        client, auth, filename='note.m4a', data=b'x' * 8192,
        media_kind='voice')
    assert response.status_code == 413
    assert response.json['category'] == 'voice'
    # The same bytes as plain music are fine under the audio limit.
    response = upload_raw(client, auth, filename='song.m4a', data=b'x' * 8192)
    assert response.status_code == 201


def test_archive_files_use_the_file_limit(app, client, auth):
    set_limits(app, limits_mb={'file': 0.001})
    response = upload_raw(client, auth, filename='backup.zip',
                          data=b'x' * 8192)
    assert response.status_code == 413
    assert response.json['category'] == 'file'


def test_per_user_cap_wins_over_category_limit(app, client, auth):
    with app.app_context():
        app_settings.set_user_limit_mb('alice', 0.001)
    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 413
    # bob has no cap: the (generous) category limit applies.
    assert upload_raw(client, auth, name='bob',
                      data=b'x' * 8192).status_code == 201
    with app.app_context():
        app_settings.set_user_limit_mb('alice', None)
    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 201


def test_send_is_rechecked_against_current_limits(app, client, auth, upload):
    media_id, _ = upload(filename='song.mp3', data=b'x' * 4096)
    # The limit drops after the upload: attaching must now fail too.
    set_limits(app, limits_mb={'audio': 0.001})
    response = client.post('/api/v1/messages/', headers=auth('alice'), json={
        'chat_id': 'chat', 'message_type': 'audio', 'media_id': media_id,
        'content': 'song',
    })
    assert response.status_code == 413
    assert response.json['code'] == 'file_too_large'


def test_file_message_keeps_its_true_category(app, client, auth, upload):
    media_id, _ = upload(filename='backup.zip', data=b'x' * 4096)
    set_limits(app, limits_mb={'video': 50.0, 'file': 0.001})
    response = client.post('/api/v1/messages/', headers=auth('alice'), json={
        'chat_id': 'chat', 'message_type': 'file', 'media_id': media_id,
        'content': 'backup.zip',
    })
    # An archive sent as a generic file counts against the file limit.
    assert response.status_code == 413
    assert response.json['category'] == 'file'


# --------------------------------------------------------------------------
# admin controls (web panel + JSON API)
# --------------------------------------------------------------------------
@pytest.fixture()
def panel(app, client, monkeypatch):
    monkeypatch.setenv('ADMIN_USERNAME', 'superadmin')
    monkeypatch.setenv('ADMIN_PASSWORD', 'panel-test-password')
    response = client.post(f'/{SECRET}/login', data={
        'username': 'superadmin', 'password': 'panel-test-password'})
    assert response.status_code == 302
    return client


def csrf(client):
    with client.session_transaction() as session:
        return session['admin_csrf']


def test_panel_settings_page_saves_limits(panel, client, auth):
    page = client.get(f'/{SECRET}/settings')
    assert page.status_code == 200
    assert 'محدودیت حجم آپلود' in page.get_data(as_text=True)

    form = {f'limit_{c}': '10' for c in app_settings.CATEGORIES}
    form.update({f'enabled_{c}': 'on' for c in app_settings.CATEGORIES})
    form['limit_image'] = '0.001'
    form['csrf_token'] = csrf(client)
    saved = client.post(f'/{SECRET}/settings', data=form)
    assert saved.status_code == 302

    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 413
    page = client.get(f'/{SECRET}/settings')
    assert 'value="0.001"' in page.get_data(as_text=True)


def test_panel_sets_and_clears_a_user_cap(panel, client, auth):
    form = {'user_id': 'alice', 'max_mb': '0.001', 'back': 'user',
            'csrf_token': csrf(client)}
    assert client.post(f'/{SECRET}/settings/user-limit',
                       data=form).status_code == 302
    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 413

    form['max_mb'] = ''
    assert client.post(f'/{SECRET}/settings/user-limit',
                       data=form).status_code == 302
    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 201


@pytest.fixture()
def admin_auth(app, auth):
    with app.app_context():
        db.session.add(User(
            id='root', email='root@example.test', username='root',
            display_name='Root', password_hash='unused',
            totp_secret='JBSWY3DPEHPK3PXP', is_admin=True))
        db.session.commit()
    with app.app_context():
        token = create_access_token(identity='root')
    return {'Authorization': f'Bearer {token}'}


def test_admin_api_manages_upload_settings(client, admin_auth, auth):
    response = client.get('/api/v1/admin/settings/uploads',
                          headers=admin_auth)
    assert response.status_code == 200
    assert response.json['limits_mb']['image'] == 10.0

    response = client.put('/api/v1/admin/settings/uploads',
                          headers=admin_auth,
                          json={'limits_mb': {'image': 0.001}})
    assert response.status_code == 200
    assert upload_raw(client, auth, data=b'x' * 8192).status_code == 413

    response = client.post('/api/v1/admin/users/alice/upload-limit',
                           headers=admin_auth, json={'max_mb': 5})
    assert response.status_code == 200
    assert response.json['max_mb'] == 5.0


def test_admin_api_rejects_non_admins(client, auth):
    assert client.get('/api/v1/admin/settings/uploads',
                      headers=auth('alice')).status_code == 403
    assert client.put('/api/v1/admin/settings/uploads',
                      headers=auth('alice'),
                      json={'limits_mb': {'image': 1}}).status_code == 403


def test_settings_survive_without_the_table(app, client, auth):
    """An installation that has not run the schema upgrade keeps working."""
    with app.app_context():
        db.session.execute(db.text('DROP TABLE app_settings'))
        db.session.commit()
        assert app_settings.get_upload_settings()['limits_mb']['image'] == 10.0
    assert upload_raw(client, auth, data=b'x' * 64).status_code == 201


# --------------------------------------------------------------------------
# transfer performance: ETag/304, gzip, batched chat list
# --------------------------------------------------------------------------
def test_polling_endpoints_answer_304_when_unchanged(client, auth):
    first = client.get('/api/v1/chats/', headers=auth('alice'))
    assert first.status_code == 200
    etag = first.headers.get('ETag')
    assert etag
    assert first.headers.get('Cache-Control') == 'private, no-cache'

    second = client.get('/api/v1/chats/', headers={
        **auth('alice'), 'If-None-Match': etag})
    assert second.status_code == 304
    assert second.data == b''


def test_large_json_is_gzipped(client, auth, make_message):
    for i in range(60):
        make_message(f'bulk-{i:03}', content='x' * 120)
    plain = client.get('/api/v1/messages/chat', headers=auth('alice'))
    packed = client.get('/api/v1/messages/chat', headers={
        **auth('alice'), 'Accept-Encoding': 'gzip'})
    assert packed.headers.get('Content-Encoding') == 'gzip'
    assert len(packed.data) < len(plain.data)
    import json as _json
    decoded = _json.loads(gzip.decompress(packed.data))
    assert len(decoded['messages']) == 50  # default page size, unchanged
    # Each encoding has its own validator, and both revalidate to 304.
    for response in (plain, packed):
        again = client.get('/api/v1/messages/chat', headers={
            **auth('alice'),
            'Accept-Encoding': 'gzip' if response is packed else 'identity',
            'If-None-Match': response.headers['ETag']})
        assert again.status_code == 304


def test_chat_list_still_reports_last_message_and_unread(
        client, auth, make_message):
    from datetime import datetime, timedelta
    make_message('m1', sender_id='bob', content='first',
                 created_at=datetime(2026, 9, 7, 12, 0, 0))
    make_message('m2', sender_id='bob', content='second',
                 created_at=datetime(2026, 9, 7, 12, 0, 1))
    make_message('m3', sender_id='alice', content='mine',
                 created_at=datetime(2026, 9, 7, 12, 0, 2))

    listing = client.get('/api/v1/chats/', headers=auth('alice')).json
    chat = next(c for c in listing['chats'] if c['id'] == 'chat')
    assert chat['last_message']['content'] == 'mine'
    assert chat['unread_count'] == 2  # only bob's messages count for alice
    assert chat['other_user']['username'] == 'bob'

    bob_view = client.get('/api/v1/chats/', headers=auth('bob')).json
    bob_chat = next(c for c in bob_view['chats'] if c['id'] == 'chat')
    assert bob_chat['unread_count'] == 1

    client.post('/api/v1/messages/chat/chat/read', headers=auth('alice'),
                json={})
    listing = client.get('/api/v1/chats/', headers=auth('alice')).json
    chat = next(c for c in listing['chats'] if c['id'] == 'chat')
    assert chat['unread_count'] == 0
