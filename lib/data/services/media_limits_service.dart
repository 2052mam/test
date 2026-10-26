import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Client-side view of the admin panel's upload policy.
///
/// The server enforces per-category size limits (and can disable a category
/// entirely); this service mirrors them so the app can refuse an oversized
/// file *before* spending minutes uploading it over a slow connection, with
/// the same message the server would have returned. Anything unknown —
/// limits not fetched yet, an older server without the endpoint — means
/// "no local opinion" and the server stays the only authority.
class MediaLimitsService {
  MediaLimitsService._();

  static final MediaLimitsService instance = MediaLimitsService._();

  static const _labels = {
    'image': 'عکس',
    'video': 'ویدیو',
    'audio': 'موسیقی و فایل صوتی',
    'voice': 'پیام صوتی',
    'file': 'فایل',
  };

  static const _imageExts = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'svg', 'heic', 'heif',
  };
  static const _videoExts = {
    'mp4', 'mov', 'webm', 'mkv', 'avi', 'flv', 'm4v', '3gp', 'mpeg', 'mpg',
    'ogv',
  };
  static const _audioExts = {
    'mp3', 'ogg', 'm4a', 'wav', 'flac', 'aac', 'wma', 'opus', 'aiff', 'amr',
  };

  final Map<String, ({int? limitBytes, bool enabled})> _limits = {};
  String? _userId;
  DateTime? _fetchedAt;
  Future<void>? _loading;

  /// The category a send falls under, mirroring the server's rules: the
  /// message type wins, and a generic file keeps its extension's category.
  static String categoryFor({required String messageType, String? fileName}) {
    switch (messageType) {
      case 'voice':
        return 'voice';
      case 'image':
      case 'sticker':
      case 'gif':
        return 'image';
      case 'video':
      case 'video_note':
      case 'round_video':
        return 'video';
      case 'audio':
      case 'music':
        return 'audio';
    }
    final ext = (fileName ?? '').contains('.')
        ? fileName!.split('.').last.toLowerCase()
        : '';
    if (_imageExts.contains(ext)) return 'image';
    if (_videoExts.contains(ext)) return 'video';
    if (_audioExts.contains(ext)) return 'audio';
    return 'file';
  }

  Future<void> ensureLoaded(ApiService api, {String? userId}) async {
    final fresh = _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < const Duration(minutes: 5) &&
        _userId == userId;
    if (fresh) return;
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final loading = _load(api, userId);
    _loading = loading;
    try {
      await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<void> _load(ApiService api, String? userId) async {
    try {
      final res = await api.get('/media/limits');
      final raw = res['limits'] as Map<String, dynamic>? ?? const {};
      _limits.clear();
      raw.forEach((category, value) {
        if (value is Map) {
          _limits[category] = (
            limitBytes: (value['limit_bytes'] as num?)?.toInt(),
            enabled: value['enabled'] as bool? ?? true,
          );
        }
      });
      _userId = userId;
      _fetchedAt = DateTime.now();
    } catch (error) {
      // Older server or offline: no local opinion, the server still decides.
      debugPrint('MediaLimitsService could not load limits: $error');
    }
  }

  /// Refetches on the next send (used after the server rejects a file, so a
  /// limit the admin just changed is picked up immediately).
  void invalidate() {
    _fetchedAt = null;
  }

  @visibleForTesting
  void seedForTest(Map<String, ({int? limitBytes, bool enabled})> limits) {
    _limits
      ..clear()
      ..addAll(limits);
    _fetchedAt = DateTime.now();
  }

  /// Returns the refusal to show the user, or null when the file may go up.
  ApiException? check({required String category, required int sizeBytes}) {
    final rule = _limits[category];
    if (rule == null) return null;
    final label = _labels[category] ?? 'فایل';
    if (!rule.enabled) {
      return ApiException(
        statusCode: 403,
        message: 'ارسال $label توسط مدیریت غیرفعال شده است.',
        code: 'uploads_disabled',
      );
    }
    final limit = rule.limitBytes;
    if (limit != null && sizeBytes > limit) {
      return ApiException(
        statusCode: 413,
        message:
            'حجم فایل بیش از حد مجاز است. حداکثر حجم مجاز برای $label ${_formatMb(limit)} مگابایت است.',
        code: 'file_too_large',
      );
    }
    return null;
  }

  static String _formatMb(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb == mb.roundToDouble()
        ? mb.toInt().toString()
        : mb.toStringAsFixed(1);
  }
}
