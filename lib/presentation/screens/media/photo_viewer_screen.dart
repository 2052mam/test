import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/utils/save_feedback.dart';
import 'package:flutter/material.dart';

import '../../../data/services/media_cache_service.dart';

import '../../../data/services/media_download_service.dart';
import '../../widgets/media/media_labels.dart';
import '../../widgets/media/photo_canvas.dart';

class PhotoViewerScreen extends StatefulWidget {
  final String url;
  final String? token;
  final String? caption;

  /// Used by the offline vault (Item 5) so a saved photo can be re-downloaded
  /// even when the server no longer has the original.
  final String? mediaId;
  final String? chatId;
  final String? messageId;

  const PhotoViewerScreen({
    super.key,
    required this.url,
    this.token,
    this.caption,
    this.mediaId,
    this.chatId,
    this.messageId,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  // A photo already in the offline vault opens from disk — full screen,
  // zoomable, and with no connection at all.
  late final ImageProvider _image = _resolveImage();

  ImageProvider _resolveImage() {
    final localPath = MediaCacheService.instance.localPathSync(widget.mediaId);
    if (localPath != null) return FileImage(File(localPath));
    return CachedNetworkImageProvider(
      widget.url,
      headers: widget.token == null
          ? null
          : {'Authorization': 'Bearer ${widget.token}'},
    );
  }

  @override
  void initState() {
    super.initState();
    // Once the network photo has actually been displayed, mirror the bytes
    // the image cache already fetched into the offline vault, so viewing a
    // photo full-screen also makes it available with no connection.
    final mediaId = widget.mediaId;
    if (mediaId != null &&
        MediaCacheService.instance.localPathSync(mediaId) == null) {
      final stream = _image.resolve(const ImageConfiguration());
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (_, __) {
          stream.removeListener(listener);
          MediaCacheService.instance.storeFromImageCache(mediaId, widget.url);
        },
        onError: (_, __) => stream.removeListener(listener),
      );
      stream.addListener(listener);
    }
  }
  bool _showChrome = true;
  bool _downloading = false;

  Future<void> _downloadPhoto() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final filename = 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await MediaDownloadService.downloadMedia(
        mediaUrl: widget.url,
        fileName: filename,
        token: widget.token,
        mediaId: widget.mediaId,
        chatId: widget.chatId,
        messageId: widget.messageId,
        messageType: 'image',
      );
      if (mounted) {
        setState(() => _downloading = false);
        SaveFeedback.success(context, fileName: filename);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloading = false);
        SaveFeedback.failure(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = MediaLabels.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PhotoCanvas(
            image: _image,
            onTap: () => setState(() => _showChrome = !_showChrome),
          ),
          if (_showChrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: labels.close,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                      Text(
                        labels.photo,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: labels.isFa ? 'دانلود عکس' : 'Download photo',
                        onPressed: _downloading ? null : _downloadPhoto,
                        icon: _downloading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.download_rounded,
                                color: Colors.white,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showChrome && widget.caption?.isNotEmpty == true)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: ColoredBox(
                color: Colors.black54,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.all(16),
                  child: Text(
                    widget.caption!,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
