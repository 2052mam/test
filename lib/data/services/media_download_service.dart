import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/constants/api_constants.dart';
import 'gallery_saver_service.dart';
import 'media_cache_service.dart';
import 'storage_service.dart';

class MediaDownloadService {
  /// Downloads media to the user's Downloads/Documents folder.
  ///
  /// The app's offline vault is consulted first (Item 5): once a file has been
  /// sent or opened on this device it can always be saved again, even when the
  /// server no longer has it. A network download is additionally mirrored into
  /// the vault so the next save works offline.
  /// Throws [MediaSaveException] when the file could not actually be stored,
  /// so the UI can show a truthful error instead of a fake "saved" toast.
  static Future<String?> downloadMedia({
    required String mediaUrl,
    required String fileName,
    String? token,
    String? mediaId,
    String? chatId,
    String? messageId,
    String? messageType,
    Function(int received, int total)? onProgress,
  }) async {
    try {
      final authToken = token ?? StorageService.getToken();
      final resolvedId = mediaId ?? _mediaIdFromUrl(mediaUrl);

      final cached = await MediaCacheService.instance.fileFor(resolvedId);
      if (cached != null) {
        final bytes = await cached.readAsBytes();
        onProgress?.call(bytes.length, bytes.length);
        return _publish(fileName, bytes, messageType);
      }

      final fullUrl = mediaUrl.startsWith('http')
          ? mediaUrl
          : '${ApiConstants.baseUrl}${mediaUrl.startsWith('/') ? '' : '/'}$mediaUrl';
      
      final uri = Uri.parse(fullUrl).replace(queryParameters: {'download': '1'});

      final request = http.Request('GET', uri);
      if (authToken != null && authToken.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $authToken';
      }

      final response = await http.Client().send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Download failed with status ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      int received = 0;
      final List<int> bytes = [];

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress(received, total);
        }
      }

      final Uint8List fileBytes = Uint8List.fromList(bytes);

      // Keep our own copy so the file survives server-side data loss.
      if (resolvedId != null && resolvedId.isNotEmpty) {
        await MediaCacheService.instance.storeBytes(
          mediaId: resolvedId,
          bytes: fileBytes,
          fileName: fileName,
          chatId: chatId,
          messageId: messageId,
        );
      }

      if (kIsWeb) {
        // Web download behavior if running on web
        return fileName;
      }
      return _publish(fileName, fileBytes, messageType);
    } catch (e) {
      debugPrint('Error downloading file: $e');
      rethrow;
    }
  }

  /// Publishes bytes into the device's shared storage (Point 6).
  ///
  /// Previously this wrote to `getDownloadsDirectory()`, which returns null on
  /// Android, so everything silently landed in app-private storage that no
  /// gallery or file manager can see. Now it goes through MediaStore and a
  /// failure is reported rather than swallowed.
  static Future<String> _publish(
    String fileName,
    Uint8List bytes,
    String? messageType,
  ) async {
    final kind = GallerySaverService.kindFor(
      messageType: messageType,
      fileName: fileName,
    );
    final result = await GallerySaverService.saveBytes(
      bytes: bytes,
      fileName: fileName,
      kind: kind,
      mimeType: GallerySaverService.guessMimeType(fileName),
    );
    if (result.isSuccess) return result.uri!;
    throw MediaSaveException(result.status, result.error);
  }

  /// `/api/v1/media/<id>` (with or without query/host) → `<id>`.
  static String? _mediaIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segments = uri?.pathSegments ?? const <String>[];
    final index = segments.lastIndexOf('media');
    if (index >= 0 && index + 1 < segments.length) return segments[index + 1];
    return segments.isEmpty ? null : segments.last;
  }

  static String formatBytes(int bytes, [int decimals = 1]) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = (bytes.toString().length - 1) ~/ 3;
    if (i >= suffixes.length) i = suffixes.length - 1;
    double num = bytes / (1 << (i * 10));
    return '${num.toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}

/// Raised when media could not be written to the device's shared storage.
class MediaSaveException implements Exception {
  MediaSaveException(this.status, this.details);

  final SaveStatus status;
  final String? details;

  bool get isPermissionProblem =>
      status == SaveStatus.permissionDenied ||
      status == SaveStatus.permissionPermanentlyDenied;

  /// True when the user must enable the permission from system settings.
  bool get needsSettings => status == SaveStatus.permissionPermanentlyDenied;

  @override
  String toString() => details ?? status.name;
}
