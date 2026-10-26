import 'package:flutter/material.dart';
import '../../../core/utils/save_feedback.dart';
import 'package:flutter/services.dart';

import '../../../data/models/message_model.dart';
import '../../../data/services/media_download_service.dart';
import 'chat_labels.dart';

class MessageActionsSheet extends StatelessWidget {
  const MessageActionsSheet({
    super.key,
    required this.message,
    required this.canDeleteForAll,
    this.canReply = true,
    this.canPin = false,
    this.canForward = true,
    this.canEdit = false,
    required this.onReply,
    required this.onForward,
    required this.onDelete,
    this.onTogglePin,
    this.onEdit,
  });

  final MessageModel message;
  final bool canDeleteForAll;
  final bool canReply;

  /// Pinning is allowed for private chats and for group/channel members with
  /// the pin right. Several messages can stay pinned at the same time.
  final bool canPin;

  /// False when forwarding is blocked (chat-level or user-level privacy).
  final bool canForward;

  /// True when the current user may edit this message (own text/caption).
  final bool canEdit;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final ValueChanged<bool> onDelete;
  final ValueChanged<bool>? onTogglePin;
  final VoidCallback? onEdit;

  Future<void> _copy(BuildContext context) async {
    final text = message.copyableText;
    if (text == null) return;
    final labels = ChatLabels.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(labels.copied)));
    } catch (_) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(labels.copyFailed)));
      }
    }
  }

  Future<void> _download(BuildContext context) async {
    final mediaId = message.mediaId;
    if (mediaId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();

    final ext = message.messageType == 'image' ? 'jpg' :
                message.messageType == 'video' ? 'mp4' :
                message.messageType == 'voice' ? 'm4a' : 'file';
    final fileName = message.originalName ??
        (message.content?.isNotEmpty == true ? message.content! : '${message.messageType}_${message.id}.$ext');
    final mediaUrl = message.mediaUrl ?? '/api/v1/media/$mediaId';

    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    try {
      messenger.showSnackBar(SnackBar(
        content: Text(isFa ? 'در حال دانلود…' : 'Downloading…'),
      ));
      await MediaDownloadService.downloadMedia(
        mediaUrl: mediaUrl,
        fileName: fileName,
        messageType: message.messageType,
        mediaId: mediaId,
        chatId: message.chatId,
        messageId: message.id,
      );
      if (context.mounted) SaveFeedback.success(context, fileName: fileName);
    } catch (e) {
      if (context.mounted) SaveFeedback.failure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    void closeAndRun(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    Widget actionTile({
      Key? key,
      required IconData icon,
      required String title,
      required VoidCallback onTap,
      Color? iconColor,
      Color? textColor,
    }) {
      final color = iconColor ?? (isDark ? const Color(0xFF64B5F6) : theme.colorScheme.primary);
      return ListTile(
        key: key,
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: textColor ?? theme.textTheme.bodyLarge?.color,
          ),
        ),
        onTap: () => closeAndRun(onTap),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canReply)
                actionTile(
                  icon: Icons.reply_rounded,
                  title: labels.reply,
                  onTap: onReply,
                ),
              if (message.copyableText != null)
                actionTile(
                  key: const ValueKey('copy-message'),
                  icon: Icons.copy_rounded,
                  title: labels.copy,
                  onTap: () => _copy(context),
                ),
              if (message.mediaId != null && !message.isViewOnce && !message.mediaExpired)
                actionTile(
                  key: const ValueKey('download-media'),
                  icon: Icons.download_rounded,
                  title: labels.downloadSaveToDevice,
                  onTap: () => _download(context),
                ),
              if (canPin && onTogglePin != null)
                actionTile(
                  key: const ValueKey('pin-message'),
                  icon: message.isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  title: message.isPinned ? labels.unpinMessage : labels.pinMessage,
                  onTap: () => onTogglePin!(!message.isPinned),
                ),
              if (canEdit && onEdit != null)
                actionTile(
                  key: const ValueKey('edit-message'),
                  icon: Icons.edit_rounded,
                  title: labels.edit,
                  onTap: onEdit!,
                ),
              if (!message.isViewOnce)
                if (canForward)
                  actionTile(
                    icon: Icons.forward_rounded,
                    title: labels.forward,
                    onTap: onForward,
                  )
                else
                  ListTile(
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.block_rounded, color: Colors.grey, size: 20),
                    ),
                    title: Text(
                      labels.forwardingDisabled,
                      style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      labels.forwardingDisabledByAdmin,
                      style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                    enabled: false,
                  ),
              Divider(color: theme.dividerColor.withValues(alpha: 0.4), height: 16),
              actionTile(
                icon: Icons.delete_outline_rounded,
                title: labels.deleteForMe,
                textColor: Colors.redAccent.shade200,
                iconColor: Colors.redAccent,
                onTap: () => onDelete(false),
              ),
              if (canDeleteForAll)
                actionTile(
                  icon: Icons.delete_forever_rounded,
                  title: labels.deleteForAll,
                  textColor: Colors.red,
                  iconColor: Colors.red,
                  onTap: () => onDelete(true),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
