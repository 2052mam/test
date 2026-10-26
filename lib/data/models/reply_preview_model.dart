import 'package:equatable/equatable.dart';

/// A bounded, non-recursive quote. Unavailable originals never expose content.
class ReplyPreviewModel extends Equatable {
  final String id;
  final String? senderId;
  final String? senderName;
  final String messageType;
  final String? content;
  final String? mediaUrl;
  final bool isViewOnce;
  final bool isUnavailable;
  final bool mediaExpired;

  const ReplyPreviewModel({
    required this.id,
    this.senderId,
    this.senderName,
    this.messageType = 'text',
    this.content,
    this.mediaUrl,
    this.isViewOnce = false,
    this.isUnavailable = false,
    this.mediaExpired = false,
  });

  const ReplyPreviewModel.unavailable(this.id)
    : senderId = null,
      senderName = null,
      messageType = 'text',
      content = null,
      mediaUrl = null,
      isViewOnce = false,
      isUnavailable = true,
      mediaExpired = false;

  factory ReplyPreviewModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (json['is_unavailable'] == true) {
      return ReplyPreviewModel.unavailable(id);
    }
    final isViewOnce = json['is_view_once'] == true;
    return ReplyPreviewModel(
      id: id,
      senderId: json['sender_id'] as String?,
      senderName: json['sender_name'] as String?,
      messageType: json['message_type'] as String? ?? 'text',
      content: isViewOnce ? null : json['content'] as String?,
      mediaUrl: isViewOnce ? null : json['media_url'] as String?,
      isViewOnce: isViewOnce,
      mediaExpired: json['media_expired'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender_id': senderId,
        'sender_name': senderName,
        'message_type': messageType,
        'content': content,
        'media_url': mediaUrl,
        'is_view_once': isViewOnce,
        'is_unavailable': isUnavailable,
        'media_expired': mediaExpired,
      };

  @override
  List<Object?> get props => [
    id,
    senderId,
    senderName,
    messageType,
    content,
    mediaUrl,
    isViewOnce,
    isUnavailable,
    mediaExpired,
  ];
}
