import io
import os
from types import SimpleNamespace

from app import db
from app.models.media import MediaFile


def test_crop_upload_validates_complete_normalized_crop_before_saving(app, client, auth):
    response = client.post(
        '/api/v1/media/upload',
        headers=auth('alice'),
        data={
            'file': (io.BytesIO(b'fake-video'), 'clip.mp4'),
            'crop_x': '0.1',
            'crop_y': '0.1',
            'crop_width': '0.95',
            'crop_height': '0.5',
        },
    )

    assert response.status_code == 400
    with app.app_context():
        assert MediaFile.query.count() == 0
        assert os.listdir(app.config['UPLOAD_FOLDER']) == []


def test_crop_upload_applies_ffmpeg_filter_and_saves_mp4(
        app, client, auth, monkeypatch):
    calls = []

    def fake_run(command, **kwargs):
        calls.append(command)
        with open(command[-1], 'wb') as output:
            output.write(b'cropped-mp4')
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr('app.api.media.shutil.which', lambda binary: '/usr/bin/ffmpeg')
    monkeypatch.setattr('app.api.media.subprocess.run', fake_run)
    response = client.post(
        '/api/v1/media/upload',
        headers=auth('alice'),
        data={
            'file': (io.BytesIO(b'original-video'), 'clip.mov'),
            'crop_x': '0.1',
            'crop_y': '0.2',
            'crop_width': '0.8',
            'crop_height': '0.6',
            'trim_start_ms': '1000',
            'trim_end_ms': '5000',
        },
    )

    assert response.status_code == 201
    assert calls and '-vf' in calls[0]
    crop_filter = calls[0][calls[0].index('-vf') + 1]
    assert crop_filter.startswith('crop=trunc(iw*0.80000000/2)*2:')
    assert '-ss' in calls[0] and '-t' in calls[0]
    with app.app_context():
        media = db.session.get(MediaFile, response.json['id'])
        assert media is not None
        assert media.stored_name.endswith('.mp4')
        assert media.mime_type == 'video/mp4'
        with open(media.file_path, 'rb') as cropped:
            assert cropped.read() == b'cropped-mp4'
