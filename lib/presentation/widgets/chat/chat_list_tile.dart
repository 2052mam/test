import 'package:flutter/material.dart';

import '../../../core/utils/chat_list_time.dart';
import '../../../core/theme/chat_design.dart';
import '../../../core/utils/security_message_localizer.dart';
import '../../../data/models/chat_model.dart';
import '../../../data/services/storage_service.dart';
import 'chat_avatar.dart';

/// One row of the chat list (also used by the archive screen).
/// Redesigned with modern Telegram styling: squircle avatar with online badge,
/// subtle gradients on unread pills, crisp typography, and verified shields.
class ChatListTile extends StatelessWidget {
  const ChatListTile({
    super.key,
    required this.chat,
    required this.isFa,
    required this.onTap,
    this.onLongPress,
  });

  final ChatModel chat;
  final bool isFa;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final last = chat.lastMessage;
    String subtitle = '';
    IconData? subtitleIcon;

    if (last != null) {
      if (last.messageType == 'image') {
        subtitle = isFa ? 'عکس' : 'Photo';
        subtitleIcon = Icons.photo_camera_rounded;
      } else if (last.messageType == 'video') {
        subtitle = isFa ? 'ویدیو' : 'Video';
        subtitleIcon = Icons.videocam_rounded;
      } else if (last.messageType == 'poll') {
        final question = last.content?.trim() ?? '';
        subtitle = question.isEmpty
            ? (isFa ? 'نظرسنجی' : 'Poll')
            : question;
        subtitleIcon = Icons.poll_rounded;
      } else if (last.messageType == 'voice') {
        subtitle = isFa ? 'پیام صوتی' : 'Voice message';
        subtitleIcon = Icons.mic_rounded;
      } else if (last.messageType == 'file') {
        subtitle = (last.content?.isNotEmpty == true ? last.content! : (isFa ? 'فایل' : 'File'));
        subtitleIcon = Icons.attach_file_rounded;
      } else {
        final content = last.content ?? '';
        subtitle = chat.isSecurityChat
            ? SecurityMessageLocalizer.localize(content, isFa: isFa)
            : content;
      }
    }

    final timeStr = last?.createdAt == null
        ? ''
        : formatChatListTime(last!.createdAt!, locale: isFa ? 'fa' : 'en');

    final isOnline =
        chat.otherUser?.isOnline == true &&
        (chat.otherUser?.showLastSeen ?? true);

    final avatarUrl = chat.chatType == 'private'
        ? (chat.otherUser?.showProfilePhoto == true
              ? chat.otherUser?.avatarUrl
              : null)
        : chat.avatarUrl;

    final unread = chat.unreadCount;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ChatDesign.space13,
            vertical: ChatDesign.space8,
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ChatAvatar(
                    title: chat.displayTitle,
                    url: avatarUrl,
                    token: StorageService.getToken(),
                    radius: 27,
                    fallbackIcon: chat.isSecurityChat
                        ? Icons.verified_user_rounded
                        : (chat.chatType == 'saved'
                            ? Icons.bookmark_rounded
                            : null),
                    foreground: chat.isSecurityChat
                        ? const Color(0xFF2E7D32)
                        : null,
                  ),
                  if (chat.chatType == 'private' && isOnline)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.scaffoldBackgroundColor,
                            width: 2.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981).withValues(alpha: 0.4),
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (chat.chatType == 'channel')
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 5),
                            child: Icon(
                              Icons.campaign_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                          )
                        else if (chat.chatType == 'group')
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 5),
                            child: Icon(
                              Icons.groups_rounded,
                              size: 16,
                              color: Colors.blueGrey.shade400,
                            ),
                          ),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  chat.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: unread > 0
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    fontSize: 16,
                                    letterSpacing: -0.2,
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              if (chat.isSecurityChat) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.verified_rounded,
                                  size: 16,
                                  color: Color(0xFF2E7D32),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (chat.isMuted)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 6),
                            child: Icon(
                              Icons.volume_off_rounded,
                              size: 15,
                              color: isDark ? Colors.white38 : const Color(0xFF94A3B8),
                            ),
                          ),
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
                            color: unread > 0
                                ? (isDark ? const Color(0xFF64B5F6) : theme.colorScheme.primary)
                                : (isDark ? Colors.white54 : const Color(0xFF64748B)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (subtitleIcon != null) ...[
                          Icon(
                            subtitleIcon,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: unread > 0
                                  ? (isDark ? const Color(0xFF64B5F6) : theme.colorScheme.primary)
                                  : (isDark ? Colors.white60 : const Color(0xFF334155)),
                              fontSize: 13.5,
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (chat.isPinned && unread == 0)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(start: 6),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 15,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        if (unread > 0)
                          Container(
                            margin: const EdgeInsetsDirectional.only(start: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              gradient: chat.isMuted
                                  ? null
                                  : LinearGradient(
                                      colors: [
                                        theme.colorScheme.primary,
                                        theme.colorScheme.primary.withValues(alpha: 0.85),
                                      ],
                                    ),
                              color: chat.isMuted ? Colors.grey.shade400 : null,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: chat.isMuted
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                                        blurRadius: 4,
                                        offset: const Offset(0, 1.5),
                                      ),
                                    ],
                            ),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
