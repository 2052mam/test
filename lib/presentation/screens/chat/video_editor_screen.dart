import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/utils/app_locale.dart';

/// Result of editing a video: the original file plus edit instructions.
/// Trimming is applied server-side (ffmpeg) at upload; [muted] is enforced
/// at playback by every client, so a muted video stays silent everywhere.
class EditedVideo {
  final File file;
  final int startMs;
  final int endMs; // -1 = until the end
  final bool muted;
  final double? cropX;
  final double? cropY;
  final double? cropWidth;
  final double? cropHeight;
  const EditedVideo({
    required this.file,
    this.startMs = 0,
    this.endMs = -1,
    this.muted = false,
    this.cropX,
    this.cropY,
    this.cropWidth,
    this.cropHeight,
  });

  bool get isTrimmed => startMs > 0 || endMs >= 0;
  bool get isCropped => cropWidth != null && cropHeight != null;
  bool get isEdited => isTrimmed || isCropped || muted;
}

/// Telegram-like internal video editor: preview, trim start/end, mute toggle.
/// Returns an [EditedVideo] via Navigator.pop.
///
/// The previous version had no listener on the controller, so the UI never
/// reflected real playback state, and it issued a `seekTo` on every slider
/// tick which flooded the decoder. This version keeps a single source of
/// truth: the controller drives the UI, the UI drives the controller once per
/// gesture, and playback is confined to the selected trim window.
class VideoEditorScreen extends StatefulWidget {
  final File videoFile;
  const VideoEditorScreen({super.key, required this.videoFile});

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen> {
  /// A trim window shorter than this makes no sense (and breaks ffmpeg).
  static const _minTrimMs = 500;

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _muted = false;

  Duration _total = Duration.zero;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;
  Duration _position = Duration.zero;

  bool _scrubbing = false;
  Timer? _seekDebounce;

  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  String _cropMode = 'Free';
  String? _cropDragMode;
  Offset _cropDragOrigin = Offset.zero;
  Rect _cropDragStart = const Rect.fromLTRB(0, 0, 1, 1);

  double get _videoAspect {
    final aspect = _controller?.value.aspectRatio ?? 1;
    return aspect.isFinite && aspect > 0 ? aspect : 1;
  }

  double? get _targetAspect => switch (_cropMode) {
        'Original' => _videoAspect,
        '1:1' => 1,
        '3:4' => 3 / 4,
        '4:3' => 4 / 3,
        '16:9' => 16 / 9,
        '9:16' => 9 / 16,
        _ => null,
      };

  double? get _normalizedCropAspect {
    final target = _targetAspect;
    return target == null ? null : target / _videoAspect;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(widget.videoFile);
    _controller = c;
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final duration = c.value.duration;
      if (duration <= Duration.zero) {
        setState(() {
          _failed = true;
          _ready = false;
        });
        return;
      }
      c.addListener(_onControllerTick);
      await c.setLooping(false);
      setState(() {
        _ready = true;
        _total = duration;
        _start = Duration.zero;
        _end = duration;
        _position = Duration.zero;
      });
      await c.play();
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = false;
          _failed = true;
        });
      }
    }
  }

  /// Single place where playback state reaches the UI.
  void _onControllerTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !mounted) return;
    final pos = c.value.position;

    // Keep playback inside the trim window: loop back to the start.
    if (!_scrubbing && c.value.isPlaying) {
      if (pos >= _end) {
        c.seekTo(_start);
        return;
      }
      if (pos < _start - const Duration(milliseconds: 300)) {
        c.seekTo(_start);
        return;
      }
    }
    // Only rebuild when the visible playhead actually moved (~10 fps), so the
    // controller's high-frequency ticks cannot thrash the widget tree.
    if ((pos - _position).abs() >= const Duration(milliseconds: 100) ||
        pos == Duration.zero) {
      setState(() => _position = pos);
    }
  }

  @override
  void dispose() {
    _seekDebounce?.cancel();
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerTick);
    c?.dispose();
    super.dispose();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0 : 1);
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= _end || c.value.position < _start) {
        await c.seekTo(_start);
      }
      await c.play();
    }
    if (mounted) setState(() {});
  }

  /// Debounced seek: the decoder is only asked once the user pauses moving.
  void _seekDebounced(Duration to) {
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 60), () {
      _controller?.seekTo(to);
    });
  }

  void _onRangeChanged(RangeValues values) {
    final startMs = values.start.round();
    final endMs = values.end.round();
    // Guarantee a valid, non-inverted window.
    if (endMs - startMs < _minTrimMs) return;
    final movedStart = (startMs - _start.inMilliseconds).abs() >
        (endMs - _end.inMilliseconds).abs();
    setState(() {
      _scrubbing = true;
      _start = Duration(milliseconds: startMs);
      _end = Duration(milliseconds: endMs);
    });
    _seekDebounced(movedStart ? _start : _end);
  }

  Future<void> _onRangeChangeEnd(RangeValues values) async {
    setState(() => _scrubbing = false);
    final c = _controller;
    if (c == null) return;
    if (c.value.position < _start || c.value.position > _end) {
      await c.seekTo(_start);
    }
  }

  void _onPositionChanged(double ms) {
    setState(() {
      _scrubbing = true;
      _position = Duration(milliseconds: ms.round());
    });
    _seekDebounced(_position);
  }

  String _fmt(Duration d) {
    final safe = d.isNegative ? Duration.zero : d;
    final m = safe.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Rect _centeredCrop(double aspect) {
    final width = aspect >= 1 ? 1.0 : aspect;
    final height = aspect >= 1 ? 1 / aspect : 1.0;
    return Rect.fromLTWH((1 - width) / 2, (1 - height) / 2, width, height);
  }

  void _selectCropMode(String mode) {
    setState(() {
      _cropMode = mode;
      final aspect = _normalizedCropAspect;
      if (aspect != null) _crop = _centeredCrop(aspect);
    });
  }

  Offset _normalizedPoint(Offset local, Size size) => Offset(
        (local.dx / size.width).clamp(0.0, 1.0).toDouble(),
        (local.dy / size.height).clamp(0.0, 1.0).toDouble(),
      );

  void _onCropPanStart(DragStartDetails details, Size size) {
    final point = _normalizedPoint(details.localPosition, size);
    final corners = <String, Offset>{
      'tl': Offset(_crop.left, _crop.top),
      'tr': Offset(_crop.right, _crop.top),
      'bl': Offset(_crop.left, _crop.bottom),
      'br': Offset(_crop.right, _crop.bottom),
    };
    String? nearest;
    var nearestDistance = 0.09;
    for (final entry in corners.entries) {
      final distance = (entry.value - point).distance;
      if (distance < nearestDistance) {
        nearest = entry.key;
        nearestDistance = distance;
      }
    }
    _cropDragMode = nearest ?? (_crop.contains(point) ? 'move' : null);
    if (_cropDragMode == null) return;
    _cropDragOrigin = point;
    _cropDragStart = _crop;
  }

  void _onCropPanUpdate(DragUpdateDetails details, Size size) {
    final mode = _cropDragMode;
    if (mode == null) return;
    final point = _normalizedPoint(details.localPosition, size);
    final dx = point.dx - _cropDragOrigin.dx;
    final dy = point.dy - _cropDragOrigin.dy;
    final start = _cropDragStart;
    if (mode == 'move') {
      final left = (start.left + dx).clamp(0.0, 1.0 - start.width).toDouble();
      final top = (start.top + dy).clamp(0.0, 1.0 - start.height).toDouble();
      setState(() => _crop = Rect.fromLTWH(left, top, start.width, start.height));
      return;
    }

    final leftSide = mode.endsWith('l');
    final topSide = mode.startsWith('t');
    final anchor = Offset(
      leftSide ? start.right : start.left,
      topSide ? start.bottom : start.top,
    );
    final requested = Offset(_cropDragOrigin.dx + dx, _cropDragOrigin.dy + dy);
    final signedWidth = (requested.dx - anchor.dx) * (leftSide ? -1 : 1);
    final signedHeight = (requested.dy - anchor.dy) * (topSide ? -1 : 1);
    final lockedAspect = _normalizedCropAspect;
    double width;
    double height;
    if (lockedAspect != null) {
      final maxWidth = math.min(
        leftSide ? anchor.dx : 1 - anchor.dx,
        (topSide ? anchor.dy : 1 - anchor.dy) * lockedAspect,
      );
      if (maxWidth < 0.05) return;
      width = math.max(signedWidth, signedHeight * lockedAspect)
          .clamp(0.05, maxWidth).toDouble();
      height = width / lockedAspect;
    } else {
      final maxWidth = leftSide ? anchor.dx : 1 - anchor.dx;
      final maxHeight = topSide ? anchor.dy : 1 - anchor.dy;
      if (maxWidth < 0.05 || maxHeight < 0.05) return;
      width = signedWidth.clamp(0.05, maxWidth).toDouble();
      height = signedHeight.clamp(0.05, maxHeight).toDouble();
    }
    final rect = Rect.fromLTRB(
      leftSide ? anchor.dx - width : anchor.dx,
      topSide ? anchor.dy - height : anchor.dy,
      leftSide ? anchor.dx : anchor.dx + width,
      topSide ? anchor.dy : anchor.dy + height,
    );
    setState(() => _crop = rect);
  }

  void _done() {
    final endMs = _end.inMilliseconds >= _total.inMilliseconds - 200
        ? -1
        : _end.inMilliseconds;
    final cropped = _crop.left > 0.002 || _crop.top > 0.002 ||
        _crop.right < 0.998 || _crop.bottom < 0.998;
    Navigator.pop(
      context,
      EditedVideo(
        file: widget.videoFile,
        startMs: _start.inMilliseconds,
        endMs: endMs,
        muted: _muted,
        cropX: cropped ? _crop.left : null,
        cropY: cropped ? _crop.top : null,
        cropWidth: cropped ? _crop.width : null,
        cropHeight: cropped ? _crop.height : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final playing = c?.value.isPlaying ?? false;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(AppLocale.pick('ویرایش ویدیو', 'Edit video')),
        actions: [
          IconButton(
            tooltip: _muted ? AppLocale.pick('با صدا', 'Unmute') : AppLocale.pick('بی‌صدا', 'Mute'),
            icon: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                color: _muted ? Colors.amber : Theme.of(context).colorScheme.onSurface),
            onPressed: _ready ? _toggleMute : null,
          ),
          IconButton(
            tooltip: AppLocale.pick('تأیید', 'Done'),
            icon: const Icon(Icons.check, color: Colors.green),
            onPressed: _ready ? _done : null,
          ),
        ],
      ),
      body: _failed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.videocam_off_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant, size: 48),
                  const SizedBox(height: 8),
                  Text(AppLocale.pick('این ویدیو قابل پیش‌نمایش نیست', 'This video cannot be previewed'),
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      EditedVideo(file: widget.videoFile),
                    ),
                    child: Text(AppLocale.pick('ارسال بدون ویرایش', 'Send original')),
                  ),
                ],
              ),
            )
          : !_ready || c == null
              ? Center(
                  child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: c.value.aspectRatio <= 0
                              ? 16 / 9
                              : c.value.aspectRatio,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final size = Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              );
                              return Stack(
                                fit: StackFit.expand,
                                alignment: Alignment.center,
                                children: [
                                  GestureDetector(
                                    onTap: _togglePlay,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        VideoPlayer(c),
                                        AnimatedOpacity(
                                          opacity: playing ? 0 : 0.85,
                                          duration: const Duration(milliseconds: 180),
                                          child: const CircleAvatar(
                                            radius: 28,
                                            backgroundColor: Colors.black54,
                                            child: Icon(Icons.play_arrow,
                                                color: Colors.white, size: 36),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onPanStart: (details) =>
                                        _onCropPanStart(details, size),
                                    onPanUpdate: (details) =>
                                        _onCropPanUpdate(details, size),
                                    onPanEnd: (_) => _cropDragMode = null,
                                    child: ColoredBox(
                                      color: Colors.transparent,
                                      child: CustomPaint(
                                        painter: _VideoCropPainter(_crop),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Container(
                      color: Theme.of(context).colorScheme.surface,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${AppLocale.pick('شروع', 'Start')}: ${_fmt(_start)}',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                              Text('${AppLocale.pick('پایان', 'End')}: ${_fmt(_end)}',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                              Text('${AppLocale.pick('مدت', 'Duration')}: ${_fmt(_end - _start)}',
                                  style: TextStyle(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              AppLocale.pick('برش کادر ویدیو', 'Video crop'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 38,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final mode in const [
                                  'Free', 'Original', '1:1', '3:4', '4:3', '16:9', '9:16',
                                ])
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ChoiceChip(
                                      label: Text(mode == 'Free'
                                          ? AppLocale.pick('آزاد', 'Free')
                                          : mode == 'Original'
                                              ? AppLocale.pick('اصلی', 'Original')
                                              : mode),
                                      selected: _cropMode == mode,
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (_) => _selectCropMode(mode),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            AppLocale.pick(
                              'برای جابه‌جایی کادر آن را بکشید؛ برای تغییر اندازه گوشه‌ها را بکشید.',
                              'Drag the frame to move it; drag a corner to resize.',
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(height: 4),
                          // Playhead
                          Row(children: [
                            IconButton(
                              icon: Icon(
                                playing
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              onPressed: _togglePlay,
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                ),
                                child: Slider(
                                  value: _position.inMilliseconds
                                      .clamp(0, _total.inMilliseconds)
                                      .toDouble(),
                                  min: 0,
                                  max: _total.inMilliseconds.toDouble(),
                                  onChanged: _onPositionChanged,
                                  onChangeEnd: (_) =>
                                      setState(() => _scrubbing = false),
                                ),
                              ),
                            ),
                            Text(_fmt(_position),
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                          ]),
                          const SizedBox(height: 2),
                          Row(children: [
                            Icon(Icons.content_cut,
                                color: Theme.of(context).colorScheme.onSurfaceVariant, size: 16),
                            const SizedBox(width: 6),
                            Text(AppLocale.pick('برش', 'Trim'),
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                            Expanded(
                              child: RangeSlider(
                                values: RangeValues(
                                  _start.inMilliseconds
                                      .clamp(0, _total.inMilliseconds)
                                      .toDouble(),
                                  _end.inMilliseconds
                                      .clamp(0, _total.inMilliseconds)
                                      .toDouble(),
                                ),
                                min: 0,
                                max: _total.inMilliseconds.toDouble(),
                                labels: RangeLabels(_fmt(_start), _fmt(_end)),
                                activeColor: Theme.of(context).colorScheme.primary,
                                onChanged: _onRangeChanged,
                                onChangeEnd: _onRangeChangeEnd,
                              ),
                            ),
                          ]),
                          if (_muted)
                            Row(children: [
                              const Icon(Icons.volume_off,
                                  color: Colors.amber, size: 16),
                              const SizedBox(width: 6),
                              Text(AppLocale.pick('ویدیو بدون صدا ارسال می‌شود', 'Video will be sent without sound'),
                                  style: const TextStyle(
                                      color: Colors.amber, fontSize: 12)),
                            ]),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _VideoCropPainter extends CustomPainter {
  final Rect crop;
  const _VideoCropPainter(this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(outside, Paint()..color = Colors.black.withOpacity(0.52));
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final handlePaint = Paint()..color = Colors.white;
    final outlinePaint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final point in [
      Offset(frame.left, frame.top),
      Offset(frame.right, frame.top),
      Offset(frame.left, frame.bottom),
      Offset(frame.right, frame.bottom),
    ]) {
      canvas.drawCircle(point, 7, handlePaint);
      canvas.drawCircle(point, 7, outlinePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _VideoCropPainter oldDelegate) =>
      oldDelegate.crop != crop;
}
