import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/api_constants.dart';
import 'storage_service.dart';

/// Offline-first media vault (Item 5).
///
/// Every photo/video/voice/file that this device **sends** or **opens** is
/// copied into the app's private cache directory and indexed on disk. The
/// copy is kept regardless of whether the recipient ever downloads it, so the
/// chat history stays usable — viewable, re-downloadable, re-sendable and
/// forwardable — even if the server loses all of its data.
///
/// The index is a plain JSON file next to the binaries; it is rebuilt from the
/// directory contents when it is missing or corrupt, so a partially written
/// index can never make previously cached media unreachable.
class MediaCacheService {
  MediaCacheService._();

  static final MediaCacheService instance = MediaCacheService._();

  static const String _dirName = 'media_cache';
  static const String _indexName = 'index.json';

  Directory? _dir;
  Map<String, CachedMedia> _index = {};
  Future<void>? _initializing;
  bool _ready = false;

  /// Overridable for tests: the root under which the cache directory lives.
  @visibleForTesting
  static Future<Directory> Function()? rootDirectoryOverride;

  /// Overridable for tests: performs the authenticated GET for remote media.
  @visibleForTesting
  static Future<Uint8List?> Function(Uri uri, Map<String, String> headers)?
      downloaderOverride;

  Future<void> init() => _initializing ??= _init();

  Future<void> _init() async {
    try {
      final root = await (rootDirectoryOverride?.call() ??
          getApplicationDocumentsDirectory());
      final dir = Directory('${root.path}/$_dirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      await _loadIndex();
      _ready = true;
    } catch (error) {
      debugPrint('MediaCacheService init failed: $error');
      _ready = false;
    }
  }

  Future<void> _ensureReady() async {
    if (_ready) return;
    _initializing ??= _init();
    await _initializing;
  }

  File get _indexFile => File('${_dir!.path}/$_indexName');

  Future<void> _loadIndex() async {
    final file = _indexFile;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          _index = {
            for (final entry in decoded.entries)
              if (entry.value is Map)
                entry.key as String: CachedMedia.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                ),
          };
          // Drop entries whose binary disappeared (user cleared storage).
          _index.removeWhere((_, item) => !File(item.path).existsSync());
          return;
        }
      } catch (error) {
        debugPrint('MediaCacheService index unreadable, rebuilding: $error');
      }
    }
    _index = await _rebuildIndexFromDisk();
    await _saveIndex();
  }

  Future<Map<String, CachedMedia>> _rebuildIndexFromDisk() async {
    final rebuilt = <String, CachedMedia>{};
    await for (final entity in _dir!.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == _indexName) continue;
      // Stored files are named "<mediaId>__<originalName>".
      final separator = name.indexOf('__');
      if (separator <= 0) continue;
      final mediaId = name.substring(0, separator);
      rebuilt[mediaId] = CachedMedia(
        mediaId: mediaId,
        path: entity.path,
        fileName: name.substring(separator + 2),
        sizeBytes: await entity.length(),
        savedAt: (await entity.stat()).modified,
      );
    }
    return rebuilt;
  }

  Future<void> _saveIndex() async {
    if (_dir == null) return;
    try {
      await _indexFile.writeAsString(
        jsonEncode({
          for (final entry in _index.entries) entry.key: entry.value.toJson(),
        }),
        flush: true,
      );
    } catch (error) {
      debugPrint('MediaCacheService could not persist index: $error');
    }
  }

  String _sanitize(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = cleaned.isEmpty ? 'file' : cleaned;
    return trimmed.length <= 120 ? trimmed : trimmed.substring(0, 120);
  }

  /// Everything currently held on this device, newest first.
  Future<List<CachedMedia>> entries() async {
    await _ensureReady();
    final list = _index.values.toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return list;
  }

  Future<CachedMedia?> lookup(String? mediaId) async {
    if (mediaId == null || mediaId.isEmpty) return null;
    await _ensureReady();
    final entry = _index[mediaId];
    if (entry == null) return null;
    if (!File(entry.path).existsSync()) {
      _index.remove(mediaId);
      unawaited(_saveIndex());
      return null;
    }
    return entry;
  }

  Future<File?> fileFor(String? mediaId) async {
    final entry = await lookup(mediaId);
    return entry == null ? null : File(entry.path);
  }

  bool hasCachedSync(String? mediaId) =>
      mediaId != null && _ready && _index.containsKey(mediaId);

  /// The on-disk path of a cached file, synchronously, for widgets that must
  /// decide between a local file and the network during build (offline
  /// playback of photos, videos, voice notes and music).
  String? localPathSync(String? mediaId) {
    if (mediaId == null || mediaId.isEmpty || !_ready) return null;
    final entry = _index[mediaId];
    if (entry == null) return null;
    return File(entry.path).existsSync() ? entry.path : null;
  }

  /// Store a file the user is sending, so the sender keeps their own copy
  /// even when the server (or the recipient) never keeps one.
  Future<CachedMedia?> storeOutgoing({
    required String mediaId,
    required File source,
    String? fileName,
    String? chatId,
    String? messageId,
    String? mediaType,
  }) async {
    await _ensureReady();
    if (!_ready || _dir == null) return null;
    try {
      final name = _sanitize(
        fileName ?? source.uri.pathSegments.last,
      );
      final target = File('${_dir!.path}/${_sanitize(mediaId)}__$name');
      if (target.path != source.path) {
        await source.copy(target.path);
      }
      return await _record(
        mediaId: mediaId,
        path: target.path,
        fileName: name,
        chatId: chatId,
        messageId: messageId,
        mediaType: mediaType,
      );
    } catch (error) {
      debugPrint('MediaCacheService could not store outgoing media: $error');
      return null;
    }
  }

  /// Store bytes that were just downloaded/viewed.
  Future<CachedMedia?> storeBytes({
    required String mediaId,
    required Uint8List bytes,
    String? fileName,
    String? chatId,
    String? messageId,
    String? mediaType,
  }) async {
    await _ensureReady();
    if (!_ready || _dir == null) return null;
    try {
      final name = _sanitize(fileName ?? '$mediaId.bin');
      final target = File('${_dir!.path}/${_sanitize(mediaId)}__$name');
      await target.writeAsBytes(bytes, flush: true);
      return await _record(
        mediaId: mediaId,
        path: target.path,
        fileName: name,
        chatId: chatId,
        messageId: messageId,
        mediaType: mediaType,
      );
    } catch (error) {
      debugPrint('MediaCacheService could not store bytes: $error');
      return null;
    }
  }

  /// Copies a photo the image widget cache already downloaded (keyed by
  /// [url]) into the vault under [mediaId]. Bubble photos render through
  /// that cache, so a photo once *seen* in a chat becomes viewable offline
  /// without ever downloading it a second time. No-op when not cached yet.
  Future<void> storeFromImageCache(String? mediaId, String url) async {
    if (mediaId == null || mediaId.isEmpty || url.isEmpty) return;
    try {
      if (await fileFor(mediaId) != null) return;
      final info = await DefaultCacheManager().getFileFromCache(url);
      final file = info?.file;
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final dot = file.path.lastIndexOf('.');
      final extension = dot > 0 && dot < file.path.length - 1
          ? file.path.substring(dot + 1).toLowerCase()
          : 'jpg';
      final fileName = '$mediaId.$extension';
      await storeBytes(
        mediaId: mediaId,
        bytes: bytes,
        fileName: fileName,
        mediaType: 'image',
      );
    } catch (_) {}
  }

  Future<CachedMedia> _record({
    required String mediaId,
    required String path,
    required String fileName,
    String? chatId,
    String? messageId,
    String? mediaType,
  }) async {
    final entry = CachedMedia(
      mediaId: mediaId,
      path: path,
      fileName: fileName,
      sizeBytes: await File(path).length(),
      savedAt: DateTime.now(),
      chatId: chatId,
      messageId: messageId,
      mediaType: mediaType,
    );
    _index[mediaId] = entry;
    await _saveIndex();
    return entry;
  }

  /// Read media, preferring the local copy. Falls back to the network and
  /// caches whatever it fetched, so the next read works fully offline.
  Future<Uint8List?> bytesFor({
    required String? mediaId,
    String? remoteUrl,
    String? token,
    String? fileName,
    String? chatId,
    String? messageId,
    String? mediaType,
  }) async {
    final cached = await fileFor(mediaId);
    if (cached != null) return cached.readAsBytes();
    if (mediaId == null || mediaId.isEmpty) return null;

    final url = remoteUrl?.isNotEmpty == true
        ? remoteUrl!
        : '${ApiConstants.baseUrl}/media/$mediaId';
    final uri = Uri.parse(
      url.startsWith('http')
          ? url
          : '${ApiConstants.baseUrl}${url.startsWith('/') ? '' : '/'}$url',
    );
    final authToken = token ?? StorageService.getToken();
    final headers = <String, String>{
      if (authToken != null && authToken.isNotEmpty)
        'Authorization': 'Bearer $authToken',
    };
    try {
      final bytes = downloaderOverride != null
          ? await downloaderOverride!(uri, headers)
          : await _fetch(uri, headers);
      if (bytes == null) return null;
      await storeBytes(
        mediaId: mediaId,
        bytes: bytes,
        fileName: fileName,
        chatId: chatId,
        messageId: messageId,
        mediaType: mediaType,
      );
      return bytes;
    } catch (error) {
      debugPrint('MediaCacheService download failed: $error');
      return null;
    }
  }

  Future<Uint8List?> _fetch(Uri uri, Map<String, String> headers) async {
    final response = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    return response.bodyBytes;
  }

  Future<int> totalBytes() async {
    await _ensureReady();
    return _index.values.fold<int>(0, (sum, item) => sum + item.sizeBytes);
  }

  Future<void> remove(String mediaId) async {
    await _ensureReady();
    final entry = _index.remove(mediaId);
    if (entry != null) {
      try {
        final file = File(entry.path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      await _saveIndex();
    }
  }

  /// Clears the whole vault. Deliberately explicit: the point of the cache is
  /// that it survives everything else, so only the user may wipe it.
  Future<void> clear() async {
    await _ensureReady();
    for (final entry in _index.values.toList()) {
      try {
        final file = File(entry.path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _index = {};
    await _saveIndex();
  }

  static String formatBytes(int bytes, [int decimals = 1]) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    var value = bytes.toDouble();
    while (value >= 1024 && index < suffixes.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(index == 0 ? 0 : decimals)} ${suffixes[index]}';
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _index = {};
    _dir = null;
    _ready = false;
    _initializing = null;
  }
}

class CachedMedia {
  const CachedMedia({
    required this.mediaId,
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.savedAt,
    this.chatId,
    this.messageId,
    this.mediaType,
  });

  final String mediaId;
  final String path;
  final String fileName;
  final int sizeBytes;
  final DateTime savedAt;
  final String? chatId;
  final String? messageId;
  final String? mediaType;

  File get file => File(path);

  Map<String, dynamic> toJson() => {
        'media_id': mediaId,
        'path': path,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'saved_at': savedAt.toIso8601String(),
        'chat_id': chatId,
        'message_id': messageId,
        'media_type': mediaType,
      };

  factory CachedMedia.fromJson(Map<String, dynamic> json) => CachedMedia(
        mediaId: json['media_id'] as String,
        path: json['path'] as String,
        fileName: json['file_name'] as String? ?? 'file',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        savedAt:
            DateTime.tryParse(json['saved_at'] as String? ?? '') ?? DateTime.now(),
        chatId: json['chat_id'] as String?,
        messageId: json['message_id'] as String?,
        mediaType: json['media_type'] as String?,
      );
}
