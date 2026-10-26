import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;

import '../../../core/utils/app_locale.dart';

/// Telegram-like internal photo editor: crop (aspect ratios), rotate, flip,
/// draw (pen colors/sizes), text overlay, then send.
/// Returns the edited [File] via Navigator.pop.
///
/// Design notes (these were the source of the old bugs):
///  * The base image is decoded ONCE and kept as a `ui.Image`; the preview
///    never re-encodes JPEG during build, so panning stays smooth.
///  * Rotate/flip/crop are *non-destructive view state* — they no longer wipe
///    the user's strokes and text.
///  * Strokes and text are stored in normalised (0..1) image space, so they
///    stay glued to the picture at any widget size and survive transforms.
class PhotoEditorScreen extends StatefulWidget {
  final File imageFile;
  const PhotoEditorScreen({super.key, required this.imageFile});

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

/// A stroke in normalised image space (0..1 on both axes).
class _DrawStroke {
  final List<Offset> points;
  final Color color;

  /// Stroke width as a fraction of the image's shortest side.
  final double width;
  _DrawStroke({required this.points, required this.color, required this.width});

  _DrawStroke copyWith({List<Offset>? points}) =>
      _DrawStroke(points: points ?? this.points, color: color, width: width);
}

/// Text overlay anchored in normalised image space.
class _TextOverlay {
  String text;
  Offset position;
  Color color;

  /// Font size as a fraction of the image height.
  double size;
  _TextOverlay({
    required this.text,
    required this.position,
    required this.color,
    required this.size,
  });
}

enum _EditorTool { draw, move }

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  final _canvasKey = GlobalKey();

  ui.Image? _image;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  // Non-destructive transform state.
  int _quarterTurns = 0;
  bool _flipH = false;
  double? _aspectRatio; // null = original or free crop
  Rect _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
  bool _freeCrop = false;
  bool _cropMode = false;
  int _cropDragEdges = 0;
  Offset? _cropDragStart;
  Rect? _cropDragStartRect;

  // Overlays (normalised coordinates).
  final List<_DrawStroke> _strokes = [];
  final List<_TextOverlay> _texts = [];
  _DrawStroke? _activeStroke;

  Color _penColor = Colors.red;
  double _penWidth = 6; // logical px at preview scale
  _EditorTool _tool = _EditorTool.draw;
  _TextOverlay? _draggingText;

  static const _colors = [
    Colors.red,
    Colors.white,
    Colors.black,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.orange,
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image = frame.image;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = AppLocale.pick('باز کردن تصویر ممکن نشد', 'Could not open image');
        });
      }
    }
  }

  bool get _isRotatedSideways => _quarterTurns.isOdd;

  /// Dimensions of the selected crop in the rotated image's source pixels.
  Size get _croppedSourceSize {
    final image = _image;
    if (image == null) return Size.zero;
    final rotatedW =
        _isRotatedSideways ? image.height.toDouble() : image.width.toDouble();
    final rotatedH =
        _isRotatedSideways ? image.width.toDouble() : image.height.toDouble();
    return Size(rotatedW * _cropRect.width, rotatedH * _cropRect.height);
  }

  double get _rotatedImageWidth => _isRotatedSideways
      ? _image!.height.toDouble()
      : _image!.width.toDouble();
  double get _rotatedImageHeight => _isRotatedSideways
      ? _image!.width.toDouble()
      : _image!.height.toDouble();

  Rect _aspectCrop(double ratio) {
    final fullW = _rotatedImageWidth;
    final fullH = _rotatedImageHeight;
    final fullRatio = fullW / fullH;
    final cropW = fullRatio > ratio ? ratio / fullRatio : 1.0;
    final cropH = fullRatio > ratio ? 1.0 : fullRatio / ratio;
    return Rect.fromCenter(
      center: const Offset(0.5, 0.5),
      width: cropW,
      height: cropH,
    );
  }

  void _rotate() => setState(() {
        final crop = _cropRect;
        _cropRect = Rect.fromLTRB(
          1 - crop.bottom,
          crop.left,
          1 - crop.top,
          crop.right,
        );
        if (_aspectRatio != null) _aspectRatio = 1 / _aspectRatio!;
        _quarterTurns = (_quarterTurns + 1) % 4;
      });

  void _flip() => setState(() {
        final crop = _cropRect;
        if (_isRotatedSideways) {
          _cropRect = Rect.fromLTRB(
            crop.left,
            1 - crop.bottom,
            crop.right,
            1 - crop.top,
          );
        } else {
          _cropRect = Rect.fromLTRB(
            1 - crop.right,
            crop.top,
            1 - crop.left,
            crop.bottom,
          );
        }
        _flipH = !_flipH;
      });

  void _setAspect(double? ratio) {
    setState(() {
      _aspectRatio = ratio;
      _freeCrop = false;
      _cropRect = ratio == null
          ? const Rect.fromLTRB(0, 0, 1, 1)
          : _aspectCrop(ratio);
      _cropMode = ratio != null;
    });
  }

  void _setFreeCrop() {
    setState(() {
      _aspectRatio = null;
      _freeCrop = true;
      if (_cropRect.width >= 0.999 && _cropRect.height >= 0.999) {
        _cropRect = const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95);
      }
      _cropMode = true;
    });
  }

  void _toggleCropMode() {
    if (_cropMode) {
      setState(() => _cropMode = false);
    } else if (_freeCrop || _aspectRatio != null) {
      setState(() => _cropMode = true);
    } else {
      _setFreeCrop();
    }
  }

  void _undo() {
    setState(() {
      if (_texts.isNotEmpty && _strokes.isEmpty) {
        _texts.removeLast();
      } else if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      }
    });
  }

  void _clearAll() {
    setState(() {
      _strokes.clear();
      _texts.clear();
    });
  }

  /// The rect the picture actually occupies inside the canvas box.
  Rect _imageRect(Size canvas) {
    final source = _croppedSourceSize;
    if (source.isEmpty || canvas.isEmpty) return Rect.zero;
    final scale =
        math.min(canvas.width / source.width, canvas.height / source.height);
    final w = source.width * scale;
    final h = source.height * scale;
    return Rect.fromLTWH(
      (canvas.width - w) / 2,
      (canvas.height - h) / 2,
      w,
      h,
    );
  }

  Rect _fullImageRect(Size canvas) {
    if (_image == null || canvas.isEmpty) return Rect.zero;
    final scale = math.min(
      canvas.width / _rotatedImageWidth,
      canvas.height / _rotatedImageHeight,
    );
    final width = _rotatedImageWidth * scale;
    final height = _rotatedImageHeight * scale;
    return Rect.fromLTWH(
      (canvas.width - width) / 2,
      (canvas.height - height) / 2,
      width,
      height,
    );
  }

  Rect _cropRectOnCanvas(Size canvas) {
    final imageRect = _fullImageRect(canvas);
    if (imageRect.isEmpty) return Rect.zero;
    return Rect.fromLTRB(
      imageRect.left + _cropRect.left * imageRect.width,
      imageRect.top + _cropRect.top * imageRect.height,
      imageRect.left + _cropRect.right * imageRect.width,
      imageRect.top + _cropRect.bottom * imageRect.height,
    );
  }

  void _onCropPanStart(DragStartDetails details) {
    final selection = _cropRectOnCanvas(_canvasSize());
    if (selection.isEmpty || !selection.inflate(36).contains(details.localPosition)) {
      return;
    }

    var edges = 0;
    if (_freeCrop) {
      const handleRadius = 32.0;
      final handles = <(Offset, int)>[
        (selection.topLeft, 1 | 2),
        (selection.topRight, 4 | 2),
        (selection.bottomLeft, 1 | 8),
        (selection.bottomRight, 4 | 8),
      ];
      for (final (point, candidate) in handles) {
        if ((point - details.localPosition).distance <= handleRadius) {
          edges = candidate;
          break;
        }
      }
    }
    _cropDragEdges = edges;
    _cropDragStart = details.localPosition;
    _cropDragStartRect = _cropRect;
  }

  void _onCropPanUpdate(DragUpdateDetails details) {
    final start = _cropDragStart;
    final startRect = _cropDragStartRect;
    final imageRect = _fullImageRect(_canvasSize());
    if (start == null || startRect == null || imageRect.isEmpty) return;
    final delta = details.localPosition - start;
    final dx = delta.dx / imageRect.width;
    final dy = delta.dy / imageRect.height;

    Rect next;
    if (_cropDragEdges == 0) {
      final left =
          (startRect.left + dx).clamp(0.0, 1.0 - startRect.width).toDouble();
      final top =
          (startRect.top + dy).clamp(0.0, 1.0 - startRect.height).toDouble();
      next = Rect.fromLTWH(left, top, startRect.width, startRect.height);
    } else {
      var left = startRect.left;
      var top = startRect.top;
      var right = startRect.right;
      var bottom = startRect.bottom;
      const minimumSide = 0.06;
      if ((_cropDragEdges & 1) != 0) {
        left =
            (startRect.left + dx).clamp(0.0, right - minimumSide).toDouble();
      }
      if ((_cropDragEdges & 2) != 0) {
        top =
            (startRect.top + dy).clamp(0.0, bottom - minimumSide).toDouble();
      }
      if ((_cropDragEdges & 4) != 0) {
        right =
            (startRect.right + dx).clamp(left + minimumSide, 1.0).toDouble();
      }
      if ((_cropDragEdges & 8) != 0) {
        bottom =
            (startRect.bottom + dy).clamp(top + minimumSide, 1.0).toDouble();
      }
      next = Rect.fromLTRB(left, top, right, bottom);
    }
    setState(() => _cropRect = next);
  }

  void _endCropPan() {
    _cropDragStart = null;
    _cropDragStartRect = null;
    _cropDragEdges = 0;
  }

  Offset? _toNormalised(Offset local, Size canvas) {
    final rect = _imageRect(canvas);
    if (rect.isEmpty) return null;
    return Offset(
      ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  Size _canvasSize() {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? Size.zero;
  }

  _TextOverlay? _hitTestText(Offset local, Size canvas) {
    final rect = _imageRect(canvas);
    if (rect.isEmpty) return null;
    for (final t in _texts.reversed) {
      final center = Offset(
        rect.left + t.position.dx * rect.width,
        rect.top + t.position.dy * rect.height,
      );
      final fontSize = t.size * rect.height;
      final painter = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromCenter(
        center: center,
        width: math.max(painter.width, 40) + 24,
        height: math.max(painter.height, 24) + 24,
      );
      if (box.contains(local)) return t;
    }
    return null;
  }

  void _onPanStart(DragStartDetails d) {
    if (_cropMode) {
      _onCropPanStart(d);
      return;
    }
    final canvas = _canvasSize();
    final text = _hitTestText(d.localPosition, canvas);
    if (text != null) {
      _draggingText = text;
      return;
    }
    if (_tool != _EditorTool.draw) return;
    final point = _toNormalised(d.localPosition, canvas);
    if (point == null) return;
    final rect = _imageRect(canvas);
    setState(() {
      _activeStroke = _DrawStroke(
        points: [point],
        color: _penColor,
        // Normalise against the shortest preview side so the exported stroke
        // matches what was drawn.
        width: _penWidth / math.min(rect.width, rect.height),
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_cropMode) {
      _onCropPanUpdate(d);
      return;
    }
    final canvas = _canvasSize();
    final dragging = _draggingText;
    if (dragging != null) {
      final rect = _imageRect(canvas);
      if (rect.isEmpty) return;
      setState(() {
        dragging.position = Offset(
          (dragging.position.dx + d.delta.dx / rect.width).clamp(0.0, 1.0),
          (dragging.position.dy + d.delta.dy / rect.height).clamp(0.0, 1.0),
        );
      });
      return;
    }
    final stroke = _activeStroke;
    if (stroke == null) return;
    final point = _toNormalised(d.localPosition, canvas);
    if (point == null) return;
    setState(() {
      _activeStroke = stroke.copyWith(points: [...stroke.points, point]);
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_cropMode) {
      _endCropPan();
      return;
    }
    if (_draggingText != null) {
      _draggingText = null;
      return;
    }
    final stroke = _activeStroke;
    if (stroke == null) return;
    setState(() {
      _strokes.add(stroke);
      _activeStroke = null;
    });
  }

  Future<void> _addOrEditText([_TextOverlay? existing]) async {
    final ctrl = TextEditingController(text: existing?.text ?? '');
    var color = existing?.color ?? Colors.white;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null
              ? AppLocale.pick('متن روی عکس', 'Text on photo')
              : AppLocale.pick('ویرایش متن', 'Edit text')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(hintText: AppLocale.pick('متن...', 'Enter text...')),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: _colors
                    .map((c) => GestureDetector(
                          onTap: () => setD(() => color = c),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: color == c ? Colors.blue : Colors.grey,
                                width: color == c ? 3 : 1,
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, '__delete__'),
                child: Text(AppLocale.pick('حذف', 'Delete'), style: const TextStyle(color: Colors.red)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(AppLocale.pick('لغو', 'Cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(existing == null
                  ? AppLocale.pick('افزودن', 'Add')
                  : AppLocale.pick('ذخیره', 'Save')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    setState(() {
      if (result == '__delete__') {
        if (existing != null) _texts.remove(existing);
        return;
      }
      if (result.isEmpty) return;
      if (existing != null) {
        existing.text = result;
        existing.color = color;
      } else {
        _texts.add(_TextOverlay(
          text: result,
          position: const Offset(0.5, 0.4),
          color: color,
          size: 0.07,
        ));
      }
    });
  }

  /// Renders the final image at full source resolution — independent of the
  /// preview size, so quality never depends on the phone's screen.
  Future<Uint8List?> _renderResult() async {
    final image = _image;
    if (image == null) return null;
    final target = _croppedSourceSize;
    if (target.isEmpty) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, target.width, target.height));

    canvas.save();
    // Move the selected source area to the center of the output, then apply
    // the same flip/rotation used by the live preview.
    final cropOffset = Offset(
      (_cropRect.center.dx - 0.5) * _rotatedImageWidth,
      (_cropRect.center.dy - 0.5) * _rotatedImageHeight,
    );
    canvas.translate(
      target.width / 2 - cropOffset.dx,
      target.height / 2 - cropOffset.dy,
    );
    if (_flipH) canvas.scale(-1, 1);
    canvas.rotate(_quarterTurns * math.pi / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: image.width.toDouble(),
        height: image.height.toDouble(),
      ),
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();

    _paintOverlays(canvas, target);

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(
      target.width.round(),
      target.height.round(),
    );
    picture.dispose();
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (data == null) return null;

    // Re-encode as JPEG (smaller upload) via the image package.
    final decoded = img.decodePng(data.buffer.asUint8List());
    if (decoded == null) return data.buffer.asUint8List();
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
  }

  void _paintOverlays(Canvas canvas, Size size) {
    for (final stroke in [..._strokes, if (_activeStroke != null) _activeStroke!]) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width * math.min(size.width, size.height)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(stroke.points.first.dx * size.width,
              stroke.points.first.dy * size.height),
          paint.strokeWidth / 2,
          Paint()..color = stroke.color,
        );
        continue;
      }
      final path = Path()
        ..moveTo(stroke.points.first.dx * size.width,
            stroke.points.first.dy * size.height);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(
            stroke.points[i].dx * size.width, stroke.points[i].dy * size.height);
      }
      canvas.drawPath(path, paint);
    }

    for (final t in _texts) {
      final painter = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: t.color,
            fontSize: t.size * size.height,
            fontWeight: FontWeight.w700,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
          ),
        ),
        textDirection: AppLocale.isFa ? TextDirection.rtl : TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: size.width * 0.9);
      painter.paint(
        canvas,
        Offset(
          t.position.dx * size.width - painter.width / 2,
          t.position.dy * size.height - painter.height / 2,
        ),
      );
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _renderResult();
      if (!mounted) return;
      if (bytes == null) {
        Navigator.pop(context, widget.imageFile);
        return;
      }
      final path =
          '${widget.imageFile.parent.path}/edited_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = await File(path).writeAsBytes(bytes);
      if (mounted) Navigator.pop(context, file);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.pick('ذخیره ناموفق: $e', 'Save failed: $e'))));
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (_strokes.isEmpty &&
        _texts.isEmpty &&
        _quarterTurns == 0 &&
        !_flipH &&
        !_freeCrop &&
        _cropRect == const Rect.fromLTRB(0, 0, 1, 1) &&
        _aspectRatio == null) {
      return true;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.pick('لغو ویرایش', 'Discard edits')),
        content: Text(AppLocale.pick('تغییرات ذخیره نشده از بین می‌رود. مطمئن هستید؟', 'Your unsaved changes will be lost. Are you sure?')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.pick('ادامه ویرایش', 'Continue editing'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocale.pick('لغو ویرایش', 'Discard edits')),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(AppLocale.pick('ویرایش عکس', 'Edit photo')),
          actions: [
            IconButton(
              tooltip: _cropMode
                  ? AppLocale.pick('پایان برش', 'Done cropping')
                  : AppLocale.pick('برش آزاد', 'Free crop'),
              icon: Icon(_cropMode ? Icons.crop_rounded : Icons.crop_free_rounded),
              onPressed: image == null ? null : _toggleCropMode,
            ),
            IconButton(
              tooltip: AppLocale.pick('چرخش', 'Rotate'),
              icon: const Icon(Icons.rotate_right),
              onPressed: image == null ? null : _rotate,
            ),
            IconButton(
              tooltip: AppLocale.pick('آینه', 'Flip'),
              icon: const Icon(Icons.flip),
              onPressed: image == null ? null : _flip,
            ),
            IconButton(
              tooltip: AppLocale.pick('متن', 'Text'),
              icon: const Icon(Icons.text_fields),
              onPressed: image == null ? null : () => _addOrEditText(),
            ),
            IconButton(
              tooltip: AppLocale.pick('واگرد', 'Undo'),
              icon: const Icon(Icons.undo),
              onPressed:
                  (_strokes.isEmpty && _texts.isEmpty) ? null : _undo,
            ),
            IconButton(
              tooltip: AppLocale.pick('ارسال', 'Send'),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.green),
                    )
                  : const Icon(Icons.check, color: Colors.green),
              onPressed: (image == null || _saving) ? null : _save,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null || image == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            color: Theme.of(context).colorScheme.onSurfaceVariant, size: 48),
                        const SizedBox(height: 8),
                        Text(_loadError ?? AppLocale.pick('تصویر در دسترس نیست', 'Image unavailable'),
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, widget.imageFile),
                          child: Text(AppLocale.pick('ارسال بدون ویرایش', 'Send original')),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(children: [
                          _cropChip(AppLocale.pick('آزاد', 'Free'), null, free: true),
                          _cropChip(AppLocale.pick('اصلی', 'Original'), null),
                          _cropChip(AppLocale.pick('۱:۱', '1:1'), 1.0),
                          _cropChip(AppLocale.pick('۴:۳', '4:3'), 4 / 3),
                          _cropChip(AppLocale.pick('۳:۴', '3:4'), 3 / 4),
                          _cropChip(AppLocale.pick('۱۶:۹', '16:9'), 16 / 9),
                          _cropChip(AppLocale.pick('۹:۱۶', '9:16'), 9 / 16),
                        ]),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: _onPanStart,
                            onPanUpdate: _onPanUpdate,
                            onPanEnd: _onPanEnd,
                            onTapUp: (d) {
                              if (_cropMode) return;
                              final t =
                                  _hitTestText(d.localPosition, _canvasSize());
                              if (t != null) _addOrEditText(t);
                            },
                            child: CustomPaint(
                              key: _canvasKey,
                              size: Size.infinite,
                              painter: _EditorPainter(
                                image: image,
                                quarterTurns: _quarterTurns,
                                flipH: _flipH,
                                sourceSize: _croppedSourceSize,
                                cropRect: _cropRect,
                                cropMode: _cropMode,
                                freeCrop: _freeCrop,
                                strokes: [
                                  ..._strokes,
                                  if (_activeStroke != null) _activeStroke!
                                ],
                                texts: _texts,
                              ),
                            ),
                          ),
                        ),
                      ),
                      _buildToolbar(),
                    ],
                  ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: _tool == _EditorTool.draw
                    ? AppLocale.pick('حالت جابه‌جایی متن', 'Move text')
                    : AppLocale.pick('حالت نقاشی', 'Draw'),
                icon: Icon(
                  _tool == _EditorTool.draw
                      ? Icons.brush
                      : Icons.pan_tool_outlined,
                  color: _tool == _EditorTool.draw
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface,
                ),
                onPressed: () => setState(() => _tool =
                    _tool == _EditorTool.draw
                        ? _EditorTool.move
                        : _EditorTool.draw),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _colors
                        .map((c) => GestureDetector(
                              onTap: () => setState(() {
                                _penColor = c;
                                _tool = _EditorTool.draw;
                              }),
                              child: Container(
                                width: 28,
                                height: 28,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _penColor == c
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.outline,
                                    width: _penColor == c ? 3 : 1,
                                  ),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ),
              ),
              IconButton(
                tooltip: AppLocale.pick('پاک کردن همه', 'Clear all'),
                icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onSurfaceVariant),
                onPressed:
                    (_strokes.isEmpty && _texts.isEmpty) ? null : _clearAll,
              ),
            ],
          ),
          Row(children: [
            Text(AppLocale.pick('ضخامت', 'Brush size'),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _penWidth,
                min: 2,
                max: 24,
                onChanged: (v) => setState(() => _penWidth = v),
              ),
            ),
            SizedBox(
              width: 26,
              height: 26,
              child: Center(
                child: Container(
                  width: _penWidth,
                  height: _penWidth,
                  decoration:
                      BoxDecoration(color: _penColor, shape: BoxShape.circle),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _cropChip(String label, double? ratio, {bool free = false}) {
    final selected = free
        ? _freeCrop
        : !_freeCrop && _aspectRatio == ratio && (ratio != null || !_cropMode);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label,
            style: TextStyle(color: selected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface)),
        selected: selected,
        selectedColor: Theme.of(context).colorScheme.primary,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        onSelected: (_) => free ? _setFreeCrop() : _setAspect(ratio),
      ),
    );
  }
}

/// Paints the picture plus overlays. Everything is derived from the current
/// state, so a repaint costs no decoding or encoding.
class _EditorPainter extends CustomPainter {
  final ui.Image image;
  final int quarterTurns;
  final bool flipH;
  final Size sourceSize;
  final Rect cropRect;
  final bool cropMode;
  final bool freeCrop;
  final List<_DrawStroke> strokes;
  final List<_TextOverlay> texts;

  _EditorPainter({
    required this.image,
    required this.quarterTurns,
    required this.flipH,
    required this.sourceSize,
    required this.cropRect,
    required this.cropMode,
    required this.freeCrop,
    required this.strokes,
    required this.texts,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (sourceSize.isEmpty || size.isEmpty) return;
    final sideways = quarterTurns.isOdd;
    final fullWidth = sideways ? image.height.toDouble() : image.width.toDouble();
    final fullHeight = sideways ? image.width.toDouble() : image.height.toDouble();

    if (cropMode) {
      _paintCropSelection(canvas, size, fullWidth, fullHeight);
      return;
    }

    final scale = math.min(
        size.width / sourceSize.width, size.height / sourceSize.height);
    final drawn = Size(sourceSize.width * scale, sourceSize.height * scale);
    final origin = Offset(
        (size.width - drawn.width) / 2, (size.height - drawn.height) / 2);
    final cropOffset = Offset(
      (cropRect.center.dx - 0.5) * fullWidth * scale,
      (cropRect.center.dy - 0.5) * fullHeight * scale,
    );

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.clipRect(Rect.fromLTWH(0, 0, drawn.width, drawn.height));
    canvas.save();
    canvas.translate(
      drawn.width / 2 - cropOffset.dx,
      drawn.height / 2 - cropOffset.dy,
    );
    if (flipH) canvas.scale(-1, 1);
    canvas.rotate(quarterTurns * math.pi / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: image.width * scale,
        height: image.height * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    // Overlays in normalised space.
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth =
            stroke.width * math.min(drawn.width, drawn.height)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(stroke.points.first.dx * drawn.width,
              stroke.points.first.dy * drawn.height),
          paint.strokeWidth / 2,
          Paint()..color = stroke.color,
        );
        continue;
      }
      final path = Path()
        ..moveTo(stroke.points.first.dx * drawn.width,
            stroke.points.first.dy * drawn.height);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx * drawn.width,
            stroke.points[i].dy * drawn.height);
      }
      canvas.drawPath(path, paint);
    }

    for (final t in texts) {
      final painter = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: t.color,
            fontSize: t.size * drawn.height,
            fontWeight: FontWeight.w700,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
          ),
        ),
        textDirection: AppLocale.isFa ? TextDirection.rtl : TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: drawn.width * 0.9);
      painter.paint(
        canvas,
        Offset(
          t.position.dx * drawn.width - painter.width / 2,
          t.position.dy * drawn.height - painter.height / 2,
        ),
      );
    }

    canvas.restore();
  }

  void _paintCropSelection(
    Canvas canvas,
    Size size,
    double fullWidth,
    double fullHeight,
  ) {
    final scale = math.min(size.width / fullWidth, size.height / fullHeight);
    final imageWidth = fullWidth * scale;
    final imageHeight = fullHeight * scale;
    final imageRect = Rect.fromLTWH(
      (size.width - imageWidth) / 2,
      (size.height - imageHeight) / 2,
      imageWidth,
      imageHeight,
    );

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    if (flipH) canvas.scale(-1, 1);
    canvas.rotate(quarterTurns * math.pi / 2);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: image.width * scale,
        height: image.height * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    final selection = Rect.fromLTRB(
      imageRect.left + cropRect.left * imageRect.width,
      imageRect.top + cropRect.top * imageRect.height,
      imageRect.left + cropRect.right * imageRect.width,
      imageRect.top + cropRect.bottom * imageRect.height,
    );
    final shade = Paint()..color = const Color(0x99000000);
    canvas
      ..drawRect(Rect.fromLTRB(0, 0, size.width, selection.top), shade)
      ..drawRect(
        Rect.fromLTRB(0, selection.top, selection.left, selection.bottom),
        shade,
      )
      ..drawRect(
        Rect.fromLTRB(selection.right, selection.top, size.width, selection.bottom),
        shade,
      )
      ..drawRect(
        Rect.fromLTRB(0, selection.bottom, size.width, size.height),
        shade,
      );
    canvas.drawRect(
      selection,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    if (freeCrop) {
      final handlePaint = Paint()..color = Colors.white;
      for (final point in <Offset>[
        selection.topLeft,
        selection.topRight,
        selection.bottomLeft,
        selection.bottomRight,
      ]) {
        canvas.drawCircle(point, 7, handlePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) =>
      old.image != image ||
      old.quarterTurns != quarterTurns ||
      old.flipH != flipH ||
      old.sourceSize != sourceSize ||
      old.cropRect != cropRect ||
      old.cropMode != cropMode ||
      old.freeCrop != freeCrop ||
      old.strokes != strokes ||
      old.texts != texts ||
      old.strokes.length != strokes.length ||
      old.texts.length != texts.length;
}
