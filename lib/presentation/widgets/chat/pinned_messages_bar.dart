import 'package:flutter/material.dart';

import '../../../data/models/message_model.dart';
import 'chat_labels.dart';

String messagePreviewText(BuildContext context, MessageModel message) {
  final labels = ChatLabels.of(context);
  final text = message.content?.trim();
  if (text != null && text.isNotEmpty) return text;
  switch (message.messageType) {
    case 'image':
      return labels.isFa ? '📷 عکس' : '📷 Photo';
    case 'video':
      return labels.isFa ? '🎥 ویدیو' : '🎥 Video';
    case 'voice':
      return labels.isFa ? '🎤 پیام صوتی' : '🎤 Voice message';
    case 'file':
      return labels.isFa ? '📎 فایل' : '📎 File';
  }
  return '';
}

/// Telegram style strip under the app bar. Tapping it jumps to the pinned
/// message; with several pins each tap moves to the next one.
class PinnedMessagesBar extends StatelessWidget {
  const PinnedMessagesBar({
    super.key,
    required this.pinned,
    required this.index,
    required this.onTap,
    required this.onShowAll,
    this.onUnpin,
  });

  final List<MessageModel> pinned;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onShowAll;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    if (pinned.isEmpty) return const SizedBox.shrink();
    final labels = ChatLabels.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final safeIndex = index < 0 || index >= pinned.length ? 0 : index;
    final message = pinned[safeIndex];

    return Material(
      color: isDark ? const Color(0xFF17212B) : const Color(0xFFF8FAFC),
      child: InkWell(
        key: const ValueKey('pinned-bar'),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.35),
                width: 0.8,
              ),
            ),
          ),
          padding: const EdgeInsetsDirectional.only(
            start: 12,
            end: 6,
            top: 7,
            bottom: 7,
          ),
          child: Row(
            children: [
              // Vertical colored accent bar
              Container(
                width: 3.5,
                height: 36,
                decoration: BoxDecoration(
                  color: primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.push_pin_rounded,
                size: 18,
                color: primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          pinned.length > 1
                              ? '${labels.pinnedMessage} (${safeIndex + 1}/${pinned.length})'
                              : labels.pinnedMessage,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      messagePreviewText(context, message),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              if (pinned.length > 1)
                IconButton(
                  tooltip: labels.pinnedMessages,
                  icon: const Icon(Icons.format_list_bulleted_rounded, size: 20),
                  onPressed: onShowAll,
                ),
              if (onUnpin != null)
                IconButton(
                  tooltip: labels.unpinMessage,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: onUnpin,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
