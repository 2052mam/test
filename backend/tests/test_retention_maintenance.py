from datetime import datetime, timedelta
import json
import os
import zipfile

import pytest

from app import db
from app.models.gif import SavedGif
from app.models.media import MediaFile
from app.models.message import Message
from app.models.profile import UserPhoto
from app.models.sticker import Sticker, StickerPack
from app.models.story import Story
from app.services.message_payloads import serialize_messages
from app.services.retention_maintenance import (
    BACKUP_FILENAME,
    create_metadata_backup,
    run_maintenance,
)


@pytest.fixture()
def app_ctx(app):
    with app.app_context():
        yield app


def _media(app, media_id, filename, created_at):
    path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
    with open(path, 'wb') as blob:
        blob.write(b'private media bytes')
    media = MediaFile(
        id=media_id,
        uploader_id='alice',
        original_name=filename,
        stored_name=filename,
        mime_type='image/png',
        file_size=os.path.getsize(path),
        file_path=path,
        media_type='image',
        created_at=created_at,
    )
    db.session.add(media)
    return media, path


def test_retention_keeps_message_history_and_marks_attachment_expired(
        app_ctx, app, client, auth, monkeypatch, tmp_path):
    now = datetime.utcnow()
    old_at = now - timedelta(hours=73)
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'private-backups'))
    media, file_path = _media(app, 'expired-media', 'expired.png', old_at)
    message = Message(
        id='retained-message', chat_id='chat', sender_id='alice',
        message_type='image', content='A caption that must remain',
        media_id=media.id, created_at=old_at,
    )
    reply = Message(
        id='retained-reply', chat_id='chat', sender_id='alice',
        message_type='text', content='Reply remains', reply_to_id=message.id,
        created_at=now,
    )
    db.session.add_all([message, reply])
    db.session.commit()

    result = run_maintenance(app, now)

    assert result == {'backup_created': True, 'expired_chat_attachments': 1}
    assert not os.path.exists(file_path)
    assert db.session.get(Message, message.id) is not None
    stored_media = db.session.get(MediaFile, media.id)
    assert stored_media.is_deleted is True
    assert stored_media.deleted_at == now

    payload = serialize_messages([message], 'alice')[0]
    assert payload['content'] == 'A caption that must remain'
    assert payload['media_id'] == media.id
    assert payload['media_url'] is None
    assert payload['media_expired'] is True
    reply_payload = serialize_messages([reply], 'alice')[0]['reply_to']
    assert reply_payload['media_url'] is None
    assert reply_payload['media_expired'] is True
    assert client.get(f'/api/v1/media/{media.id}', headers=auth('alice')).status_code == 404


def test_retention_protects_profile_story_sticker_and_saved_gif_media(
        app_ctx, app, monkeypatch, tmp_path):
    now = datetime.utcnow()
    old_at = now - timedelta(hours=80)
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'private-backups'))
    protected = []
    for media_id, filename in [
        ('story-media', 'story.png'),
        ('profile-media', 'profile.png'),
        ('legacy-profile-media', 'legacy-profile.png'),
        ('sticker-media', 'sticker.png'),
        ('saved-gif-media', 'saved.gif'),
    ]:
        media, path = _media(app, media_id, filename, old_at)
        protected.append((media, path))
        db.session.add(Message(
            id=f'msg-{media_id}', chat_id='chat', sender_id='alice',
            message_type=(
                'gif' if media_id == 'saved-gif-media'
                else 'sticker' if media_id == 'sticker-media' else 'image'
            ),
            content='', media_id=media_id, created_at=old_at,
        ))

    scheduled_media, scheduled_path = _media(app, 'scheduled-media', 'scheduled.png', old_at)
    protected.append((scheduled_media, scheduled_path))
    db.session.add(Message(
        id='scheduled-media-message', chat_id='chat', sender_id='alice',
        message_type='image', content='', media_id=scheduled_media.id,
        is_scheduled=True, created_at=old_at,
    ))

    db.session.add(Story(
        id='story-protect', user_id='alice', story_type='image',
        media_id='story-media', expires_at=now + timedelta(days=1),
    ))
    db.session.add(UserPhoto(
        id='photo-protect', user_id='alice', photo_url='/api/v1/media/profile-media',
        media_id='profile-media', is_main=True,
    ))
    db.session.add(UserPhoto(
        id='legacy-photo-protect', user_id='alice',
        photo_url='/api/v1/media/legacy-profile-media', media_id=None,
        is_main=False,
    ))
    pack = StickerPack(id='pack-protect', name='protect-test', title='Test')
    db.session.add(pack)
    db.session.flush()
    db.session.add(Sticker(
        id='sticker-protect', pack_id=pack.id, file_url='/api/v1/media/sticker-media',
        media_id='sticker-media',
    ))
    db.session.add(SavedGif(
        id='gif-protect', user_id='alice', media_id='saved-gif-media',
        gif_url='/api/v1/media/saved-gif-media',
    ))
    db.session.commit()

    result = run_maintenance(app, now)

    assert result['expired_chat_attachments'] == 0
    assert all(os.path.exists(path) for _, path in protected)
    assert all(media.is_deleted is False for media, _ in protected)


def test_unsaved_chat_gif_attachment_expires(app_ctx, app, monkeypatch, tmp_path):
    now = datetime.utcnow()
    old_at = now - timedelta(hours=73)
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'private-backups'))
    media, path = _media(app, 'chat-gif', 'chat.gif', old_at)
    db.session.add(Message(
        id='chat-gif-message', chat_id='chat', sender_id='alice',
        message_type='gif', content='', media_id=media.id, created_at=old_at,
    ))
    db.session.commit()

    result = run_maintenance(app, now)

    assert result['expired_chat_attachments'] == 1
    assert not os.path.exists(path)


def test_failed_due_backup_restores_availability_and_skips_blob_deletion(
        app_ctx, app, monkeypatch, tmp_path):
    now = datetime.utcnow()
    old_at = now - timedelta(hours=73)
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'private-backups'))
    media, path = _media(app, 'backup-failure-media', 'retry.png', old_at)
    db.session.add(Message(
        id='backup-failure-message', chat_id='chat', sender_id='alice',
        message_type='image', content='', media_id=media.id, created_at=old_at,
    ))
    db.session.commit()

    def fail_backup(*_args, **_kwargs):
        raise RuntimeError('simulated backup failure')

    monkeypatch.setattr('app.services.retention_maintenance.create_metadata_backup', fail_backup)
    with pytest.raises(RuntimeError, match='simulated backup failure'):
        run_maintenance(app, now)

    db.session.expire_all()
    assert os.path.exists(path)
    assert db.session.get(MediaFile, media.id).is_deleted is False


def test_retention_retries_blob_for_already_expired_record(app_ctx, app, monkeypatch, tmp_path):
    now = datetime.utcnow()
    old_at = now - timedelta(hours=73)
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'private-backups'))
    media, path = _media(app, 'retry-media', 'retry-existing.png', old_at)
    media.is_deleted = True
    media.deleted_at = now - timedelta(minutes=1)
    db.session.add(Message(
        id='retry-message', chat_id='chat', sender_id='alice',
        message_type='image', content='', media_id=media.id, created_at=old_at,
    ))
    db.session.commit()

    result = run_maintenance(app, now)

    assert result['expired_chat_attachments'] == 1
    assert not os.path.exists(path)


def test_metadata_backup_is_verified_and_replaced_in_place(app_ctx, app, monkeypatch, tmp_path):
    backup_dir = tmp_path / 'private-backups'
    monkeypatch.setenv('BACKUP_DIR', str(backup_dir))
    first_time = datetime.utcnow()
    first = create_metadata_backup(app, first_time)
    assert first.name == BACKUP_FILENAME
    with zipfile.ZipFile(first) as archive:
        assert set(archive.namelist()) == {'database.sqlite3', 'manifest.json'}
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['media_blobs_included'] is False
        assert manifest['kind'] == 'database_and_chat_metadata'
        assert archive.testzip() is None
    assert oct(first.stat().st_mode & 0o777) == '0o600'

    create_metadata_backup(app, first_time + timedelta(hours=72))
    backups = [path for path in backup_dir.iterdir() if path.suffix == '.zip']
    assert backups == [first]
    with zipfile.ZipFile(first) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        assert manifest['created_at_utc'] == (first_time + timedelta(hours=72)).isoformat(timespec='seconds') + 'Z'
