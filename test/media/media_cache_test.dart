import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/media_cache_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('media-cache-test-');
    MediaCacheService.rootDirectoryOverride = () async => root;
    MediaCacheService.downloaderOverride = null;
    await MediaCacheService.instance.resetForTest();
    await MediaCacheService.instance.init();
  });

  tearDown(() async {
    MediaCacheService.rootDirectoryOverride = null;
    MediaCacheService.downloaderOverride = null;
    await MediaCacheService.instance.resetForTest();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<File> sourceFile(String name, String content) async {
    final file = File('${root.path}/$name');
    await file.writeAsString(content);
    return file;
  }

  test('A sent photo stays on the device even without any server call',
      () async {
    final source = await sourceFile('photo.jpg', 'binary-photo');
    final entry = await MediaCacheService.instance.storeOutgoing(
      mediaId: 'media-1',
      source: source,
      fileName: 'photo.jpg',
      chatId: 'chat',
    );
    expect(entry, isNotNull);

    // Deleting the original picked file must not lose the cached copy.
    await source.delete();
    final cached = await MediaCacheService.instance.fileFor('media-1');
    expect(cached, isNotNull);
    expect(await cached!.readAsString(), 'binary-photo');
  });

  test('Cached media survives a fresh app start (index is persisted)',
      () async {
    await MediaCacheService.instance.storeOutgoing(
      mediaId: 'media-2',
      source: await sourceFile('doc.pdf', 'pdf-bytes'),
    );
    await MediaCacheService.instance.resetForTest();
    await MediaCacheService.instance.init();
    final cached = await MediaCacheService.instance.fileFor('media-2');
    expect(await cached!.readAsString(), 'pdf-bytes');
  });

  test('A corrupt index is rebuilt from the files on disk', () async {
    await MediaCacheService.instance.storeOutgoing(
      mediaId: 'media-3',
      source: await sourceFile('clip.mp4', 'video-bytes'),
      fileName: 'clip.mp4',
    );
    await File('${root.path}/media_cache/index.json')
        .writeAsString('{not valid json');
    await MediaCacheService.instance.resetForTest();
    await MediaCacheService.instance.init();
    final cached = await MediaCacheService.instance.fileFor('media-3');
    expect(cached, isNotNull);
    expect(await cached!.readAsString(), 'video-bytes');
  });

  test('bytesFor serves the local copy without touching the network',
      () async {
    await MediaCacheService.instance.storeOutgoing(
      mediaId: 'media-4',
      source: await sourceFile('a.png', 'local-bytes'),
    );
    var downloads = 0;
    MediaCacheService.downloaderOverride = (uri, headers) async {
      downloads++;
      return Uint8List.fromList('remote'.codeUnits);
    };
    final bytes = await MediaCacheService.instance.bytesFor(mediaId: 'media-4');
    expect(String.fromCharCodes(bytes!), 'local-bytes');
    expect(downloads, 0);
  });

  test('A downloaded file is mirrored locally so the next read is offline',
      () async {
    var downloads = 0;
    MediaCacheService.downloaderOverride = (uri, headers) async {
      downloads++;
      return Uint8List.fromList('remote-bytes'.codeUnits);
    };
    final first = await MediaCacheService.instance.bytesFor(
      mediaId: 'media-5',
      fileName: 'remote.jpg',
    );
    expect(String.fromCharCodes(first!), 'remote-bytes');
    expect(downloads, 1);

    MediaCacheService.downloaderOverride = (uri, headers) async {
      downloads++;
      return null; // The server has lost the file.
    };
    final second = await MediaCacheService.instance.bytesFor(mediaId: 'media-5');
    expect(String.fromCharCodes(second!), 'remote-bytes');
    expect(downloads, 1, reason: 'the local copy is used, no new request');
  });

  test('Entries and totals reflect what is stored, and clearing wipes it',
      () async {
    await MediaCacheService.instance.storeBytes(
      mediaId: 'm-a',
      bytes: Uint8List.fromList(List.filled(10, 1)),
      fileName: 'a.bin',
    );
    await MediaCacheService.instance.storeBytes(
      mediaId: 'm-b',
      bytes: Uint8List.fromList(List.filled(20, 1)),
      fileName: 'b.bin',
    );
    expect((await MediaCacheService.instance.entries()).length, 2);
    expect(await MediaCacheService.instance.totalBytes(), 30);

    await MediaCacheService.instance.remove('m-a');
    expect((await MediaCacheService.instance.entries()).length, 1);

    await MediaCacheService.instance.clear();
    expect(await MediaCacheService.instance.entries(), isEmpty);
    expect(await MediaCacheService.instance.totalBytes(), 0);
  });

  test('Unknown ids never resolve to a file', () async {
    expect(await MediaCacheService.instance.fileFor(null), isNull);
    expect(await MediaCacheService.instance.fileFor(''), isNull);
    expect(await MediaCacheService.instance.fileFor('missing'), isNull);
  });

  test('formatBytes renders human readable sizes', () {
    expect(MediaCacheService.formatBytes(0), '0 B');
    expect(MediaCacheService.formatBytes(512), '512 B');
    expect(MediaCacheService.formatBytes(2048), '2.0 KB');
  });
}
