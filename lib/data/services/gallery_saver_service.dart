import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// What kind of shared collection a file belongs in.
enum SavedMediaKind { image, video, audio, file }

/// The outcome of a save attempt, so callers can tell the user the truth
/// instead of always claiming success.
class SaveResult {
  const SaveResult._(this.status, {this.uri, this.error});

  const SaveResult.saved(String location)
      : this._(SaveStatus.saved, uri: location);
  const SaveResult.permissionDenied()
      : this._(SaveStatus.permissionDenied);
  const SaveResult.permissionPermanentlyDenied()
      : this._(SaveStatus.permissionPermanentlyDenied);
  const SaveResult.failed(String reason)
      : this._(SaveStatus.failed, error: reason);

  final SaveStatus status;

  /// Public `content://` or `file://` location of the saved copy.
  final String? uri;
  final String? error;

  bool get isSuccess => status == SaveStatus.saved;
}

enum SaveStatus { saved, permissionDenied, permissionPermanentlyDenied, failed }

/// Point 6: actually persist media where the user can find it.
///
/// The previous implementation wrote through `getDownloadsDirectory()`, which
/// returns null on Android and therefore fell back to the app's *private*
/// documents folder. Files landed somewhere no gallery or file manager can
/// see, the app still showed "saved", and nothing ever asked for permission.
///
/// This service:
///  * asks for the right permission for the OS version (and nothing on
///    Android 10+, where MediaStore needs none),
///  * hands the bytes to Android's MediaStore so the file is published into
///    Pictures/Movies/Music/Download under a `Reyno` folder,
///  * reports a real success/failure so the UI can stop lying.
class GallerySaverService {
  GallerySaverService._();

  static const MethodChannel _channel =
      MethodChannel('secure_messenger/media_store');

  /// Overridable for tests.
  @visibleForTesting
  static Future<String?> Function(
    String sourcePath,
    String fileName,
    String? mimeType,
    SavedMediaKind kind,
  )? platformSaveOverride;

  @visibleForTesting
  static Future<bool> Function(SavedMediaKind kind)? permissionOverride;

  /// Lets tests pin the Android API level instead of touching the plugin.
  @visibleForTesting
  static set androidSdkIntForTest(int? value) => _cachedSdk = value;

  @visibleForTesting
  static void resetForTest() {
    platformSaveOverride = null;
    permissionOverride = null;
    _cachedSdk = null;
  }

  /// Writes [bytes] into a temp file and publishes it to shared storage.
  static Future<SaveResult> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required SavedMediaKind kind,
    String? mimeType,
  }) async {
    File? temp;
    try {
      final dir = await getTemporaryDirectory();
      temp = File('${dir.path}/save_${DateTime.now().microsecondsSinceEpoch}_'
          '$fileName');
      await temp.writeAsBytes(bytes, flush: true);
      return await saveFile(
        source: temp,
        fileName: fileName,
        kind: kind,
        mimeType: mimeType,
      );
    } catch (error) {
      return SaveResult.failed('$error');
    } finally {
      // The published copy is independent of our scratch file.
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// Publishes an existing on-disk file into shared storage.
  static Future<SaveResult> saveFile({
    required File source,
    required String fileName,
    required SavedMediaKind kind,
    String? mimeType,
  }) async {
    if (!await source.exists()) {
      return const SaveResult.failed('source file missing');
    }

    final granted = await ensurePermission(kind);
    if (!granted) {
      // Distinguish "say no again" from "must go to Settings".
      if (!kIsWeb && Platform.isAndroid) {
        final status = await Permission.storage.status;
        if (status.isPermanentlyDenied) {
          return const SaveResult.permissionPermanentlyDenied();
        }
      }
      return const SaveResult.permissionDenied();
    }

    try {
      final override = platformSaveOverride;
      final uri = override != null
          ? await override(source.path, fileName, mimeType, kind)
          : await _platformSave(source, fileName, mimeType, kind);
      if (uri == null || uri.isEmpty) {
        return const SaveResult.failed('platform returned no location');
      }
      return SaveResult.saved(uri);
    } on PlatformException catch (error) {
      return SaveResult.failed(error.message ?? error.code);
    } catch (error) {
      return SaveResult.failed('$error');
    }
  }

  static Future<String?> _platformSave(
    File source,
    String fileName,
    String? mimeType,
    SavedMediaKind kind,
  ) async {
    if (!kIsWeb && Platform.isAndroid) {
      return _channel.invokeMethod<String>('saveFile', {
        'sourcePath': source.path,
        'fileName': fileName,
        'mimeType': mimeType,
        'kind': kind.name,
      });
    }
    // iOS/desktop: the documents directory is user-visible via Files.app.
    final dir = await getApplicationDocumentsDirectory();
    final target = File('${dir.path}/$fileName');
    await source.copy(target.path);
    return target.path;
  }

  /// Requests only what the running OS version actually needs.
  static Future<bool> ensurePermission(SavedMediaKind kind) async {
    final override = permissionOverride;
    if (override != null) return override(kind);
    if (kIsWeb || !Platform.isAndroid) return true;

    // Android 10 (API 29) and above: scoped storage means MediaStore inserts
    // into our own collection need no permission whatsoever. Asking anyway
    // would show a dialog the user cannot grant on Android 13+.
    final sdk = await _androidSdkInt();
    if (sdk >= 29) return true;

    final status = await Permission.storage.request();
    return status.isGranted || status.isLimited;
  }

  static int? _cachedSdk;

  /// Cached `Build.VERSION.SDK_INT`, used only to decide whether the legacy
  /// storage permission is still relevant.
  static Future<int> _androidSdkInt() async {
    final cached = _cachedSdk;
    if (cached != null) return cached;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _cachedSdk = info.version.sdkInt;
      return info.version.sdkInt;
    } catch (_) {
      // Assume a modern device: the worst case is skipping a permission
      // request that Android 13+ would have rejected anyway.
      return 29;
    }
  }

  /// Best-effort MIME guess from the file extension.
  static String? guessMimeType(String fileName) {
    final ext = fileName.toLowerCase().split('.').last;
    const map = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'mp3': 'audio/mpeg',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'ogg': 'audio/ogg',
      'opus': 'audio/opus',
      'wav': 'audio/wav',
      'pdf': 'application/pdf',
      'zip': 'application/zip',
      'txt': 'text/plain',
    };
    return map[ext];
  }

  /// Chooses the shared collection from a file name / message type.
  static SavedMediaKind kindFor({String? messageType, String? fileName}) {
    switch (messageType) {
      case 'image':
      case 'sticker':
        return SavedMediaKind.image;
      case 'video':
      case 'video_note':
      case 'gif':
        return SavedMediaKind.video;
      case 'voice':
      case 'music':
      case 'audio':
        return SavedMediaKind.audio;
    }
    final mime = fileName == null ? null : guessMimeType(fileName);
    if (mime == null) return SavedMediaKind.file;
    if (mime.startsWith('image/')) return SavedMediaKind.image;
    if (mime.startsWith('video/')) return SavedMediaKind.video;
    if (mime.startsWith('audio/')) return SavedMediaKind.audio;
    return SavedMediaKind.file;
  }
}
