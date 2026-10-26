import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../core/utils/media_utils.dart';
import '../../../data/services/media_cache_service.dart';

class VideoNotePlayer extends StatefulWidget {
  final String url;
  final String? authToken;
  final double size;

  /// When set, a previously downloaded copy in the offline vault plays
  /// from disk; a network play is mirrored into the vault for next time.
  final String? mediaId;

  const VideoNotePlayer({super.key, required this.url, this.authToken, this.size = 220, this.mediaId});

  @override
  State<VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<VideoNotePlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final uri = Uri.parse(widget.url);
      final headers = widget.authToken != null ? {'Authorization': 'Bearer ${widget.authToken}'} : <String, String>{};
      final localPath = MediaCacheService.instance.localPathSync(widget.mediaId);
      _controller = localPath != null
          ? VideoPlayerController.file(File(localPath))
          : VideoPlayerController.networkUrl(uri, httpHeaders: headers);
      await _controller!.initialize();
      if (localPath == null && widget.mediaId != null) {
        unawaited(
          MediaCacheService.instance.bytesFor(
            mediaId: widget.mediaId,
            remoteUrl: widget.url,
            token: widget.authToken,
          ),
        );
      }
      _controller!.setLooping(true);
      setState(() => _initialized = true);
    } catch (_) {
      setState(() => _initialized = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_controller == null || !_initialized) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
      setState(() => _isPlaying = false);
    } else {
      _controller!.play();
      setState(() => _isPlaying = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2AABEE).withValues(alpha: 0.25),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
          border: Border.all(
            color: const Color(0xFF2AABEE).withValues(alpha: 0.6),
            width: 2.5,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_initialized && _controller != null)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.size.width,
                    height: _controller!.value.size.height,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              )
            else
              const Icon(Icons.videocam_rounded, color: Colors.white70, size: 48),
            if (!_isPlaying)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
              ),
            Positioned(
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_rounded, size: 13, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      _controller != null && _initialized
                          ? formatMediaDuration(_controller!.value.duration)
                          : '0:00',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
