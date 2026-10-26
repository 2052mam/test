/// Point 6 (critical): media is actually written to shared storage, and a
/// failure is reported as a failure.
///
/// The old path called `getDownloadsDirectory()`, which returns null on
/// Android, so files silently went to the app's private sandbox — invisible to
/// the gallery and any file manager — while the UI said "saved". Nothing ever
/// asked for a storage permission either.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/gallery_saver_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(GallerySaverService.resetForTest);

  group('kindFor routes files to the right shared collection', () {
    test('by message type', () {
      expect(GallerySaverService.kindFor(messageType: 'image'),
          SavedMediaKind.image);
      expect(GallerySaverService.kindFor(messageType: 'video'),
          SavedMediaKind.video);
      expect(GallerySaverService.kindFor(messageType: 'voice'),
          SavedMediaKind.audio);
      expect(GallerySaverService.kindFor(messageType: 'music'),
          SavedMediaKind.audio);
      expect(GallerySaverService.kindFor(messageType: 'file'),
          SavedMediaKind.file);
    });

    test('falls back to the file extension', () {
      expect(GallerySaverService.kindFor(fileName: 'holiday.JPG'),
          SavedMediaKind.image);
      expect(GallerySaverService.kindFor(fileName: 'clip.mp4'),
          SavedMediaKind.video);
      expect(GallerySaverService.kindFor(fileName: 'song.mp3'),
          SavedMediaKind.audio);
      expect(GallerySaverService.kindFor(fileName: 'report.pdf'),
          SavedMediaKind.file);
    });
  });

  test('guessMimeType covers the formats the app sends', () {
    expect(GallerySaverService.guessMimeType('a.jpg'), 'image/jpeg');
    expect(GallerySaverService.guessMimeType('a.PNG'), 'image/png');
    expect(GallerySaverService.guessMimeType('a.mp4'), 'video/mp4');
    expect(GallerySaverService.guessMimeType('a.m4a'), 'audio/mp4');
    expect(GallerySaverService.guessMimeType('a.opus'), 'audio/opus');
    expect(GallerySaverService.guessMimeType('a.unknown'), isNull);
  });

  group('saveFile', () {
    late Directory temp;
    late File source;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('saver-test-');
      source = File('${temp.path}/photo.jpg');
      await source.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
    });

    tearDown(() async => temp.delete(recursive: true));

    test('reports the published location on success', () async {
      String? seenName;
      String? seenMime;
      SavedMediaKind? seenKind;
      GallerySaverService.permissionOverride = (_) async => true;
      GallerySaverService.platformSaveOverride =
          (path, name, mime, kind) async {
        seenName = name;
        seenMime = mime;
        seenKind = kind;
        return 'content://media/external/images/media/42';
      };

      final result = await GallerySaverService.saveFile(
        source: source,
        fileName: 'photo.jpg',
        kind: SavedMediaKind.image,
        mimeType: 'image/jpeg',
      );

      expect(result.isSuccess, isTrue);
      expect(result.uri, 'content://media/external/images/media/42');
      expect(seenName, 'photo.jpg');
      expect(seenMime, 'image/jpeg');
      expect(seenKind, SavedMediaKind.image);
    });

    test('a denied permission is NOT reported as success', () async {
      GallerySaverService.permissionOverride = (_) async => false;
      GallerySaverService.platformSaveOverride = (_, __, ___, ____) async {
        fail('must not try to write without permission');
      };

      final result = await GallerySaverService.saveFile(
        source: source,
        fileName: 'photo.jpg',
        kind: SavedMediaKind.image,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, anyOf(SaveStatus.permissionDenied,
          SaveStatus.permissionPermanentlyDenied));
    });

    test('a platform error surfaces as a failure, not a success', () async {
      GallerySaverService.permissionOverride = (_) async => true;
      GallerySaverService.platformSaveOverride = (_, __, ___, ____) async =>
          throw Exception('MediaStore rejected the insert');

      final result = await GallerySaverService.saveFile(
        source: source,
        fileName: 'photo.jpg',
        kind: SavedMediaKind.image,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, SaveStatus.failed);
      expect(result.error, contains('MediaStore'));
    });

    test('an empty platform location is a failure', () async {
      GallerySaverService.permissionOverride = (_) async => true;
      GallerySaverService.platformSaveOverride =
          (_, __, ___, ____) async => '';

      final result = await GallerySaverService.saveFile(
        source: source,
        fileName: 'photo.jpg',
        kind: SavedMediaKind.image,
      );

      expect(result.isSuccess, isFalse);
      expect(result.status, SaveStatus.failed);
    });

    test('a missing source file fails instead of pretending', () async {
      GallerySaverService.permissionOverride = (_) async => true;
      final result = await GallerySaverService.saveFile(
        source: File('${temp.path}/does-not-exist.jpg'),
        fileName: 'gone.jpg',
        kind: SavedMediaKind.image,
      );
      expect(result.isSuccess, isFalse);
      expect(result.status, SaveStatus.failed);
    });
  });

  test('ensurePermission skips the dialog on scoped storage (API 29+)',
      () async {
    // On Android 10+ a MediaStore insert into our own collection needs no
    // permission, and on 13+ the legacy dialog cannot be granted at all.
    GallerySaverService.androidSdkIntForTest = 33;
    expect(await GallerySaverService.ensurePermission(SavedMediaKind.image),
        isTrue);
  });
}
