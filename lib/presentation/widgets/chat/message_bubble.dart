import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/chat_design.dart';
import '../../../core/utils/chat_invite_link.dart';
import '../../../core/utils/security_message_localizer.dart';
import '../../../data/models/message_model.dart';
import '../../../data/models/reply_preview_model.dart';
import '../../../data/services/media_cache_service.dart';
import '../../../data/services/media_playback_coordinator.dart';
import '../media/media_labels.dart';
import '../media/video_message_player.dart';
import '../media/video_note_player.dart';
import '../media/voice_message_player.dart';
import '../music/music_message_bubble.dart';
import 'encrypted_bubble.dart';
import 'location_bubble.dart';
import 'reaction_bar.dart';
import 'reply_preview.dart';
import 'message_text.dart';
import 'spoiler_widget.dart';
import 'file_message_bubble.dart';
import 'poll_bubble.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final String mediaUrl;
  final String? token;
  final String? currentUserId;
  final ReplyPreviewModel? reply;
  final VoidCallback? onReplyTap;
  final VoidCallback? onOpenPhoto;
  final VoidCallback? onOpenViewOnce;
  final ValueChanged<ChatInviteLink>? onInviteTap;
  final MediaPlaybackCoordinator? coordinator;
  final bool highlighted;
  final bool showSender;
  final ValueChanged<String>? onReactionTap;
  final VoidCallback? onAddReaction;
  final ValueChanged<String>? onMentionTap;
  final List<MessageModel> musicQueue;
  final String chatTitle;
  // Polls & quizzes (Telegram parity).
  final ValueChanged<String>? onPollVote;
  final VoidCallback? onPollRetract;
  final VoidCallback? onPollClose;
  final VoidCallback? onPollShowVoters;
  final bool pollBusy;
  final bool isSecurityChat;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.mediaUrl,
    this.token,
    this.currentUserId,
    this.reply,
    this.onReplyTap,
    this.onOpenPhoto,
    this.onOpenViewOnce,
    this.onInviteTap,
    this.coordinator,
    this.highlighted = false,
    this.showSender = false,
    this.onReactionTap,
    this.onAddReaction,
    this.onMentionTap,
    this.musicQueue = const [],
    this.chatTitle = '',
    this.onPollVote,
    this.onPollRetract,
    this.onPollClose,
    this.onPollShowVoters,
    this.pollBusy = false,
    this.isSecurityChat = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final labels = MediaLabels.of(context);
    final displayContent = isSecurityChat && message.content != null
        ? SecurityMessageLocalizer.localize(message.content!, isFa: labels.isFa)
        : message.content;

    // Color psychology: Outgoing gets confident sapphire gradient; incoming gets crisp resting neutral
    final bg = isMine
        ? (isDark ? const Color(0xFF2B5278) : const Color(0xFF2481CC))
        : (isDark ? const Color(0xFF1E2C3A) : Colors.white);
    final fg = isMine ? Colors.white : (isDark ? Colors.white : const Color(0xFF0F172A));
    final quote = reply ?? message.replyTo;
    final rendersMedia =
        ((message.messageType == 'image' || message.messageType == 'video') &&
            mediaUrl.isNotEmpty) ||
        message.messageType == 'voice' ||
        message.messageType == 'audio' ||
        message.mediaExpired;
    final hasCaption =
        !message.isViewOnce &&
        rendersMedia &&
        message.content?.trim().isNotEmpty == true;

    // Fibonacci-scale rounding with a compact tail corner.
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(ChatDesign.space21),
      topRight: const Radius.circular(ChatDesign.space21),
      bottomLeft: Radius.circular(isMine ? ChatDesign.space21 : ChatDesign.space3),
      bottomRight: Radius.circular(isMine ? ChatDesign.space3 : ChatDesign.space21),
    );

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(
          vertical: ChatDesign.space3,
          horizontal: ChatDesign.space8,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ChatDesign.space13,
          vertical: ChatDesign.space8,
        ),
        constraints: BoxConstraints(
          maxWidth: ChatDesign.messageMaxWidth(
            MediaQuery.sizeOf(context).width,
          ),
        ),
        decoration: BoxDecoration(
          color: bg,
          gradient: isMine
              ? LinearGradient(
                  colors: isDark
                      ? const [Color(0xFF2E5B88), Color(0xFF264C72)]
                      : const [Color(0xFF2AABEE), Color(0xFF229ED9), Color(0xFF2481CC)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          border: Border.all(
            color: highlighted
                ? Colors.amber.shade400
                : (isMine
                    ? Colors.transparent
                    : (isDark
                        ? const Color(0xFF27384A)
                        : const Color(0xFFE2E8F0))),
            width: highlighted ? 2 : 0.8,
          ),
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1.5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showSender && !isMine && (message.author != null || message.sender != null))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        message.author?.displayName ?? message.sender!.displayName,
                        style: TextStyle(
                          color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (message.author?.username?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '@${message.author!.username}',
                          style: TextStyle(
                            color: (isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7))
                                .withValues(alpha: 0.75),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (message.author != null)
                      Container(
                        margin: const EdgeInsets.only(right: 5),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: (isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7))
                              .withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          labels.isFa ? 'مدیر' : 'Admin',
                          style: TextStyle(
                            color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF0284C7),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (message.replyToId != null || quote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: ReplyPreview(
                  reply:
                      quote ??
                      ReplyPreviewModel.unavailable(message.replyToId!),
                  currentUserId: currentUserId,
                  token: token,
                  foreground: isMine ? Colors.white : theme.colorScheme.primary,
                  onTap: onReplyTap,
                ),
              ),
            if (message.isEncrypted)
              EncryptedBubble(
                message: message,
                isMine: isMine,
                foreground: fg,
                onInviteTap: onInviteTap,
                onMentionTap: onMentionTap,
                onOpenPhoto: onOpenPhoto,
              )
            else if (message.isPoll)
              PollBubble(
                poll: message.poll!,
                isMine: isMine,
                foreground: fg,
                busy: pollBusy,
                onVote: onPollVote,
                onRetract: onPollRetract,
                onClose: onPollClose,
                onShowVoters: onPollShowVoters,
              )
            else if (message.isLocation)
              LocationBubble(message: message, isMine: isMine)
            else if (message.mediaExpired)
              _ExpiredMediaTile(
                messageType: message.messageType,
                foreground: fg,
              )
            else if (message.isViewOnce)
              _ViewOnceTile(
                viewed: message.viewedAt != null,
                expired: message.isTimedExpired,
                viewDuration: message.viewDuration,
                isMine: isMine,
                color: fg,
                onTap: !isMine &&
                        message.viewedAt == null &&
                        !message.isTimedExpired
                    ? onOpenViewOnce
                    : null,
              )
            else if (message.messageType == 'image' && mediaUrl.isNotEmpty)
              SpoilerWidget(
                isSpoiler: message.isSpoiler,
                child: Semantics(
                  button: true,
                  label: labels.photo,
                  child: GestureDetector(
                    onTap: onOpenPhoto,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 340),
                        child: _BubbleImage(
                          mediaId: message.mediaId,
                          mediaUrl: mediaUrl,
                          token: token,
                          isDark: isDark,
                          isMine: isMine,
                          fallbackColor: fg,
                          primary: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else if (message.messageType == 'video' && mediaUrl.isNotEmpty)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.isMuted)
                    Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.volume_off_rounded, size: 12, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(labels.isFa ? 'بی‌صدا' : 'Muted', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  SpoilerWidget(
                    isSpoiler: message.isSpoiler,
                    child: VideoMessagePlayer(
                      url: mediaUrl,
                      authToken: token,
                      isMine: isMine,
                      coordinator: coordinator,
                      muted: message.isMuted,
                      mediaId: message.mediaId,
                    ),
                  ),
                ],
              )
            else if (message.messageType == 'video_note' || message.messageType == 'round_video')
              mediaUrl.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: VideoNotePlayer(url: mediaUrl, authToken: token, size: 180, mediaId: message.mediaId),
                    )
                  : SpoilerWidget(
                      isSpoiler: message.isSpoiler,
                      child: MessageText(
                        text: '${labels.isFa ? 'ویدیو مسیج' : 'Video message'} ${message.content ?? ''}'.trim(),
                        style: TextStyle(color: fg, fontSize: 14),
                        linkColor: isMine ? Colors.white : theme.colorScheme.primary,
                        onInviteTap: onInviteTap,
                        onMentionTap: onMentionTap,
                      ),
                    )
            else if (message.messageType == 'sticker')
              mediaUrl.isNotEmpty
                  ? GestureDetector(
                      onTap: onOpenPhoto,
                      child: CachedNetworkImage(
                        imageUrl: mediaUrl,
                        httpHeaders: token == null ? null : {'Authorization': 'Bearer $token'},
                        width: 150,
                        height: 150,
                        fit: BoxFit.contain,
                        placeholder: (_, __) => const SizedBox(
                          width: 80,
                          height: 80,
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                        errorWidget: (_, __, ___) => Text(
                          message.content ?? (labels.isFa ? 'استیکر' : 'Sticker'),
                          style: const TextStyle(fontSize: 48),
                        ),
                      ),
                    )
                  : Text(message.content ?? (labels.isFa ? 'استیکر' : 'Sticker'), style: TextStyle(fontSize: 48, color: fg))
            else if (message.messageType == 'gif')
              mediaUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        children: [
                          CachedNetworkImage(
                            imageUrl: mediaUrl,
                            httpHeaders: token == null ? null : {'Authorization': 'Bearer $token'},
                            width: 230,
                            height: 165,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                              width: 230,
                              height: 165,
                              color: Colors.black12,
                              child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              width: 230,
                              height: 120,
                              color: Colors.black12,
                              child: Icon(Icons.gif_box_rounded, color: fg, size: 36),
                            ),
                          ),
                          Positioned(
                            bottom: 6,
                            left: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'GIF',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : MessageText(
                      text: message.content ?? 'GIF',
                      style: TextStyle(color: fg),
                      linkColor: isMine ? Colors.white : theme.colorScheme.primary,
                      onInviteTap: onInviteTap,
                      onMentionTap: onMentionTap,
                    )
            else if (message.messageType == 'voice')
              VoiceMessagePlayer(
                url: mediaUrl,
                token: token,
                foreground: fg,
                coordinator: coordinator,
                mediaId: message.mediaId,
              )
            else if (message.isMusic)
              MusicMessageBubble(
                message: message,
                isMine: isMine,
                foreground: fg,
                queue: musicQueue.isEmpty ? [message] : musicQueue,
                chatTitle: chatTitle,
                token: token,
              )
            else if (message.messageType == 'file')
              FileMessageBubble(
                message: message,
                mediaUrl: mediaUrl,
                token: token,
                isMine: isMine,
                foregroundColor: fg,
              )
            else
              SpoilerWidget(
                isSpoiler: message.isSpoiler,
                child: MessageText(
                  text: displayContent?.isNotEmpty == true
                      ? displayContent!
                      : labels.type(message.messageType),
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    height: 1.38,
                    letterSpacing: -0.1,
                  ),
                  linkColor: isMine ? Colors.white : theme.colorScheme.primary,
                  onInviteTap: onInviteTap,
                  onMentionTap: onMentionTap,
                ),
              ),
            if (hasCaption)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: MessageText(
                  text: displayContent!,
                  style: TextStyle(color: fg, fontSize: 14.5),
                  linkColor: isMine ? Colors.white : theme.colorScheme.primary,
                  onInviteTap: onInviteTap,
                  onMentionTap: onMentionTap,
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.forwardedFromId != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forward_rounded, size: 11, color: isMine ? Colors.white70 : const Color(0xFF64748B)),
                          const SizedBox(width: 2),
                          Text(
                            labels.isFa ? 'فوروارد شده' : 'Forwarded',
                            style: TextStyle(color: isMine ? Colors.white70 : const Color(0xFF64748B), fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  if (message.isEdited)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        labels.isFa ? 'ویرایش شده' : 'Edited',
                        style: TextStyle(
                          color: isMine ? Colors.white70 : const Color(0xFF64748B),
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  Text(
                    '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      color: isMine
                          ? Colors.white.withValues(alpha: 0.82)
                          : (isDark ? Colors.white60 : const Color(0xFF64748B)),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    Icon(
                      message.status == 'sent' ? Icons.done_rounded : Icons.done_all_rounded,
                      size: 16,
                      color: message.status == 'read'
                          ? const Color(0xFF80D8FF)
                          : Colors.white70,
                    ),
                  ],
                ],
              ),
            ),
            if (message.reactions.isNotEmpty)
              ReactionBar(
                reactions: message.reactions,
                isMine: isMine,
                onReactionTap: onReactionTap,
                onAddReaction: onAddReaction,
              ),
          ],
        ),
      ),
    );
  }
}

/// Bubble photo: the offline vault's local copy wins when present (works
/// with no connection at all); otherwise the network image, exactly as
/// before. Placeholder and error states are visually identical either way.
/// Once the network copy has actually been displayed, it is mirrored into
/// the vault so the same photo opens offline next time.
class _BubbleImage extends StatefulWidget {
  final String? mediaId;
  final String mediaUrl;
  final String? token;
  final bool isDark;
  final bool isMine;
  final Color fallbackColor;
  final Color primary;

  const _BubbleImage({
    required this.mediaId,
    required this.mediaUrl,
    required this.token,
    required this.isDark,
    required this.isMine,
    required this.fallbackColor,
    required this.primary,
  });

  @override
  State<_BubbleImage> createState() => _BubbleImageState();
}

class _BubbleImageState extends State<_BubbleImage> {
  bool _mirrorScheduled = false;

  void _scheduleMirror() {
    if (_mirrorScheduled || widget.mediaId == null) return;
    _mirrorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        MediaCacheService.instance.storeFromImageCache(
          widget.mediaId,
          widget.mediaUrl,
        ),
      );
    });
  }

  Widget _placeholder() => Container(
        width: 280,
        height: 180,
        color: widget.isDark ? Colors.black26 : const Color(0xFFF1F5F9),
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.isMine ? Colors.white70 : widget.primary,
          ),
        ),
      );

  Widget _error() => Container(
        width: 220,
        height: 110,
        color: widget.isDark ? Colors.black26 : const Color(0xFFF1F5F9),
        child: Center(
          child: Icon(
            Icons.broken_image_rounded,
            size: 40,
            color: widget.fallbackColor.withValues(alpha: 0.6),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final localPath = MediaCacheService.instance.localPathSync(widget.mediaId);
    if (localPath != null) {
      return Image.file(
        File(localPath),
        width: 280,
        fit: BoxFit.cover,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            frame == null && !wasSynchronouslyLoaded ? _placeholder() : child,
        errorBuilder: (_, __, ___) => _error(),
      );
    }
    return CachedNetworkImage(
      imageUrl: widget.mediaUrl,
      httpHeaders:
          widget.token == null ? null : {'Authorization': 'Bearer ${widget.token}'},
      width: 280,
      fit: BoxFit.cover,
      placeholder: (_, __) => _placeholder(),
      errorWidget: (_, __, ___) => _error(),
      imageBuilder: (context, provider) {
        // The bytes are on the device now; keep a vault copy for offline.
        _scheduleMirror();
        return Image(image: provider, width: 280, fit: BoxFit.cover);
      },
    );
  }
}

class _ExpiredMediaTile extends StatelessWidget {
  const _ExpiredMediaTile({
    required this.messageType,
    required this.foreground,
  });

  final String messageType;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (messageType) {
      'video' || 'video_note' || 'round_video' => Icons.videocam_off_outlined,
      'voice' || 'audio' || 'music' => Icons.audiotrack_rounded,
      'file' => Icons.insert_drive_file_outlined,
      _ => Icons.image_not_supported_outlined,
    };
    return Container(
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 270),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: foreground.withValues(alpha: 0.75), size: 24),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  MediaLabels.of(context).mediaExpired,
                  style: TextStyle(color: foreground, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  MediaLabels.of(context).mediaExpiredNotice,
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.78),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewOnceTile extends StatelessWidget {
  final bool viewed;
  final bool expired;
  final int? viewDuration;
  final bool isMine;
  final Color color;
  final VoidCallback? onTap;

  const _ViewOnceTile({
    required this.viewed,
    this.expired = false,
    this.viewDuration,
    required this.isMine,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final labels = MediaLabels.of(context);
    final timed = (viewDuration ?? 0) > 0;
    final title = timed
        ? (labels.isFa
            ? 'عکس زمان‌دار ($viewDuration ثانیه)'
            : 'Timed photo ($viewDuration seconds)')
        : (viewed ? labels.viewed : labels.viewOnce);
    final subtitle = expired
        ? (labels.isFa ? 'این عکس منقضی شده است' : 'This photo has expired')
        : (isMine ? labels.sentOnce : labels.tapToOpen);

    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.12),
                  border: Border.all(color: color.withValues(alpha: 0.25), width: 1.2),
                ),
                child: Icon(
                  viewed || expired
                      ? Icons.timer_off_rounded
                      : timed
                          ? Icons.timer_10_rounded
                          : Icons.timer_rounded,
                  color: color,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    if (!viewed) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: color.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ],
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
