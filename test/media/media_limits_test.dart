import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/media_limits_service.dart';

void main() {
  group('category mapping mirrors the server', () {
    test('message types map to their categories', () {
      expect(
        MediaLimitsService.categoryFor(messageType: 'voice'),
        'voice',
      );
      expect(MediaLimitsService.categoryFor(messageType: 'image'), 'image');
      expect(
        MediaLimitsService.categoryFor(messageType: 'video_note'),
        'video',
      );
      expect(MediaLimitsService.categoryFor(messageType: 'audio'), 'audio');
    });

    test('generic files keep the category of their extension', () {
      expect(
        MediaLimitsService.categoryFor(
          messageType: 'file',
          fileName: 'backup.zip',
        ),
        'file',
      );
      expect(
        MediaLimitsService.categoryFor(
          messageType: 'file',
          fileName: 'clip.mp4',
        ),
        'video',
      );
      expect(
        MediaLimitsService.categoryFor(
          messageType: 'file',
          fileName: 'song.mp3',
        ),
        'audio',
      );
    });
  });

  group('local pre-check', () {
    setUp(() {
      MediaLimitsService.instance.seedForTest({
        'image': (limitBytes: 10 * 1024 * 1024, enabled: true),
        'video': (limitBytes: null, enabled: false),
      });
    });

    test('files at or below the limit pass', () {
      expect(
        MediaLimitsService.instance.check(
          category: 'image',
          sizeBytes: 10 * 1024 * 1024,
        ),
        isNull,
      );
    });

    test('oversized files are refused with the server-style error', () {
      final error = MediaLimitsService.instance.check(
        category: 'image',
        sizeBytes: 10 * 1024 * 1024 + 1,
      );
      expect(error, isNotNull);
      expect(error!.statusCode, 413);
      expect(error.code, 'file_too_large');
      expect(error.message, contains('10'));
    });

    test('disabled categories are refused', () {
      final error = MediaLimitsService.instance.check(
        category: 'video',
        sizeBytes: 1,
      );
      expect(error!.statusCode, 403);
      expect(error.code, 'uploads_disabled');
    });

    test('unknown categories have no local opinion', () {
      expect(
        MediaLimitsService.instance.check(category: 'file', sizeBytes: 1 << 40),
        isNull,
      );
    });
  });
}
