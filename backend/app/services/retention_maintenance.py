"""Rolling metadata backup and 72-hour chat-attachment retention.

This deliberately keeps message rows and media metadata. Only local media blobs
attached to chat image/video/voice/audio/file messages are removed. Story media,
profile photos, sticker assets, and saved GIF assets are protected even when
also referenced by a chat message.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import sqlite3
import subprocess
import tempfile
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy.engine import make_url

from app import db
from app.models.chat import Chat
from app.models.gif import SavedGif
from app.models.media import MediaFile
from app.models.message import Message
from app.models.profile import UserPhoto
from app.models.sticker import Sticker, StickerPack
from app.models.story import Story
from app.models.user import User

log = logging.getLogger(__name__)

RETENTION_HOURS = 72
BACKUP_INTERVAL_HOURS = 72
BACKUP_FILENAME = 'reynooo-chat-metadata-latest.zip'
CHAT_ATTACHMENT_TYPES = (
    'image', 'video', 'voice', 'audio', 'music', 'file', 'gif',
    'video_note', 'round_video',
)
_BATCH_SIZE = 200


def _safe_backup_dir(app) -> Path:
    configured = os.environ.get('BACKUP_DIR') or app.config.get('BACKUP_DIR')
    if not configured or not os.path.isabs(configured):
        raise RuntimeError('Set BACKUP_DIR to an absolute directory outside public_html.')

    backup_dir = Path(configured).resolve()
    upload_dir = Path(app.config['UPLOAD_FOLDER']).resolve()
    for left, right in ((backup_dir, upload_dir), (upload_dir, backup_dir)):
        try:
            common = Path(os.path.commonpath((str(left), str(right))))
        except ValueError:
            continue
        if common == left or common == right:
            raise RuntimeError('BACKUP_DIR and UPLOAD_FOLDER must be separate trees.')

    document_root = os.environ.get('DOCUMENT_ROOT')
    if document_root:
        public_root = Path(document_root).resolve()
        try:
            if os.path.commonpath((str(backup_dir), str(public_root))) == str(public_root):
                raise RuntimeError('BACKUP_DIR must be outside DOCUMENT_ROOT/public_html.')
        except ValueError:
            pass

    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(backup_dir, 0o700)
    except OSError:
        log.warning('Could not tighten permissions on BACKUP_DIR; verify it is private.')
    return backup_dir


def _mysql_defaults_file(url, directory: Path) -> str:
    if not url.database or not url.username:
        raise RuntimeError('DATABASE_URL must include the MySQL database and user.')
    values = {
        'user': url.username,
        'password': url.password or '',
        'host': url.host or 'localhost',
    }
    if url.port:
        values['port'] = str(url.port)
    socket = url.query.get('unix_socket')
    if socket:
        values['socket'] = str(socket)

    def quote(value: str) -> str:
        if '\n' in value or '\r' in value:
            raise RuntimeError('DATABASE_URL contains an invalid MySQL option value.')
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

    fd, path = tempfile.mkstemp(prefix='.mysql-client-', dir=directory, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as config:
            config.write('[client]\n')
            for key, value in values.items():
                config.write(f'{key}={quote(value)}\n')
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path


def _stream_mysql_dump(url, archive: zipfile.ZipFile, directory: Path) -> None:
    executable = shutil.which('mysqldump')
    if executable is None:
        raise RuntimeError('mysqldump is not installed; database backup was not created.')
    defaults_file = _mysql_defaults_file(url, directory)
    try:
        args = [
            executable,
            f'--defaults-extra-file={defaults_file}',
            '--single-transaction',
            '--quick',
            '--skip-lock-tables',
            '--databases',
            url.database,
        ]
        # TemporaryFile is private and lets subprocess.run enforce its timeout
        # without buffering a large SQL dump in memory or blocking on a pipe.
        with tempfile.TemporaryFile() as dump_file, tempfile.TemporaryFile() as stderr_file:
            result = subprocess.run(
                args,
                stdin=subprocess.DEVNULL,
                stdout=dump_file,
                stderr=stderr_file,
                timeout=600,
                check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f'mysqldump failed with exit status {result.returncode}; media purge was skipped.'
                )
            if dump_file.tell() == 0:
                raise RuntimeError('mysqldump returned an empty database dump; media purge was skipped.')
            dump_file.seek(0)
            with archive.open('database.sql', 'w') as output:
                shutil.copyfileobj(dump_file, output, length=1024 * 1024)
    finally:
        try:
            os.unlink(defaults_file)
        except OSError:
            pass


def _write_database_entry(app, archive: zipfile.ZipFile, backup_dir: Path) -> str:
    url = make_url(app.config['SQLALCHEMY_DATABASE_URI'])
    if url.drivername.startswith('mysql'):
        _stream_mysql_dump(url, archive, backup_dir)
        return 'database.sql'
    if url.drivername.startswith('sqlite'):
        fd, snapshot_path = tempfile.mkstemp(prefix='.sqlite-snapshot-', dir=backup_dir)
        os.close(fd)
        try:
            raw = db.engine.raw_connection()
            try:
                source = getattr(raw, 'driver_connection', None) or raw.connection
                with sqlite3.connect(snapshot_path) as destination:
                    source.backup(destination)
            finally:
                raw.close()
            archive.write(snapshot_path, arcname='database.sqlite3')
        finally:
            try:
                os.unlink(snapshot_path)
            except OSError:
                pass
        return 'database.sqlite3'
    raise RuntimeError(f'Unsupported database driver for backup: {url.drivername}')


def create_metadata_backup(app, now: datetime | None = None) -> Path:
    """Atomically replace the one private ZIP; never include uploaded blobs."""
    now = now or datetime.utcnow()
    backup_dir = _safe_backup_dir(app)
    latest = backup_dir / BACKUP_FILENAME
    fd, temporary_path = tempfile.mkstemp(prefix='.metadata-backup-', suffix='.zip', dir=backup_dir)
    os.close(fd)
    try:
        with zipfile.ZipFile(
            temporary_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            database_entry = _write_database_entry(app, archive, backup_dir)
            archive.writestr(
                'manifest.json',
                json.dumps({
                    'created_at_utc': now.isoformat(timespec='seconds') + 'Z',
                    'kind': 'database_and_chat_metadata',
                    'media_blobs_included': False,
                    'database_entry': database_entry,
                }, sort_keys=True),
            )
        with zipfile.ZipFile(temporary_path, 'r') as archive:
            corrupt_entry = archive.testzip()
            if corrupt_entry is not None:
                raise RuntimeError(f'Backup ZIP verification failed at {corrupt_entry}.')
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, latest)
        return latest
    finally:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass


def _protected_url_media_ids() -> set[str]:
    """Resolve legacy URL-only references once per maintenance pass."""
    url_columns = (
        User.avatar_url,
        Chat.avatar_url,
        UserPhoto.photo_url,
        Sticker.file_url,
        StickerPack.thumbnail_url,
        SavedGif.gif_url,
        SavedGif.preview_url,
    )
    protected: set[str] = set()
    for column in url_columns:
        for row in db.session.query(column).filter(column.isnot(None)).all():
            value = row[0] or ''
            marker = '/media/'
            if marker not in value:
                continue
            media_id = value.split(marker, 1)[1].split('?', 1)[0].split('/', 1)[0].strip()
            if media_id:
                protected.add(media_id)
    return protected


def _protected_media_ids(media_ids: list[str], url_media_ids: set[str] | None = None) -> set[str]:
    if not media_ids:
        return set()
    candidates = set(media_ids)
    protected = (url_media_ids or set()).intersection(candidates)
    for model in (Story, UserPhoto, SavedGif, Sticker):
        protected.update(
            row[0] for row in db.session.query(model.media_id).filter(
                model.media_id.in_(media_ids),
            ).all() if row[0]
        )
    return protected


def _stored_path(upload_root: Path, stored_name: str | None) -> Path | None:
    if not stored_name or Path(stored_name).name != stored_name:
        return None
    path = (upload_root / stored_name).resolve()
    try:
        if os.path.commonpath((str(upload_root), str(path))) != str(upload_root):
            return None
    except ValueError:
        return None
    return path


def _delete_media_files(upload_root: Path, media: MediaFile) -> None:
    main_path = _stored_path(upload_root, media.stored_name)
    if main_path is None:
        raise RuntimeError('Stored media path is unsafe; refusing to remove it.')
    paths = [main_path]
    if media.thumbnail_path:
        thumbnail = Path(media.thumbnail_path)
        if not thumbnail.is_absolute():
            thumbnail = upload_root / thumbnail
        thumbnail = thumbnail.resolve()
        try:
            inside_uploads = os.path.commonpath((str(upload_root), str(thumbnail))) == str(upload_root)
        except ValueError:
            inside_uploads = False
        if inside_uploads:
            paths.append(thumbnail)
        else:
            log.warning('Skipping a thumbnail outside UPLOAD_FOLDER for media id %s.', media.id)
    for path in paths:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            raise RuntimeError('A media file could not be removed; it will be retried.') from exc


def _iter_expired_chat_attachment_batches(now: datetime):
    """Keyset-page eligible media IDs so large libraries stay memory-bounded."""
    cutoff = now - timedelta(hours=RETENTION_HOURS)
    message_reference = db.session.query(Message.id).filter(
        Message.media_id == MediaFile.id,
        Message.message_type.in_(CHAT_ATTACHMENT_TYPES),
        Message.is_scheduled.is_(False),
    ).exists()
    base_query = MediaFile.query.filter(
        MediaFile.created_at.isnot(None),
        MediaFile.created_at <= cutoff,
        message_reference,
    )
    protected_url_ids = _protected_url_media_ids()
    last_id = None
    while True:
        query = base_query
        if last_id is not None:
            query = query.filter(MediaFile.id > last_id)
        batch_ids = [row[0] for row in query.order_by(MediaFile.id.asc())
                     .limit(_BATCH_SIZE).with_entities(MediaFile.id).all()]
        if not batch_ids:
            return
        last_id = batch_ids[-1]
        protected = _protected_media_ids(batch_ids, protected_url_ids)
        eligible = [media_id for media_id in batch_ids if media_id not in protected]
        if eligible:
            yield eligible


def _mark_media_expired(media_ids: list[str], now: datetime) -> list[str]:
    rows = MediaFile.query.filter(
        MediaFile.id.in_(media_ids), MediaFile.is_deleted.is_(False),
    ).all()
    newly_marked = []
    for media in rows:
        media.is_deleted = True
        media.deleted_at = now
        newly_marked.append(media.id)
    if rows:
        db.session.commit()
    return newly_marked


def _restore_expiration_marks(media_ids: list[str]) -> None:
    for start in range(0, len(media_ids), _BATCH_SIZE):
        rows = MediaFile.query.filter(
            MediaFile.id.in_(media_ids[start:start + _BATCH_SIZE]),
            MediaFile.is_deleted.is_(True),
        ).all()
        for media in rows:
            media.is_deleted = False
            media.deleted_at = None
        if rows:
            db.session.commit()


def _remove_expired_blobs(app, now: datetime) -> int:
    upload_root = Path(app.config['UPLOAD_FOLDER']).resolve()
    upload_root.mkdir(parents=True, exist_ok=True)
    removed = 0
    for batch_ids in _iter_expired_chat_attachment_batches(now):
        rows = MediaFile.query.filter(
            MediaFile.id.in_(batch_ids), MediaFile.is_deleted.is_(True),
        ).all()
        for media in rows:
            try:
                _delete_media_files(upload_root, media)
                removed += 1
            except Exception:
                db.session.rollback()
                log.exception('Could not remove one expired chat attachment; it will be retried.')
    return removed


def purge_expired_chat_attachments(app, now: datetime | None = None) -> int:
    """Remove >72-hour chat blobs while keeping message rows and attachment metadata."""
    now = now or datetime.utcnow()
    for batch_ids in _iter_expired_chat_attachment_batches(now):
        _mark_media_expired(batch_ids, now)
    return _remove_expired_blobs(app, now)


def backup_is_due(backup_path: Path, now: datetime | None = None) -> bool:
    now = now or datetime.utcnow()
    try:
        modified = datetime.utcfromtimestamp(backup_path.stat().st_mtime)
    except OSError:
        return True
    try:
        with zipfile.ZipFile(backup_path, 'r') as archive:
            manifest = json.loads(archive.read('manifest.json'))
            database_entry = manifest.get('database_entry')
            if (manifest.get('kind') != 'database_and_chat_metadata'
                    or manifest.get('media_blobs_included') is not False
                    or database_entry not in ('database.sqlite3', 'database.sql')
                    or set(archive.namelist()) != {'manifest.json', database_entry}):
                return True
    except (OSError, ValueError, KeyError, zipfile.BadZipFile):
        log.warning('The current metadata ZIP is invalid; a fresh backup is required.')
        return True
    return now - modified >= timedelta(hours=BACKUP_INTERVAL_HOURS)


def run_maintenance(app, now: datetime | None = None) -> dict[str, object]:
    """Hourly cPanel cron: back up the updated metadata before deleting blobs."""
    now = now or datetime.utcnow()
    backup_dir = _safe_backup_dir(app)
    backup_path = backup_dir / BACKUP_FILENAME
    backup_due = backup_is_due(backup_path, now)

    newly_marked: list[str] = []
    for batch_ids in _iter_expired_chat_attachment_batches(now):
        newly_marked.extend(_mark_media_expired(batch_ids, now))
    if backup_due:
        try:
            create_metadata_backup(app, now)
        except Exception:
            # Files have not yet been removed, so reverting the availability
            # marker leaves messages and attachments usable if the ZIP fails.
            _restore_expiration_marks(newly_marked)
            raise

    removed = _remove_expired_blobs(app, now)
    log.info(
        'Retention maintenance complete: backup_created=%s expired_chat_attachments=%s',
        backup_due,
        removed,
    )
    return {'backup_created': backup_due, 'expired_chat_attachments': removed}
