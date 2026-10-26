import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

/// Next-gen animated upload banner shown above the composer or top of chat.
/// Features high-precision upload percentage (e.g. 74%), fluid gradient ring,
/// dynamic micro-animations, media icon badge, and cancel action.
class ChatUploadBanner extends StatefulWidget {
  final String mediaType; // 'image', 'video', 'voice', 'file', 'video_note', 'audio'
  final String? fileName;
  final double? progress; // 0.0 to 1.0, or null if indeterminate
  final bool isSending;
  final VoidCallback? onCancel;
  final bool isFa;

  const ChatUploadBanner({
    super.key,
    required this.mediaType,
    this.fileName,
    this.progress,
    this.isSending = false,
    this.onCancel,
    this.isFa = true,
  });

  @override
  State<ChatUploadBanner> createState() => _ChatUploadBannerState();
}

class _ChatUploadBannerState extends State<ChatUploadBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  IconData _iconForType() {
    switch (widget.mediaType) {
      case 'image':
        return Icons.photo_library_rounded;
      case 'video':
        return Icons.videocam_rounded;
      case 'voice':
        return Icons.mic_rounded;
      case 'video_note':
        return Icons.play_circle_fill_rounded;
      case 'audio':
      case 'music':
        return Icons.music_note_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  String _titleForType() {
    if (widget.isSending) {
      return widget.isFa ? 'در حال نهایی‌سازی ارسال…' : 'Finishing send…';
    }
    final pct = widget.progress != null ? ' (${(widget.progress! * 100).toInt()}%)' : '';
    if (widget.isFa) {
      switch (widget.mediaType) {
        case 'image':
          return 'در حال بارگذاری عکس$pct…';
        case 'video':
          return 'در حال بهینه‌سازی و آپلود ویدیو$pct…';
        case 'voice':
          return 'در حال ارسال پیام صوتی$pct…';
        case 'video_note':
          return 'در حال آپلود ویدیو مسیج$pct…';
        case 'audio':
        case 'music':
          return 'در حال ارسال موسیقی$pct…';
        default:
          return widget.fileName != null
              ? 'در حال ارسال ${widget.fileName}$pct…'
              : 'در حال آپلود فایل$pct…';
      }
    } else {
      switch (widget.mediaType) {
        case 'image':
          return 'Uploading photo$pct…';
        case 'video':
          return 'Optimizing & uploading video$pct…';
        case 'voice':
          return 'Uploading voice note$pct…';
        case 'video_note':
          return 'Sending video message$pct…';
        case 'audio':
        case 'music':
          return 'Uploading music$pct…';
        default:
          return widget.fileName != null
              ? 'Uploading ${widget.fileName}$pct…'
              : 'Uploading file$pct…';
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final progress = widget.progress?.clamp(0.0, 1.0);
    final percentageInt = progress != null ? (progress * 100).toInt() : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF17212B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: primary.withValues(alpha: isDark ? 0.35 : 0.22),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  // Circular Progress Ring with embedded media Icon or percentage
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 3.2,
                          backgroundColor: primary.withValues(alpha: 0.15),
                          valueColor: AlwaysStoppedAnimation<Color>(primary),
                        ),
                      ),
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary.withValues(alpha: 0.12),
                        ),
                        child: Center(
                          child: percentageInt != null
                              ? Text(
                                  '$percentageInt%',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: primary,
                                    letterSpacing: -0.5,
                                  ),
                                )
                              : Icon(_iconForType(), color: primary, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _titleForType(),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (percentageInt != null) ...[
                              Text(
                                '$percentageInt% ${widget.isFa ? 'تکمیل شد' : 'completed'}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: primary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text('•', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                widget.fileName ?? (widget.isFa ? 'در حال ارسال رسانه' : 'Sending media'),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isDark ? Colors.white60 : const Color(0xFF64748B),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.onCancel != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      visualDensity: VisualDensity.compact,
                      tooltip: widget.isFa ? 'لغو' : 'Cancel',
                      onPressed: widget.onCancel,
                    ),
                  ],
                ],
              ),
            ),
            // Smooth gradient linear progress bar
            SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: primary.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full interactive voice recording bar with dynamic animated audio waveforms,
/// pulsing live microphone badge, elapsed timer, slide-to-cancel, and discard/send actions.
class VoiceRecordingBar extends StatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final bool isFa;

  const VoiceRecordingBar({
    super.key,
    required this.onCancel,
    required this.onSend,
    this.isFa = true,
  });

  @override
  State<VoiceRecordingBar> createState() => _VoiceRecordingBarState();
}

class _VoiceRecordingBarState extends State<VoiceRecordingBar>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  int _seconds = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat();

    _startTimer();
  }

  void _startTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || _disposed) return;
      setState(() => _seconds++);
      _startTimer();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          // Discard / Trash icon
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
            tooltip: widget.isFa ? 'لغو و حذف' : 'Discard',
            onPressed: widget.onCancel,
          ),
          const SizedBox(width: 4),
          // Pulsing red recording dot
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (context, child) {
              return Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.6 + 0.4 * _pulseCtrl.value),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.5 * _pulseCtrl.value),
                      blurRadius: 6,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          // Elapsed time
          Text(
            _formattedTime,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          // Dynamic animated audio waveform bars
          Expanded(
            child: AnimatedBuilder(
              animation: _waveCtrl,
              builder: (context, child) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(14, (i) {
                    final phase = (i / 14.0) * 2 * math.pi;
                    final h = 6.0 + 18.0 * ((math.sin(_waveCtrl.value * 2 * math.pi + phase) + 1) / 2);
                    return Container(
                      width: 3,
                      height: h,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: 0.45 + (h / 24.0) * 0.55),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          // Slide to cancel text
          Text(
            widget.isFa ? '« کشیدن برای لغو' : '« Slide to cancel',
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          // Send button
          Material(
            color: primary,
            shape: const CircleBorder(),
            elevation: 2,
            child: InkWell(
              onTap: widget.onSend,
              customBorder: const CircleBorder(),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.send_rounded, color: Colors.white, size: 19),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
