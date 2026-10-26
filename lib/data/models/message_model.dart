import '../../core/utils/api_datetime.dart';
import 'package:equatable/equatable.dart';

import 'user_model.dart';
import 'reply_preview_model.dart';
import 'poll_model.dart';
import 'reaction_model.dart';

/// Publishing admin signature (Telegram-like channel/group author label).
class MessageAuthor extends Equatable {
  final String id;
  final String displayName;
  final String? username;
  const MessageAuthor({required this.id, required this.displayName, this.username});
  factory MessageAuthor.fromJson(Map<String, dynamic> json) => MessageAuthor(
        id: json['id'] as String,
        displayName: json['display_name'] as String? ?? '',
        username: json['username'] as String?,
      );
  @override
  List<Object?> get props => [id, displayName, username];
}

class MessageModel extends Equatable {
  final String id;
  final String chatId;
  final String senderId;
  final UserModel? sender;
  final MessageAuthor? author;
  final String messageType;
  final String? content;
  final String? mediaId;
  final String? mediaUrl;
  final bool mediaExpired;
  final String? replyToId;
  final ReplyPreviewModel? replyTo;
  final String? forwardedFromId;
  final bool isViewOnce;
  final bool isSpoiler;
  final bool isScheduled;
  final DateTime? scheduledAt;
  final String? originalName;
  final int? fileSize;
  final bool isPinned;
  final DateTime? viewedAt;
  // Timed photo (Item 2): null = classic view-once (open until exit),
  // otherwise auto-close N seconds after opening (Telegram-like).
  final int? viewDuration;
  final DateTime? viewExpiresAt;
  final bool isEdited;
  final DateTime? editedAt;
  // Encrypted (password-protected) messages
  final bool isEncrypted;
  final String? encryptionHint;
  // Secure-mode messages
  final bool isSecure;
  // Location messages
  final double? latitude;
  final double? longitude;
  final String? locationTitle;
  final DateTime? liveUntil;
  // Music / audio messages
  final String? audioTitle;
  final String? audioArtist;
  final double? audioDuration;
  // Video editor: muted videos play silently on every client
  final bool isMuted;
  // Polls & quizzes (Telegram parity): present for messageType == 'poll'.
  final String? pollId;
  final PollModel? poll;
  final DateTime createdAt;
  final String status; // sent | delivered | read
  final List<ReactionModel> reactions;

  const MessageModel({
    required this.id,
    required this.chatId,
    required this.senderId,
    this.sender,
    this.author,
    required this.messageType,
    this.content,
    this.mediaId,
    this.mediaUrl,
    this.mediaExpired = false,
    this.replyToId,
    this.replyTo,
    this.forwardedFromId,
    this.isViewOnce = false,
    this.isSpoiler = false,
    this.isScheduled = false,
    this.scheduledAt,
    this.originalName,
    this.fileSize,
    this.isPinned = false,
    this.viewedAt,
    this.viewDuration,
    this.viewExpiresAt,
    this.isEdited = false,
    this.editedAt,
    this.isEncrypted = false,
    this.encryptionHint,
    this.isSecure = false,
    this.latitude,
    this.longitude,
    this.locationTitle,
    this.liveUntil,
    this.audioTitle,
    this.audioArtist,
    this.audioDuration,
    this.isMuted = false,
    this.pollId,
    this.poll,
    required this.createdAt,
    this.status = 'sent',
    this.reactions = const [],
  });

  bool get isLocation => messageType == 'location' || messageType == 'live_location';
  /// A view-once photo with a countdown (10s in the UI, 1-120s server-side).
  bool get isTimedPhoto => isViewOnce && (viewDuration ?? 0) > 0;
  /// True once the server deadline passed (or the photo was consumed).
  bool get isTimedExpired =>
      viewExpiresAt != null && !viewExpiresAt!.isAfter(DateTime.now());
  bool get isLiveLocation => messageType == 'live_location';
  bool get isLiveActive => isLiveLocation && liveUntil != null && liveUntil!.isAfter(DateTime.now());
  bool get isMusic => messageType == 'audio' || messageType == 'music';
  bool get isPoll => messageType == 'poll' && poll != null;
  bool get isVoiceOrMusic => messageType == 'voice' || isMusic;

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      senderId: json['sender_id'] as String,
      sender: json['sender'] != null
          ? UserModel.fromJson(json['sender'] as Map<String, dynamic>)
          : null,
      author: json['author'] is Map<String, dynamic>
          ? MessageAuthor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      messageType: json['message_type'] as String? ?? 'text',
      content: json['content'] as String?,
      mediaId: json['media_id'] as String?,
      mediaUrl: json['media_url'] as String?,
      mediaExpired: json['media_expired'] as bool? ?? false,
      replyToId: json['reply_to_id'] as String?,
      replyTo: json['reply_to'] is Map<String, dynamic>
          ? ReplyPreviewModel.fromJson(json['reply_to'] as Map<String, dynamic>)
          : null,
      forwardedFromId: json['forwarded_from_id'] as String?,
      isViewOnce: json['is_view_once'] as bool? ?? false,
      isSpoiler: json['is_spoiler'] as bool? ?? false,
      isScheduled: json['is_scheduled'] as bool? ?? false,
      scheduledAt: json['scheduled_at'] != null
          ? parseApiDateTime(json['scheduled_at'] as String?)
          : null,
      originalName: json['original_name'] as String?,
      fileSize: json['file_size'] as int?,
      isPinned: json['is_pinned'] as bool? ?? false,
      viewedAt: json['viewed_at'] != null
          ? parseApiDateTime(json['viewed_at'] as String?)
          : null,
      viewDuration: (json['view_duration'] as num?)?.toInt(),
      viewExpiresAt: json['view_expires_at'] != null
          ? parseApiDateTime(json['view_expires_at'] as String?)
          : null,
      isEdited: json['is_edited'] as bool? ?? false,
      editedAt: json['edited_at'] != null
          ? parseApiDateTime(json['edited_at'] as String?)
          : null,
      isEncrypted: json['is_encrypted'] as bool? ?? false,
      encryptionHint: json['encryption_hint'] as String?,
      isSecure: json['is_secure'] as bool? ?? false,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationTitle: json['location_title'] as String?,
      liveUntil: json['live_until'] != null
          ? parseApiDateTime(json['live_until'] as String?)
          : null,
      audioTitle: json['audio_title'] as String?,
      audioArtist: json['audio_artist'] as String?,
      audioDuration: (json['audio_duration'] as num?)?.toDouble(),
      isMuted: json['is_muted'] as bool? ?? false,
      pollId: json['poll_id'] as String?,
      poll: json['poll'] is Map<String, dynamic>
          ? PollModel.fromJson(json['poll'] as Map<String, dynamic>)
          : null,
      createdAt: json['created_at'] != null
          ? parseApiDateTime(json['created_at'] as String?) ?? DateTime.now()
          : DateTime.now(),
      status: json['status'] as String? ?? 'sent',
      reactions: (json['reactions'] as List?)?.map((e) => ReactionModel.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    );
  }

  /// The exact inverse of [MessageModel.fromJson], used by the offline
  /// cache so a stored message re-opens identically (Telegram-style).
  Map<String, dynamic> toJson() => {
        'id': id,
        'chat_id': chatId,
        'sender_id': senderId,
        'sender': sender?.toJson(),
        'author': author == null
            ? null
            : {
                'id': author!.id,
                'display_name': author!.displayName,
                'username': author!.username,
              },
        'message_type': messageType,
        'content': content,
        'media_id': mediaId,
        'media_url': mediaUrl,
        'media_expired': mediaExpired,
        'reply_to_id': replyToId,
        'reply_to': replyTo?.toJson(),
        'forwarded_from_id': forwardedFromId,
        'is_view_once': isViewOnce,
        'is_spoiler': isSpoiler,
        'is_scheduled': isScheduled,
        'scheduled_at': scheduledAt?.toUtc().toIso8601String(),
        'original_name': originalName,
        'file_size': fileSize,
        'is_pinned': isPinned,
        'viewed_at': viewedAt?.toUtc().toIso8601String(),
        'view_duration': viewDuration,
        'view_expires_at': viewExpiresAt?.toUtc().toIso8601String(),
        'is_edited': isEdited,
        'edited_at': editedAt?.toUtc().toIso8601String(),
        'is_encrypted': isEncrypted,
        'encryption_hint': encryptionHint,
        'is_secure': isSecure,
        'latitude': latitude,
        'longitude': longitude,
        'location_title': locationTitle,
        'live_until': liveUntil?.toUtc().toIso8601String(),
        'audio_title': audioTitle,
        'audio_artist': audioArtist,
        'audio_duration': audioDuration,
        'is_muted': isMuted,
        'poll_id': pollId,
        'poll': poll?.toJson(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'status': status,
        'reactions': reactions.map((r) => r.toJson()).toList(),
      };

  MessageModel copyWith({
    String? status,
    String? content,
    bool? mediaExpired,
    bool? isViewOnce,
    bool? isSpoiler,
    bool? isScheduled,
    DateTime? scheduledAt,
    bool? isPinned,
    DateTime? viewedAt,
    int? viewDuration,
    DateTime? viewExpiresAt,
    bool? isEdited,
    DateTime? editedAt,
    bool? isEncrypted,
    String? encryptionHint,
    double? latitude,
    double? longitude,
    DateTime? liveUntil,
    ReplyPreviewModel? replyTo,
    List<ReactionModel>? reactions,
    PollModel? poll,
  }) {
    return MessageModel(
      id: id,
      chatId: chatId,
      senderId: senderId,
      sender: sender,
      author: author,
      messageType: messageType,
      content: content ?? this.content,
      mediaId: mediaId,
      mediaUrl: mediaUrl,
      mediaExpired: mediaExpired ?? this.mediaExpired,
      replyToId: replyToId,
      replyTo: replyTo ?? this.replyTo,
      forwardedFromId: forwardedFromId,
      isViewOnce: isViewOnce ?? this.isViewOnce,
      isSpoiler: isSpoiler ?? this.isSpoiler,
      isScheduled: isScheduled ?? this.isScheduled,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      originalName: originalName,
      fileSize: fileSize,
      isPinned: isPinned ?? this.isPinned,
      viewedAt: viewedAt ?? this.viewedAt,
      viewDuration: viewDuration ?? this.viewDuration,
      viewExpiresAt: viewExpiresAt ?? this.viewExpiresAt,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      encryptionHint: encryptionHint ?? this.encryptionHint,
      isSecure: isSecure,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationTitle: locationTitle,
      liveUntil: liveUntil ?? this.liveUntil,
      audioTitle: audioTitle,
      audioArtist: audioArtist,
      audioDuration: audioDuration,
      isMuted: isMuted,
      pollId: pollId,
      poll: poll ?? this.poll,
      createdAt: createdAt,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
    );
  }

  /// View-once / encrypted content and empty media placeholders are never copied.
  String? get copyableText =>
      !isViewOnce && !isEncrypted && content?.trim().isNotEmpty == true ? content : null;

  ReplyPreviewModel get asReplyPreview => ReplyPreviewModel(
    id: id,
    senderId: senderId,
    senderName: sender?.displayName,
    messageType: messageType,
    content: isViewOnce || isEncrypted ? null : content,
    mediaUrl: isViewOnce || isEncrypted || mediaExpired || messageType != 'image'
        ? null
        : mediaUrl ?? (mediaId == null ? null : '/api/v1/media/$mediaId'),
    isViewOnce: isViewOnce,
    mediaExpired: mediaExpired,
  );

  @override
  List<Object?> get props => [
    id,
    chatId,
    senderId,
    sender,
    author,
    messageType,
    content,
    createdAt,
    status,
    mediaId,
    mediaUrl,
    mediaExpired,
    replyToId,
    replyTo,
    forwardedFromId,
    isViewOnce,
    isSpoiler,
    isScheduled,
    scheduledAt,
    originalName,
    fileSize,
    isPinned,
    viewedAt,
    viewDuration,
    viewExpiresAt,
    isEdited,
    editedAt,
    isEncrypted,
    encryptionHint,
    isSecure,
    latitude,
    longitude,
    locationTitle,
    liveUntil,
    audioTitle,
    audioArtist,
    audioDuration,
    isMuted,
    pollId,
    poll,
    reactions,
  ];
}
