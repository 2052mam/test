import 'package:flutter/material.dart';
import '../../../core/utils/save_feedback.dart';
import '../../../data/models/message_model.dart';
import '../../../data/services/media_download_service.dart';
import '../media/media_labels.dart';

class FileMessageBubble extends StatefulWidget {
  final MessageModel message;
  final String mediaUrl;
  final String? token;
  final bool isMine;
  final Color foregroundColor;

  const FileMessageBubble({
    super.key,
    required this.message,
    required this.mediaUrl,
    this.token,
    required this.isMine,
    required this.foregroundColor,
  });

  @override
  State<FileMessageBubble> createState() => _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<FileMessageBubble> {
  bool _downloading = false;
  double _progress = 0.0;
  String? _downloadedPath;

  IconData _getFileIcon(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_rounded;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return Icons.folder_zip_rounded;
    if (['doc', 'docx', 'txt'].contains(ext)) return Icons.description_rounded;
    if (['xls', 'xlsx'].contains(ext)) return Icons.table_chart_rounded;
    if (['ppt', 'pptx'].contains(ext)) return Icons.slideshow_rounded;
    if (['apk'].contains(ext)) return Icons.android_rounded;
    if (['mp3', 'wav', 'ogg'].contains(ext)) return Icons.audio_file_rounded;
    if (['mp4', 'avi', 'mkv'].contains(ext)) return Icons.video_file_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Color _getFileColor(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    if (['pdf'].contains(ext)) return const Color(0xFFEF4444);
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return const Color(0xFFF59E0B);
    if (['doc', 'docx', 'txt'].contains(ext)) return const Color(0xFF3B82F6);
    if (['xls', 'xlsx'].contains(ext)) return const Color(0xFF10B981);
    if (['apk'].contains(ext)) return const Color(0xFF84CC16);
    if (['mp3', 'wav', 'ogg'].contains(ext)) return const Color(0xFF06B6D4);
    if (['mp4', 'avi', 'mkv'].contains(ext)) return const Color(0xFF8B5CF6);
    return const Color(0xFF64748B);
  }

  Future<void> _startDownload() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0.0;
    });

    final fileName = widget.message.originalName ??
        widget.message.content ??
        'file_${widget.message.id}';

    try {
      final path = await MediaDownloadService.downloadMedia(
        mediaUrl: widget.mediaUrl,
        fileName: fileName,
        token: widget.token,
        mediaId: widget.message.mediaId,
        chatId: widget.message.chatId,
        messageId: widget.message.id,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadedPath = path;
      });
      SaveFeedback.success(context, fileName: fileName);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      SaveFeedback.failure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = MediaLabels.of(context);
    final fileName = widget.message.originalName ??
        widget.message.content ??
        (labels.isFa ? 'فایل پیوست' : 'Attached file');
    final fg = widget.foregroundColor;
    final fileColor = _getFileColor(fileName);

    if (widget.message.mediaExpired) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fg.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: fg.withValues(alpha: 0.75)),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(labels.mediaExpired, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
                  Text(labels.mediaExpiredNotice, style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: _startDownload,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: widget.isMine
                    ? Colors.white.withValues(alpha: 0.2)
                    : fileColor.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_downloading)
                    CircularProgressIndicator(
                      value: _progress > 0 ? _progress : null,
                      strokeWidth: 2.5,
                      color: widget.isMine ? Colors.white : fileColor,
                    ),
                  Icon(
                    _downloadedPath != null
                        ? Icons.check_circle_rounded
                        : _getFileIcon(fileName),
                    color: widget.isMine ? Colors.white : fileColor,
                    size: 24,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _downloading
                        ? (labels.isFa
                            ? 'در حال دانلود… ${(_progress * 100).toInt()}%'
                            : 'Downloading… ${(_progress * 100).toInt()}%')
                        : _downloadedPath != null
                            ? (labels.isFa ? 'ذخیره شد در حافظه' : 'Saved to device')
                            : (labels.isFa ? 'برای دانلود ضربه بزنید' : 'Tap to download'),
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.72),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
