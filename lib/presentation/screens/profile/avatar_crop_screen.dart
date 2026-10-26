import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../../widgets/chat/chat_labels.dart';

/// Point 2: Telegram-style circular cropper for profile pictures.
///
/// Before this screen existed the picked image was uploaded as-is, so a
/// landscape photo turned into an arbitrarily centre-cropped avatar. Now the
/// user drags and pinches to choose exactly what lands inside the circle.
///
/// Returns the cropped [File] via `Navigator.pop`, or null when cancelled.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({
    super.key,
    required this.imageFile,
    this.title,
    this.outputSize = 720,
  });

  final File imageFile;
  final String? title;

  /// Edge length of the square JPEG that gets written out.
  final int outputSize;

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  ui.Image? _image;
  String? _error;
  bool _saving = false;

  /// View transform, in *viewport* space. [_offset] is the translation of the
  /// image centre away from the viewport centre; [_scale] is relative to the
  /// "cover the circle exactly" baseline, so 1.0 is always a valid crop.
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  double _gestureStartScale = 1.0;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocal = Offset.zero;

  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final bytes = await widget.imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) {
        setState(() => _error = ChatLabels.of(context).imageUnreadable);
      }
    }
  }

  /// The scale at which the image exactly covers a circle of [circle] pixels.
  double _baseScale(ui.Image image, double circle) =>
      circle / math.min(image.width.toDouble(), image.height.toDouble());

  /// Keeps the circle fully covered by the image at all times, which is what
  /// stops the user from cropping in empty space.
  Offset _clampOffset(Offset offset, ui.Image image, double circle) {
    final drawn = _baseScale(image, circle) * _scale;
    final halfWidth = image.width * drawn / 2;
    final halfHeight = image.height * drawn / 2;
    final maxX = math.max(0.0, halfWidth - circle / 2);
    final maxY = math.max(0.0, halfHeight - circle / 2);
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartOffset = _offset;
    _gestureStartFocal = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double circle) {
    final image = _image;
    if (image == null) return;
    final nextScale =
        (_gestureStartScale * details.scale).clamp(_minScale, _maxScale);
    final pan = details.focalPoint - _gestureStartFocal;
    // Scaling around the viewport centre keeps the maths (and the clamping)
    // simple and matches how the circle stays fixed on screen.
    final scaled = _gestureStartOffset * (nextScale / _gestureStartScale);
    setState(() {
      _scale = nextScale;
      _offset = _clampOffset(scaled + pan, image, circle);
    });
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null || _saving) return;
    setState(() => _saving = true);
    try {
      final file = await _renderCrop(image);
      if (!mounted) return;
      Navigator.of(context).pop(file);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = ChatLabels.of(context).cropSaveFailed;
        });
      }
    }
  }

  /// Maps the on-screen circle back to source pixels and encodes a square JPEG.
  Future<File> _renderCrop(ui.Image image) async {
    // Work in a normalised viewport: the circle is 1.0 wide.
    const circle = 1.0;
    final drawn = _baseScale(image, circle) * _scale;
    final normalisedOffset = _offset / _circleDiameter;

    // Top-left of the circle, expressed in source pixel coordinates.
    final visibleSource = circle / drawn;
    final centreX = image.width / 2 - normalisedOffset.dx / drawn;
    final centreY = image.height / 2 - normalisedOffset.dy / drawn;
    var left = (centreX - visibleSource / 2).round();
    var top = (centreY - visibleSource / 2).round();
    var side = visibleSource.round();

    // Guard against rounding pushing the window past the edges.
    side = side.clamp(1, math.min(image.width, image.height));
    left = left.clamp(0, image.width - side);
    top = top.clamp(0, image.height - side);

    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) throw StateError('decode failed');
    final source = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: byteData.buffer,
      numChannels: 4,
    );
    final cropped =
        img.copyCrop(source, x: left, y: top, width: side, height: side);
    final resized = side == widget.outputSize
        ? cropped
        : img.copyResize(
            cropped,
            width: widget.outputSize,
            height: widget.outputSize,
            interpolation: img.Interpolation.cubic,
          );
    final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 90));

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    return File(path).writeAsBytes(jpeg, flush: true);
  }

  /// Diameter of the crop circle in logical pixels, set during build.
  double _circleDiameter = 1;

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final labels = ChatLabels.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? labels.cropProfilePhoto),
        actions: [
          if (image != null)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(labels.confirm,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: image == null
                  ? Center(
                      child: _error != null
                          ? Text(_error!,
                              style: const TextStyle(color: Colors.redAccent))
                          : const CircularProgressIndicator(),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final circle = math.min(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            ) *
                            0.82;
                        _circleDiameter = circle;
                        return GestureDetector(
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: (details) =>
                              _onScaleUpdate(details, circle),
                          child: Container(
                            color: Colors.black,
                            alignment: Alignment.center,
                            child: SizedBox(
                              width: circle,
                              height: circle,
                              child: ClipOval(
                                child: CustomPaint(
                                  painter: _CropPainter(
                                    image: image,
                                    scale: _baseScale(image, circle) * _scale,
                                    offset: _offset,
                                  ),
                                  size: Size(circle, circle),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (image != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    const Icon(Icons.zoom_out, color: Colors.white54, size: 20),
                    Expanded(
                      child: Slider(
                        value: _scale,
                        min: _minScale,
                        max: _maxScale,
                        onChanged: (value) => setState(() {
                          _scale = value;
                          _offset =
                              _clampOffset(_offset, image, _circleDiameter);
                        }),
                      ),
                    ),
                    const Icon(Icons.zoom_in, color: Colors.white54, size: 20),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 18),
                child: Text(
                  'برای جابه‌جایی بکشید و برای بزرگ‌نمایی دو انگشتی حرکت دهید.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.scale,
    required this.offset,
  });

  final ui.Image image;
  final double scale;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    final width = image.width * scale;
    final height = image.height * scale;
    final left = size.width / 2 - width / 2 + offset.dx;
    final top = size.height / 2 - height / 2 + offset.dy;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(left, top, width, height),
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.scale != scale || old.offset != offset;
}
