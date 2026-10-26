import 'package:flutter/material.dart';

import '../../../data/models/user_model.dart';
import 'chat_avatar.dart';
import 'chat_labels.dart';

class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.title,
    required this.chatType,
    this.otherUser,
    this.avatarUrl,
    this.membersCount,
    this.onlineCount,
    this.token,
    this.onTap,
  });

  final String title;
  final String chatType;
  final UserModel? otherUser;
  final String? avatarUrl;
  final int? membersCount;
  final int? onlineCount;
  final String? token;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final labels = ChatLabels.of(context);
    final peer = otherUser;
    final isPrivate = chatType == 'private' || chatType == 'support';
    final name = isPrivate ? peer?.displayName ?? title : title;
    final photo = isPrivate && peer != null
        ? (peer.showProfilePhoto ? peer.avatarUrl : null)
        : avatarUrl;
    final online =
        isPrivate && peer?.isOnline == true && peer?.showLastSeen == true;

    final String subtitle;
    if (isPrivate && peer != null) {
      subtitle = online
          ? labels.online
          : !peer.showLastSeen || peer.lastSeen == null
          ? labels.lastSeenHidden
          : labels.lastSeen(peer.lastSeen!);
    } else if (chatType == 'group' || chatType == 'channel') {
      if (membersCount == null) {
        subtitle = (chatType == 'channel' ? labels.channel : labels.group);
      } else {
        final base = labels.members(membersCount!, subscribers: chatType == 'channel');
        if (onlineCount != null && onlineCount! > 0 && chatType == 'group') {
          subtitle = '$base • $onlineCount ${labels.online}';
        } else if (onlineCount != null && onlineCount! > 0 && chatType == 'channel') {
          subtitle = base;
        } else {
          subtitle = base;
        }
      }
    } else if (chatType == 'saved') {
      subtitle = labels.saved;
    } else {
      subtitle = labels.profile;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = online
        ? (isDark ? const Color(0xFF69F0AE) : const Color(0xFF059669))
        : (isDark ? Colors.white70 : const Color(0xFF64748B));

    return Semantics(
      button: onTap != null,
      child: InkWell(
        key: const ValueKey('chat-header'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Stack(
                children: [
                  ChatAvatar(
                    title: name,
                    url: photo,
                    token: token,
                    foreground: titleColor,
                    radius: 20,
                    fallbackIcon: chatType == 'saved' ? Icons.bookmark_rounded : null,
                  ),
                  if (online)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).appBarTheme.backgroundColor ??
                                Theme.of(context).scaffoldBackgroundColor,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: titleColor,
                            ),
                          ),
                        ),
                        if (chatType == 'saved')
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.bookmark_rounded,
                              size: 14,
                              color: isDark ? Colors.white70 : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: online ? FontWeight.w600 : FontWeight.w400,
                        color: subtitleColor,
                      ),
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
