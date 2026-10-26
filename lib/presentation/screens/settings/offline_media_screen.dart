import 'package:flutter/material.dart';

import '../../../data/services/media_cache_service.dart';
import '../../providers/locale_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Offline media vault (Item 5).
///
/// Shows everything this device is keeping locally — the photos, videos, voice
/// messages and files it sent or opened — so the user can confirm their chat
/// history remains usable even if the server ever loses its data.
class OfflineMediaScreen extends ConsumerStatefulWidget {
  const OfflineMediaScreen({super.key});

  @override
  ConsumerState<OfflineMediaScreen> createState() => _OfflineMediaScreenState();
}

class _OfflineMediaScreenState extends ConsumerState<OfflineMediaScreen> {
  List<CachedMedia> _entries = const [];
  int _totalBytes = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await MediaCacheService.instance.entries();
    final total = await MediaCacheService.instance.totalBytes();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _totalBytes = total;
      _loading = false;
    });
  }

  Future<void> _clear(bool isFa) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFa ? 'پاک کردن حافظه محلی' : 'Clear local storage'),
        content: Text(
          isFa
              ? 'پس از پاک کردن، اگر سرور هم فایل را نداشته باشد دیگر قابل بازیابی نیست. ادامه می‌دهید؟'
              : 'Once cleared, files the server no longer has cannot be recovered. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isFa ? 'لغو' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isFa ? 'پاک کردن' : 'Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MediaCacheService.instance.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isFa = ref.watch(localeProvider).languageCode == 'fa';
    return Scaffold(
      appBar: AppBar(
        title: Text(isFa ? 'حافظه آفلاین رسانه' : 'Offline media storage'),
        actions: [
          IconButton(
            key: const ValueKey('clear-offline-cache'),
            tooltip: isFa ? 'پاک کردن همه' : 'Clear all',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _entries.isEmpty ? null : () => _clear(isFa),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Card(
                    margin: const EdgeInsets.all(12),
                    child: ListTile(
                      leading: const Icon(Icons.shield_outlined, color: Colors.green),
                      title: Text(
                        isFa
                            ? '${_entries.length} فایل · ${MediaCacheService.formatBytes(_totalBytes)}'
                            : '${_entries.length} files · ${MediaCacheService.formatBytes(_totalBytes)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        isFa
                            ? 'هر عکس یا فایلی که ارسال یا باز می‌کنید روی همین دستگاه نگه داشته می‌شود؛ حتی اگر اطلاعات سرور از بین برود، از تاریخچه چت قابل مشاهده، ذخیره و ارسال دوباره است.'
                            : 'Everything you send or open stays on this device, so your history remains viewable, savable and re-sendable even if the server loses its data.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  if (_entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          isFa
                              ? 'هنوز چیزی ذخیره نشده است'
                              : 'Nothing stored yet',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    ),
                  for (final entry in _entries)
                    ListTile(
                      key: ValueKey('cached-${entry.mediaId}'),
                      leading: Icon(_iconFor(entry)),
                      title: Text(
                        entry.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        MediaCacheService.formatBytes(entry.sizeBytes),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await MediaCacheService.instance.remove(entry.mediaId);
                          await _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  IconData _iconFor(CachedMedia entry) {
    final name = entry.fileName.toLowerCase();
    if (entry.mediaType == 'image' ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (entry.mediaType == 'video' || name.endsWith('.mp4')) {
      return Icons.videocam_outlined;
    }
    if (entry.mediaType == 'audio' ||
        name.endsWith('.mp3') ||
        name.endsWith('.m4a') ||
        name.endsWith('.ogg')) {
      return Icons.audiotrack_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
