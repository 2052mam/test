import 'package:file_picker/file_picker.dart';
import '../../widgets/chat/scheduled_messages_sheet.dart';
import '../../../core/utils/api_datetime.dart';
import 'chat_management_screen.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';

import '../../../data/models/message_model.dart';
import '../../../data/models/poll_model.dart';
import '../../../data/models/user_model.dart';
import '../../../data/models/chat_invite_model.dart';
import '../../../data/services/message_reconciler.dart';
import '../../../core/utils/chat_invite_link.dart';
import '../../../data/models/reply_preview_model.dart';
import '../../../data/services/media_cache_service.dart';
import '../../../data/services/media_limits_service.dart';
import '../../../data/services/offline_cache_service.dart';
import '../../../data/services/upload_queue.dart';
import '../../../data/services/chat_navigation.dart';
import '../../../data/services/media_playback_coordinator.dart';
import '../../../core/utils/media_utils.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/notification_service.dart';
import '../../../data/services/storage_service.dart';
import '../../../data/services/voice_service.dart';
import '../../../data/services/location_service.dart';
import '../../../data/services/sound_service.dart';
import '../../../core/constants/api_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_list_provider.dart';
import '../profile/user_profile_screen.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/chat_header.dart';
import '../../widgets/chat/chat_labels.dart';
import '../../widgets/chat/chat_invite_dialog.dart';
import '../../widgets/chat/message_actions_sheet.dart';
import '../../widgets/chat/pinned_messages_bar.dart';
import '../../widgets/chat/reaction_bar.dart';
import '../../widgets/chat/sticker_picker.dart';
import '../../widgets/chat/gif_picker.dart';
import '../../widgets/chat/report_dialog.dart';
import '../../widgets/chat/encrypted_bubble.dart';
import '../../../data/services/encryption_service.dart';
import '../../widgets/media/video_note_player.dart';
import '../../widgets/music/mini_music_player.dart';
import 'pinned_messages_screen.dart';
import 'create_poll_screen.dart';
import 'location_picker_screen.dart';
import 'secure_chat_screen.dart';
import 'photo_editor_screen.dart';
import 'video_editor_screen.dart';
import '../../widgets/chat/reply_preview.dart';
import '../../widgets/chat/chat_upload_indicator.dart';
import '../../widgets/media/media_labels.dart';
import '../media/photo_viewer_screen.dart';
import '../media/view_once_photo_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String title;
  final String chatType;
  final UserModel? otherUser;
  final String? avatarUrl;
  const ChatScreen({
    super.key,
    required this.chatId,
    required this.title,
    this.chatType = 'private',
    this.otherUser,
    this.avatarUrl,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  late ApiService _api;
  late String? _authToken;
  late final String? _sessionUserId;
  final _reconciler = MessageReconciler();
  UserModel? _otherUser;
  String? _loadedChatType;
  String? _chatTitle;
  String? _chatAvatarUrl;
  bool _hasChatInfo = false;
  bool _refreshingChatInfo = false;
  bool _chatUnavailable = false;
  bool _allowForwarding = true;
  bool _openingInvite = false;
  Route<void>? _photoRoute;
  String? _photoMessageId;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<MessageModel> _messages = [];
  final VoiceService _voice = VoiceService();
  final _playback = MediaPlaybackCoordinator();
  final Map<String, GlobalKey> _messageKeys = {};
  Timer? _highlightTimer;
  String? _highlightedMessageId;
  bool _openingMedia = false;
  bool _jumpingToReply = false;
  bool _historyMode = false;
  bool _hasEarlier = false;
  bool _loadingEarlier = false;
  bool _polling = false;
  bool _refreshingStatuses = false;
  DateTime? _lastAuxiliaryPollAt;
  int _loadGeneration = 0;
  bool _loading = true;
  bool _sending = false;

  /// Upload jobs live in the app-scoped queue, not this route, so they keep
  /// running and remain visible if the user leaves and reopens the chat.
  bool _searchMode = false;
  String? _error;
  Timer? _pollTimer;
  String? _lastMessageId;

  /// Timestamp of [_lastMessageId]. Sent alongside the cursor so the server can
  /// recover when the cursor message has been hard-deleted (Point 4): without
  /// it a stale cursor used to 404 forever and the group/channel stopped
  /// updating until the user backed out and re-entered.
  DateTime? _lastMessageAt;
  String? _currentUserId;
  MessageModel? _replyTo;
  Color? _bgColor;
  String? _bgImageUrl;
  bool _isRecording = false;
  String? _myRole;
  Map<String, dynamic> _capabilities = {};
  bool _isMuted = false;
  bool _muting = false;
  final List<MessageModel> _pinned = [];
  int _pinnedIndex = 0;
  bool _canPinMessages = false;
  bool _loadingPinned = false;
  bool _isSpoiler = false;
  int _slowModeDelay = 0;
  int _slowModeRemaining = 0;
  Timer? _slowModeTimer;
  // Poll id whose vote/close request is currently in flight.
  String? _pollBusyId;
  // True while this chat has an ongoing (non-erased) secure conversation.
  bool _hasSecureSession = false;
  // Live location: id of the message currently being broadcast + its ticker.
  String? _liveLocationMessageId;
  DateTime? _liveLocationUntil;
  Timer? _liveLocationTimer;

  bool _can(String right) {
    if (_chatUnavailable) return false;
    // Point 7: the Security Support chat is one-way — the server writes, the
    // user only reads. The backend enforces this too; hiding the composer
    // just avoids offering an action that would always be refused.
    if (_chatType == 'security') return false;
    if (_chatType != 'group' && _chatType != 'channel') return true;
    return _capabilities[right] == true;
  }

  bool _canDelete(MessageModel msg) {
    if (_chatType == 'private' ||
        _chatType == 'saved' ||
        _chatType == 'security') return true;
    if (_chatType == 'support')
      return msg.senderId == _currentUserId ||
          _myRole == 'owner' ||
          _myRole == 'admin';
    if (_chatType == 'channel') return _can('delete_messages');
    return _can('delete_messages') ||
        (msg.senderId == _currentUserId && _can('delete_own_messages'));
  }

  int _membersCount = 0;
  int _onlineCount = 0;
  bool _hideMembers = false;
  bool _isSuspended = false;
  String? _suspensionReason;
  bool _isClosed = false;
  String? _closedReason;

  String get _chatType => _loadedChatType ?? widget.chatType;
  String get _displayTitle =>
      _otherUser?.displayName ?? _chatTitle ?? widget.title;
  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  String _mediaFullUrl(String? mediaId, {String? existingUrl}) =>
      resolveMediaUrl(mediaId, existingUrl: existingUrl);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final session = ref.read(authenticatedSessionProvider);
    _sessionUserId = session.userId;
    _authToken = session.token;
    _api = session.api;
    _otherUser = widget.otherUser;
    _chatAvatarUrl = widget.avatarUrl;
    _currentUserId =
        ref.read(authNotifierProvider).valueOrNull?.id ??
        StorageService.getUserId();
    // The open chat never raises a banner for itself, and opening it clears
    // any banner it raised earlier (Telegram behaviour).
    NotificationService().suppressedChats.add(widget.chatId);
    unawaited(NotificationService().cancelForChat(widget.chatId));
    _seedFromOfflineCache();
    unawaited(
      MediaLimitsService.instance.ensureLoaded(_api, userId: _sessionUserId),
    );
    _loadMessages();
    _startPolling();
    _loadBackground();
    _loadChatInfo();
    _loadPinned();
    _checkSecureSession();
  }

  Future<void> _loadBackground() async {
    try {
      final res = await _api.get('/chats/${widget.chatId}/background');
      final bg = res['background'] as Map<String, dynamic>?;
      if (bg == null) return;
      _applyBackground(bg);
      final userId = _sessionUserId;
      if (userId != null) {
        unawaited(
          OfflineCacheService.instance.saveChatMeta(
            userId,
            widget.chatId,
            'background',
            res,
          ),
        );
      }
    } catch (_) {}
  }

  void _applyBackground(Map<String, dynamic> bg, {bool notify = true}) {
    final type = bg['type'] as String?;
    final value = bg['value'] as String?;
    if (value == null || value.isEmpty) return;
    if (type == 'image') {
      if (notify) {
        if (mounted) setState(() => _bgImageUrl = value);
      } else {
        _bgImageUrl = value;
      }
    } else if (type == 'color') {
      final hex = value.replaceFirst('#', '');
      final colorValue = int.tryParse(hex, radix: 16);
      if (colorValue != null) {
        if (notify) {
          if (mounted) setState(() => _bgColor = Color(colorValue | 0xFF000000));
        } else {
          _bgColor = Color(colorValue | 0xFF000000);
        }
      }
    }
  }

  Future<void> _loadChatInfo() async {
    if (!mounted || _refreshingChatInfo || _chatUnavailable) return;
    _refreshingChatInfo = true;
    try {
      final res = await _api.get('/chats/${widget.chatId}/info');
      if (!mounted) return;
      if (res['my_role'] == null &&
          ['group', 'channel'].contains(res['chat_type'])) {
        _showChatUnavailable();
        return;
      }
      _applyChatInfo(res);
      final userId = _sessionUserId;
      if (userId != null) {
        unawaited(
          OfflineCacheService.instance.saveChatMeta(
            userId,
            widget.chatId,
            'info',
            res,
          ),
        );
      }
      if (_isRecording && !_can('send_voice')) {
        setState(() => _isRecording = false);
        await _voice.cancelRecording();
      }
    } on ApiException catch (error) {
      if ([403, 404].contains(error.statusCode)) _showChatUnavailable();
    } catch (_) {
      // Keep the last known profile during a temporary network failure.
    } finally {
      _refreshingChatInfo = false;
    }
  }

  void _showChatUnavailable() {
    if (!mounted || _chatUnavailable) return;
    _pollTimer?.cancel();
    unawaited(_playback.pause());
    final route = _photoRoute;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    setState(() {
      ++_loadGeneration;
      _chatUnavailable = true;
      _loading = false;
      _error = ChatLabels.of(context).chatUnavailable;
      _messages.clear();
      _messageKeys.clear();
      _replyTo = null;
    });
  }

  @override
  void dispose() {
    ++_loadGeneration;
    NotificationService().suppressedChats.remove(widget.chatId);
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _highlightTimer?.cancel();
    _slowModeTimer?.cancel();
    _liveLocationTimer?.cancel();
    unawaited(_playback.pause());
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _voice.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_playback.pause());
    } else {
      _pollNow();
    }
  }

  Future<void> _markChatRead() async {
    if (!mounted ||
        !_foreground ||
        _chatUnavailable ||
        ModalRoute.of(context)?.isCurrent == false)
      return;
    try {
      await _api.post('/messages/chat/${widget.chatId}/read', {});
      if (!mounted) return;
      ref.read(chatListProvider.notifier).refresh();
    } catch (_) {}
  }

  /// Applies a `/chats/<id>/info` payload (live or from the offline cache).
  void _applyChatInfo(Map<String, dynamic> res, {bool notify = true}) {
    void assign() {
      _myRole = res['my_role'] as String?;
      _capabilities = Map<String, dynamic>.from(
        res['capabilities'] as Map? ?? {},
      );
      _isMuted = res['is_muted'] as bool? ?? false;
      _slowModeDelay = res['slow_mode_delay'] as int? ?? 0;
      _membersCount = res['members_count'] as int? ?? 0;
      _onlineCount = res['online_count'] as int? ?? 0;
      _hideMembers = res['hide_members'] as bool? ?? false;
      _isSuspended = res['is_suspended'] as bool? ?? false;
      _suspensionReason = res['suspension_reason'] as String?;
      _isClosed = res['is_closed'] as bool? ?? false;
      _closedReason = res['closed_reason'] as String?;
      _loadedChatType = res['chat_type'] as String?;
      _allowForwarding = res['allow_forwarding'] as bool? ?? true;
      _chatTitle = res['title'] as String?;
      _chatAvatarUrl = res['avatar_url'] as String?;
      _otherUser = res['other_user'] is Map<String, dynamic>
          ? UserModel.fromJson(res['other_user'] as Map<String, dynamic>)
          : null;
      _hasChatInfo = true;
      if (!_can('send_messages')) _replyTo = null;
    }

    if (notify && mounted) {
      setState(assign);
    } else {
      assign();
    }
  }

  /// Offline-first seeding: the previous history, chat info, pinned messages
  /// and background are restored synchronously, so opening a chat with no
  /// connection shows the conversation instead of an internet error. The
  /// network refresh that follows simply replaces them when it succeeds.
  void _seedFromOfflineCache() {
    final userId = _sessionUserId;
    if (userId == null) return;
    final cache = OfflineCacheService.instance;
    try {
      final cachedMessages = cache.messagesSync(userId, widget.chatId);
      if (cachedMessages.isNotEmpty) {
        _messages.addAll(_reconciler.reconcile(cachedMessages));
        _lastMessageId = _messages.last.id;
        _lastMessageAt = _messages.last.createdAt;
        _loading = false;
      }
    } catch (_) {}
    try {
      final info = cache.chatMetaSync(userId, widget.chatId, 'info');
      if (info != null) _applyChatInfo(info, notify: false);
    } catch (_) {}
    try {
      final pinned = cache.chatMetaSync(userId, widget.chatId, 'pinned');
      if (pinned != null) {
        _pinned.addAll(
          (pinned['messages'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(MessageModel.fromJson)
              .where((m) => !_reconciler.isUnavailable(m.id)),
        );
        _canPinMessages = pinned['can_pin'] == true;
      }
    } catch (_) {}
    try {
      final background = cache.chatMetaSync(
        userId,
        widget.chatId,
        'background',
      );
      final bg = background?['background'] as Map<String, dynamic>?;
      if (bg != null) _applyBackground(bg, notify: false);
    } catch (_) {}
  }

  void _persistMessages({bool replace = false}) {
    final userId = _sessionUserId;
    if (userId == null) return;
    if (replace) {
      unawaited(
        OfflineCacheService.instance.replaceMessages(
          userId,
          widget.chatId,
          List<MessageModel>.from(_messages),
        ),
      );
      return;
    }
    if (_messages.isEmpty) return;
    unawaited(
      OfflineCacheService.instance.saveMessages(
        userId,
        widget.chatId,
        List<MessageModel>.from(_messages),
      ),
    );
  }

  Future<void> _loadMessages({String? query}) async {
    if (!mounted || _chatUnavailable) return;
    final generation = ++_loadGeneration;
    setState(() {
      // With history already on screen (offline cache), keep it visible
      // while this refreshes; the spinner is only for an empty chat.
      _loading = _messages.isEmpty;
      _error = null;
    });
    try {
      final Map<String, dynamic> res;
      if (query != null && query.length >= 2) {
        res = await _api.get(
          '/messages/search/${widget.chatId}',
          query: {'q': query},
        );
      } else {
        res = await _api.get('/messages/${widget.chatId}');
      }
      if (!mounted || generation != _loadGeneration) return;
      final rawMessages = (res['messages'] as List? ?? [])
          .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
          .toList();
      final list = _reconciler.reconcile(rawMessages);
      setState(() {
        _messages
          ..clear()
          ..addAll(list);
        _messageKeys.removeWhere((id, _) => !list.any((m) => m.id == id));
        if (query == null) {
          _lastMessageId = rawMessages.isEmpty ? null : rawMessages.last.id;
          _lastMessageAt =
              rawMessages.isEmpty ? null : rawMessages.last.createdAt;
        }
        _hasEarlier = query == null && res['has_more'] == true;
        _historyMode = false;
        _loading = false;
      });
      unawaited(_refreshMessageStatuses());
      if (query == null) {
        _persistMessages(replace: true);
        _scrollToBottom();
        _markChatRead();
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      if (e is ApiException && [403, 404].contains(e.statusCode)) {
        _showChatUnavailable();
        return;
      }
      if (_messages.isNotEmpty) {
        // Offline (or a transient failure) with history already on screen:
        // keep the cached conversation readable instead of replacing it
        // with an internet-error screen. Polling keeps retrying quietly.
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _mergeMessages(Iterable<MessageModel> messages) {
    for (final message in _reconciler.reconcile(messages)) {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index == -1) {
        _messages.add(message);
      } else {
        final previous = _messages[index];
        _messages[index] = message.copyWith(
          status: MessageReconciler.newestStatus(
            previous.status,
            message.status,
          ),
          viewedAt: previous.viewedAt ?? message.viewedAt,
          viewExpiresAt: previous.viewExpiresAt ?? message.viewExpiresAt,
        );
      }
    }
    _messages.sort((a, b) {
      final order = a.createdAt.compareTo(b.createdAt);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    // Only history/new-message polls advance the server cursor. A send or
    // an older page must not skip remote messages still waiting to be polled.
    _persistMessages();
  }

  Future<void> _loadEarlier() async {
    if (_loadingEarlier || _messages.isEmpty || !_hasEarlier) return;
    final generation = _loadGeneration;
    setState(() => _loadingEarlier = true);
    final oldExtent = _scrollCtrl.hasClients
        ? _scrollCtrl.position.maxScrollExtent
        : 0.0;
    final oldOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
    try {
      final res = await _api.get(
        '/messages/${widget.chatId}',
        query: {'before_id': _messages.first.id},
      );
      if (!mounted || generation != _loadGeneration) return;
      final list = (res['messages'] as List? ?? []).map(
        (e) => MessageModel.fromJson(e as Map<String, dynamic>),
      );
      setState(() {
        _mergeMessages(list);
        _hasEarlier = res['has_more'] == true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_scrollCtrl.hasClients ||
            generation != _loadGeneration)
          return;
        final offset =
            oldOffset + _scrollCtrl.position.maxScrollExtent - oldExtent;
        _scrollCtrl.jumpTo(
          offset.clamp(0.0, _scrollCtrl.position.maxScrollExtent).toDouble(),
        );
      });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _loadingEarlier = false);
    }
  }

  ReplyPreviewModel? _replyPreviewFor(MessageModel message) {
    if (message.replyTo != null) return message.replyTo;
    final id = message.replyToId;
    if (id == null) return null;
    return _messages.firstWhereOrNull((m) => m.id == id)?.asReplyPreview ??
        ReplyPreviewModel.unavailable(id);
  }

  Future<void> _jumpToReply(String id) async {
    if (_jumpingToReply || _reconciler.isUnavailable(id)) return;
    _jumpingToReply = true;
    try {
      var target = _messageKeys[id]?.currentContext;
      if (target == null) {
        final generation = ++_loadGeneration;
        // Start the history window at the original, so it can be reached even
        // outside the lazy list's built items without an estimated pixel jump.
        final res = await _api.get(
          '/messages/${widget.chatId}',
          query: {'from_id': id},
        );
        if (!mounted || generation != _loadGeneration) return;
        final list = (res['messages'] as List? ?? [])
            .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
            .toList();
        if (list.isEmpty || list.first.id != id)
          throw StateError('Message unavailable');
        await _playback.pause();
        if (!mounted) return;
        setState(() {
          _messages
            ..clear()
            ..addAll(_reconciler.reconcile(list));
          _historyMode = true;
          _searchMode = false;
          _hasEarlier = true;
          _loading = false;
          _error = null;
        });
        if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        target = _messageKeys[id]?.currentContext;
      }
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.25,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      if (!mounted) return;
      _highlightTimer?.cancel();
      setState(() => _highlightedMessageId = id);
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _highlightedMessageId = null);
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(MediaLabels.of(context).unavailable)),
        );
    } finally {
      _jumpingToReply = false;
    }
  }

  /// The pinned bar is chat state, not message state: it must survive
  /// scrolling, search and history mode, so it is loaded separately.
  Future<void> _loadPinned() async {
    if (!mounted || _loadingPinned || _chatUnavailable) return;
    _loadingPinned = true;
    try {
      final res = await _api.get('/messages/chat/${widget.chatId}/pinned');
      if (!mounted) return;
      final list = (res['messages'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(MessageModel.fromJson)
          .where((m) => !_reconciler.isUnavailable(m.id))
          .toList();
      final canPin = res['can_pin'] == true;
      if (const ListEquality<MessageModel>().equals(_pinned, list) &&
          canPin == _canPinMessages) {
        return;
      }
      setState(() {
        _pinned
          ..clear()
          ..addAll(list);
        _canPinMessages = canPin;
        if (_pinnedIndex >= _pinned.length) _pinnedIndex = 0;
      });
      final userId = _sessionUserId;
      if (userId != null) {
        unawaited(
          OfflineCacheService.instance.saveChatMeta(
            userId,
            widget.chatId,
            'pinned',
            {
              'messages': (res['messages'] as List? ?? [])
                  .whereType<Map<String, dynamic>>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList(),
              'can_pin': canPin,
            },
          ),
        );
      }
    } catch (_) {
      // The bar simply stays as it is; the next poll retries.
    } finally {
      _loadingPinned = false;
    }
  }

  Future<void> _togglePin(MessageModel msg, bool pin) async {
    try {
      await _api.post('/messages/${msg.id}/${pin ? 'pin' : 'unpin'}', {});
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m.id == msg.id);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(isPinned: pin);
        }
        if (!pin) {
          _pinned.removeWhere((m) => m.id == msg.id);
          if (_pinnedIndex >= _pinned.length) _pinnedIndex = 0;
        }
      });
      await _loadPinned();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _unpinAll() async {
    try {
      await _api.post('/messages/chat/${widget.chatId}/unpin-all', {});
      if (!mounted) return;
      setState(() {
        _pinned.clear();
        _pinnedIndex = 0;
      });
      await _loadPinned();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openPinnedMessages() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => PinnedMessagesScreen(
          pinned: List<MessageModel>.from(_pinned),
          canPin: _canPinMessages,
          onUnpin: (message) => unawaited(_togglePin(message, false)),
          onUnpinAll: _unpinAll,
        ),
      ),
    );
    if (!mounted || id == null) return;
    await _jumpToReply(id);
  }

  void _tapPinnedBar() {
    if (_pinned.isEmpty) return;
    final index = _pinnedIndex < _pinned.length ? _pinnedIndex : 0;
    final message = _pinned[index];
    setState(() => _pinnedIndex = (index + 1) % _pinned.length);
    unawaited(_jumpToReply(message.id));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: ApiConstants.pollingIntervalSeconds),
      (_) => _pollNow(),
    );
  }

  void _pollNow() {
    if (!mounted || !_foreground || _chatUnavailable) return;
    if (_loading) return;
    if (!_searchMode && !_historyMode) unawaited(_pollNewMessages());

    // Message arrival stays on the fast 3-second cadence. Chat metadata,
    // pins and delivery/read status can be reconciled less frequently; doing
    // all four reads on every tick multiplied server work for every open chat.
    final now = DateTime.now();
    final lastAuxiliaryPoll = _lastAuxiliaryPollAt;
    if (lastAuxiliaryPoll == null ||
        now.difference(lastAuxiliaryPoll).inSeconds >=
            ApiConstants.auxiliaryChatPollingIntervalSeconds) {
      _lastAuxiliaryPollAt = now;
      unawaited(_loadChatInfo());
      unawaited(_loadPinned());
      // Reconcile every loaded page, including in search/history mode.
      unawaited(_refreshMessageStatuses());
    }
  }

  void _applyMessageUpdate(MessageSyncResult update) {
    if (!mounted) return;
    final updated = _reconciler.reconcile(_messages, update: update);
    final clearReply =
        _replyTo != null && _reconciler.isUnavailable(_replyTo!.id);
    if (const ListEquality<MessageModel>().equals(_messages, updated) &&
        !clearReply)
      return;
    final removedMedia = _messages.any(
      (m) => update.deletedIds.contains(m.id) && m.mediaId != null,
    );
    if (removedMedia) unawaited(_playback.pause());
    setState(() {
      _messages
        ..clear()
        ..addAll(updated);
      _messageKeys.removeWhere((id, _) => _reconciler.isUnavailable(id));
      if (clearReply) _replyTo = null;
      if (_highlightedMessageId != null &&
          _reconciler.isUnavailable(_highlightedMessageId!)) {
        _highlightedMessageId = null;
      }
    });
    _persistMessages(replace: true);
    // Close only the deleted photo's route, never an unrelated dialog/chat.
    final photoRoute = _photoRoute;
    if (photoRoute != null &&
        photoRoute.isActive &&
        _photoMessageId != null &&
        update.deletedIds.contains(_photoMessageId)) {
      photoRoute.navigator?.removeRoute(photoRoute);
    }
    if (update.deletedIds.isNotEmpty) {
      unawaited(ref.read(chatListProvider.notifier).refresh());
    }
    final pinnedIds = update.pinnedIds;
    if (pinnedIds != null &&
        !const SetEquality<String>().equals(
          pinnedIds.toSet(),
          _pinned.map((m) => m.id).toSet(),
        )) {
      unawaited(_loadPinned());
    }
  }

  Future<void> _refreshMessageStatuses() async {
    if (!mounted || _refreshingStatuses || _chatUnavailable || !_foreground)
      return;
    final generation = _loadGeneration;
    final batches = _reconciler.batches(
      _messages.reversed,
      selectedReply: _replyTo,
    );
    if (batches.isEmpty) return;
    _refreshingStatuses = true;
    try {
      // Do not truncate at 100: users can have many earlier pages loaded.
      for (final ids in batches) {
        final res = await _api.post('/messages/statuses', {
          'chat_id': widget.chatId,
          'message_ids': ids,
        });
        if (!mounted || generation != _loadGeneration || !_foreground) return;
        _applyMessageUpdate(MessageSyncResult.fromJson(res));
      }
    } on ApiException catch (error) {
      if ([403, 404].contains(error.statusCode)) _showChatUnavailable();
    } catch (_) {
      // Every batch is reconciled again next cycle; missed polls lose no state.
    } finally {
      _refreshingStatuses = false;
    }
  }

  Future<void> _pollNewMessages() async {
    if (!mounted || _polling || _loading || _historyMode) return;
    _polling = true;
    final generation = _loadGeneration;
    try {
      final query = <String, String>{};
      if (_lastMessageId != null) {
        query['after_id'] = _lastMessageId!;
        final since = _lastMessageAt;
        if (since != null) {
          query['after_since'] = since.toUtc().toIso8601String();
        }
      }
      final res = await _api.get('/messages/${widget.chatId}', query: query);
      if (!mounted ||
          _searchMode ||
          _historyMode ||
          generation != _loadGeneration)
        return;
      final list = (res['messages'] as List? ?? [])
          .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
          .toList();
      // The server dropped our cursor (the message it pointed at is gone).
      // Re-seed from what it just sent so the next poll is healthy again.
      final cursorReset = res['cursor_reset'] == true;
      if (list.isNotEmpty) {
        final hasIncoming = list.any(
          (m) =>
              m.senderId != null &&
              m.senderId != _currentUserId &&
              m.senderId != _sessionUserId,
        );
        if (hasIncoming) {
          unawaited(SoundService().playMessageReceived());
        }
        _lastMessageId = list.last.id;
        _lastMessageAt = list.last.createdAt;
        final atBottom =
            !_scrollCtrl.hasClients ||
            _scrollCtrl.position.maxScrollExtent - _scrollCtrl.offset < 160;
        setState(() => _mergeMessages(list));
        if (atBottom) _scrollToBottom();
        _markChatRead();
      } else if (cursorReset) {
        // Nothing to show, but the cursor is dead: clear it so the next poll
        // asks for the newest page instead of repeating a doomed request.
        _lastMessageId = null;
        _lastMessageAt = null;
      }
    } catch (error) {
      // A cursor the server refuses (404) must not wedge polling forever.
      if (error is ApiException && error.statusCode == 404) {
        _lastMessageId = null;
        _lastMessageAt = null;
      }
    } finally {
      _polling = false;
    }
  }

  MessageModel _sentMessage(Map<String, dynamic> payload, MessageModel? reply) {
    final message = MessageModel.fromJson({
      'reply_to_id': reply?.id,
      ...payload,
    });
    // Trust the current server's privacy-filtered snapshot. Only older servers
    // with abbreviated send responses need the locally selected quote fallback.
    return message.replyTo != null || reply == null
        ? message
        : message.copyWith(replyTo: reply.asReplyPreview);
  }

  void _startSlowModeTimer(int seconds) {
    _slowModeTimer?.cancel();
    setState(() => _slowModeRemaining = seconds);
    _slowModeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_slowModeRemaining <= 1) {
        timer.cancel();
        setState(() => _slowModeRemaining = 0);
      } else {
        setState(() => _slowModeRemaining--);
      }
    });
  }

  void _handleSlowModeError(String message) {
    final match = RegExp(r'(\d+)').firstMatch(message);
    final secs = match != null ? int.tryParse(match.group(1)!) ?? _slowModeDelay : _slowModeDelay;
    _startSlowModeTimer(secs > 0 ? secs : 10);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _sendText({DateTime? scheduledAt}) async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending || !_can('send_messages')) return;
    if (_slowModeRemaining > 0 && (_myRole != 'owner' && _myRole != 'admin')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_label('Please wait $_slowModeRemaining more seconds before sending a message.', 'لطفاً $_slowModeRemaining ثانیه دیگر برای ارسال پیام صبر کنید.'))),
      );
      return;
    }
    final reply = _replyTo;
    final sendSpoiler = _isSpoiler;
    setState(() => _sending = true);
    try {
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'content': text,
        'message_type': 'text',
        'is_spoiler': sendSpoiler,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      if (scheduledAt != null) {
        // Iran time fix: Flutter DateTime is local (e.g. Asia/Tehran +03:30).
        // toUtc().toIso8601String() sends UTC with 'Z', so backend stores correct UTC
        // and displays it back in local time via parseApiDateTime(...).toLocal().
        body['scheduled_at'] = scheduledAt.toUtc().toIso8601String();
      }
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      if (res['is_scheduled'] == true) {
        setState(() {
          _textCtrl.clear();
          _replyTo = null;
          _isSpoiler = false;
          _sending = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_label('Message scheduled.', 'پیام زمان‌بندی شد.'))),
        );
        return;
      }
      final msg = _sentMessage(res, reply);
      setState(() {
        _mergeMessages([msg]);
        _textCtrl.clear();
        _replyTo = null;
        _isSpoiler = false;
        _sending = false;
      });
      unawaited(SoundService().playMessageSent());
      if (_slowModeDelay > 0 && (_myRole != 'owner' && _myRole != 'admin')) {
        _startSlowModeTimer(_slowModeDelay);
      }
      if (_historyMode) await _loadMessages();
      if (!mounted) return;
      _scrollToBottom();
      ref.read(chatListProvider.notifier).refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      if (e.statusCode == 429) {
        _handleSlowModeError(e.message);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _scheduleMessage() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_label('Enter a message first.', 'ابتدا متن پیام را وارد کنید'))),
      );
      return;
    }
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(minutes: 5)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10))),
    );
    if (pickedTime == null || !mounted) return;

    final scheduledDateTime = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    if (scheduledDateTime.isBefore(DateTime.now().add(const Duration(seconds: 30)))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_label('Choose a time in the future.', 'زمان انتخاب‌شده باید در آینده باشد'))),
      );
      return;
    }

    _sendText(scheduledAt: scheduledDateTime);
  }

  void _openScheduledSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ScheduledMessagesSheet(
        chatId: widget.chatId,
        api: _api,
      ),
    );
  }

  // --- parallel uploads -------------------------------------------------
  String _beginUpload(String type, String? name) =>
      UploadQueue.instance.register(
        chatId: widget.chatId,
        mediaType: type,
        fileName: name,
      );

  void _setUploadProgress(String id, double progress) =>
      UploadQueue.instance.updateProgress(id, progress);

  void _endUpload(String id) => UploadQueue.instance.complete(id);

  /// Upload a file and immediately keep a local copy (Item 5).
  ///
  /// The sender's device always retains what it sent, so the content survives
  /// a total loss of server data and can still be viewed, saved, resent or
  /// forwarded from the chat history.
  ///
  /// Uploads run through [UploadQueue]: several files fly in parallel, the
  /// admin's size limits are checked locally first (no wasted bandwidth on a
  /// file the server would only reject at the end), and progress is reported
  /// per upload so each banner above the composer tracks its own file.
  Future<Map<String, dynamic>> _uploadAndCache(
    File file, {
    Map<String, String>? fields,
    String? fileName,
    String? category,
    String? uploadId,
    bool cacheSource = true,
  }) async {
    if (category != null) {
      final size = await file.length();
      final blocked = MediaLimitsService.instance.check(
        category: category,
        sizeBytes: size,
      );
      if (blocked != null) throw blocked;
    }
    final cancellationToken = uploadId == null
        ? null
        : UploadQueue.instance.tokenFor(uploadId);
    final Map<String, dynamic> upload;
    try {
      upload = await UploadQueue.instance.run(
        () => _api.uploadFile(
          '/media/upload',
          file,
          fields: fields,
          onProgress: (p) {
            if (uploadId != null) _setUploadProgress(uploadId, p);
          },
          cancellationToken: cancellationToken,
        ),
        cancellationToken: cancellationToken,
      );
    } on ApiException catch (e) {
      // The admin may have changed a limit a moment ago; refetch so the
      // next attempt is judged against the current policy.
      if (e.statusCode == 403 || e.statusCode == 413) {
        MediaLimitsService.instance.invalidate();
      }
      rethrow;
    }
    cancellationToken?.throwIfCancelled();
    if (uploadId != null) UploadQueue.instance.markFinalizing(uploadId);
    final mediaId = upload['id'] as String?;
    if (cacheSource && mediaId != null && mediaId.isNotEmpty) {
      unawaited(
        MediaCacheService.instance.storeOutgoing(
          mediaId: mediaId,
          source: file,
          fileName: fileName ?? upload['original_name'] as String?,
          chatId: widget.chatId,
          mediaType: upload['media_type'] as String?,
        ),
      );
    }
    return upload;
  }

  Future<void> _pickAndSendFile() async {
    if (!_can('send_files')) return;
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || !mounted) return;
    final reply = _replyTo;
    final sendSpoiler = _isSpoiler;
    var first = true;
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null) continue;
      unawaited(
        _sendFile(
          File(path),
          fileName: picked.name,
          reply: first ? reply : null,
          sendSpoiler: sendSpoiler,
        ),
      );
      first = false;
    }
  }

  /// Sends one picked file. Runs independently of any other upload, so the
  /// user can keep picking and sending while previous files still fly.
  Future<void> _sendFile(
    File file, {
    required String fileName,
    MessageModel? reply,
    bool sendSpoiler = false,
  }) async {
    final uploadId = _beginUpload('file', fileName);
    try {
      final upload = await _uploadAndCache(
        file,
        fileName: fileName,
        category: MediaLimitsService.categoryFor(
          messageType: 'file',
          fileName: fileName,
        ),
        uploadId: uploadId,
      );
      final mediaId = upload['id'] as String;
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'file',
        'media_id': mediaId,
        'content': fileName,
        'is_spoiler': sendSpoiler,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({
        ...res,
        'media_id': mediaId,
        'media_url': '/api/v1/media/$mediaId',
        'message_type': 'file',
        'original_name': fileName,
        'is_spoiler': sendSpoiler,
      }, reply);
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
        _isSpoiler = false;
      });
      unawaited(SoundService().playMessageSent());
      if (_slowModeDelay > 0 && (_myRole != 'owner' && _myRole != 'admin')) {
        _startSlowModeTimer(_slowModeDelay);
      }
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 429) {
        _handleSlowModeError(e.message);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } catch (e) {
      if (!mounted || e is UploadCancelledException) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      _endUpload(uploadId);
    }
  }

  /// Direct photo send used when several photos are picked at once. There
  /// is no per-photo editor or send-option sheet (Telegram behaves the same
  /// way for multi-picks); each photo uploads independently and lands as
  /// its own message.
  Future<void> _sendPhotoFile(
    File file, {
    MessageModel? reply,
    bool sendSpoiler = false,
  }) async {
    final uploadId = _beginUpload('image', null);
    try {
      final upload = await _uploadAndCache(
        file,
        category: 'image',
        uploadId: uploadId,
      );
      final mediaId = upload['id'] as String;
      final mediaType = upload['media_type'] as String? ?? 'image';
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': mediaType,
        'media_id': mediaId,
        'content': '',
        'is_spoiler': sendSpoiler,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({
        ...res,
        'media_id': mediaId,
        'media_url': '/api/v1/media/$mediaId',
        'message_type': mediaType,
        'is_spoiler': sendSpoiler,
      }, reply);
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
        _isSpoiler = false;
      });
      unawaited(SoundService().playMessageSent());
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (!mounted || e is UploadCancelledException) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      _endUpload(uploadId);
    }
  }

  Future<void> _pickAndSendMedia(
    ImageSource source, {
    bool isVideo = false,
    bool viewOnce = false,
  }) async {
    if (!_can(isVideo ? 'send_videos' : 'send_photos')) return;
    final picker = ImagePicker();
    final XFile? picked;
    if (!isVideo && source == ImageSource.gallery) {
      final pickedList = await picker.pickMultiImage(
        maxWidth: 4096,
        imageQuality: 95,
      );
      if (pickedList.isEmpty || !mounted) return;
      if (pickedList.length > 1) {
        // Several photos at once: each uploads and lands independently;
        // the composer never locks while they fly.
        final reply = _replyTo;
        final sendSpoiler = _isSpoiler;
        var first = true;
        for (final item in pickedList) {
          unawaited(
            _sendPhotoFile(
              File(item.path),
              reply: first ? reply : null,
              sendSpoiler: sendSpoiler,
            ),
          );
          first = false;
        }
        return;
      }
      picked = pickedList.first;
    } else {
      picked = isVideo
          ? await picker.pickVideo(source: source)
          : await picker.pickImage(
              source: source,
              maxWidth: 4096,
              imageQuality: 95,
            );
    }
    if (picked == null || !mounted) return;

    // Internal editor (Telegram-like): crop/draw/text for photos,
    // crop/trim/mute for videos. Back = cancel the send.
    File sendFile = File(picked.path);
    bool videoMuted = false;
    Map<String, String>? trimFields;
    if (!isVideo) {
      final edited = await Navigator.of(context).push<File>(
        MaterialPageRoute(builder: (_) => PhotoEditorScreen(imageFile: sendFile)),
      );
      if (edited == null || !mounted) return;
      sendFile = edited;
    } else {
      final edited = await Navigator.of(context).push<EditedVideo>(
        MaterialPageRoute(builder: (_) => VideoEditorScreen(videoFile: sendFile)),
      );
      if (edited == null || !mounted) return;
      sendFile = edited.file;
      videoMuted = edited.muted;
      final editFields = <String, String>{};
      if (edited.isTrimmed) {
        editFields.addAll({
          'trim_start_ms': edited.startMs.toString(),
          'trim_end_ms': edited.endMs.toString(),
        });
      }
      if (edited.isCropped) {
        editFields.addAll({
          'crop_x': edited.cropX!.toStringAsFixed(6),
          'crop_y': edited.cropY!.toStringAsFixed(6),
          'crop_width': edited.cropWidth!.toStringAsFixed(6),
          'crop_height': edited.cropHeight!.toStringAsFixed(6),
        });
      }
      if (editFields.isNotEmpty) trimFields = editFields;
    }

    bool sendViewOnce = viewOnce;
    int? sendViewDuration;
    bool sendSpoiler = _isSpoiler;
    if (!isVideo) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12, bottom: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
              ListTile(
                leading: const Icon(Icons.send),
                title: Text(_label('Send as photo', 'ارسال معمولی')),
                onTap: () => Navigator.pop(ctx, 'normal'),
              ),
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined, color: Colors.purple),
                title: Text(_label('Send as spoiler', 'ارسال عکس با اسپویلر (مخفی)')),
                onTap: () => Navigator.pop(ctx, 'spoiler'),
              ),
              if (_can('send_view_once_photos'))
                ListTile(
                  leading: const Icon(Icons.timer, color: Colors.orange),
                  title: Text(MediaLabels.of(ctx).viewOnce),
                  subtitle: Text(MediaLabels.of(ctx).disappears),
                  onTap: () => Navigator.pop(ctx, 'once'),
                ),
              if (_can('send_view_once_photos'))
                ListTile(
                  leading: const Icon(
                    Icons.timer_10_outlined,
                    color: Colors.deepOrange,
                  ),
                  title: Text(_label('Send as timed photo (10 seconds)', 'ارسال عکس زمان‌دار (۱۰ ثانیه)')),
                  subtitle: Text(
                    _label('Like view-once, but closes 10 seconds after it is opened.', 'مثل «یک‌بارمشاهده»، ولی ۱۰ ثانیه بعد از باز شدن بسته می‌شود'),
                  ),
                  onTap: () => Navigator.pop(ctx, 'timed'),
                ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(_label('Cancel', 'لغو')),
                onTap: () => Navigator.pop(ctx, 'cancel'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == null || choice == 'cancel' || !mounted) return;
      if (choice == 'spoiler') sendSpoiler = true;
      if (choice == 'once') sendViewOnce = true;
      if (choice == 'timed') {
        sendViewOnce = true;
        sendViewDuration = 10;
      }
    } else {
      if (!sendSpoiler) {
        final choice = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12, bottom: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                ListTile(
                  leading: const Icon(Icons.send),
                  title: Text(_label('Send as video', 'ارسال معمولی')) ,
                  onTap: () => Navigator.pop(ctx, 'normal'),
                ),
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined, color: Colors.purple),
                  title: Text(_label('Send as spoiler', 'ارسال ویدیو با اسپویلر (مخفی)')),
                  onTap: () => Navigator.pop(ctx, 'spoiler'),
                ),
                ListTile(
                  leading: const Icon(Icons.close),
                  title: Text(_label('Cancel', 'لغو')) ,
                  onTap: () => Navigator.pop(ctx, 'cancel'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        if (choice == null || choice == 'cancel' || !mounted) return;
        if (choice == 'spoiler') sendSpoiler = true;
      }
    }

    final reply = _replyTo;
    final uploadId = _beginUpload(isVideo ? 'video' : 'image', null);
    try {
      final upload = await _uploadAndCache(
        sendFile,
        fields: trimFields,
        category: isVideo ? 'video' : 'image',
        uploadId: uploadId,
        cacheSource: !(trimFields?.containsKey('crop_width') ?? false),
      );
      final mediaId = upload['id'] as String;
      final mediaType =
          upload['media_type'] as String? ?? (isVideo ? 'video' : 'image');
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': mediaType,
        'media_id': mediaId,
        'content': '',
        'is_view_once': sendViewOnce,
        'is_spoiler': sendSpoiler,
        if (sendViewDuration != null && !isVideo)
          'view_duration': sendViewDuration,
        if (isVideo && videoMuted) 'is_muted': true,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({
        ...res,
        'media_id': mediaId,
        'media_url': sendViewOnce ? null : '/api/v1/media/$mediaId',
        'message_type': mediaType,
        'is_view_once': sendViewOnce,
        'is_spoiler': sendSpoiler,
        if (sendViewDuration != null && !isVideo)
          'view_duration': sendViewDuration,
        if (isVideo && videoMuted) 'is_muted': true,
      }, reply);
      if (isVideo && !sendViewOnce &&
          (trimFields?.containsKey('crop_width') ?? false)) {
        // Cache the server-rendered crop rather than the unmodified source.
        unawaited(MediaCacheService.instance.bytesFor(
          mediaId: mediaId,
          remoteUrl: '/api/v1/media/$mediaId',
          fileName: '$mediaId.mp4',
          chatId: widget.chatId,
          messageId: msg.id,
          mediaType: 'video',
        ));
      }
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
        _isSpoiler = false;
      });
      unawaited(SoundService().playMessageSent());
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (!mounted || e is UploadCancelledException) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      _endUpload(uploadId);
    }
  }

  Future<void> _toggleVoiceRecord() async {
    if (!_isRecording && !_can('send_voice')) return;
    if (_isRecording) {
      final file = await _voice.stopRecording();
      if (!mounted) return;
      setState(() => _isRecording = false);
      if (file == null) return;
      if (!_can('send_voice')) {
        await _voice.cancelRecording();
        return;
      }
      final reply = _replyTo;
      final uploadId = _beginUpload('voice', null);
      try {
        final upload = await _uploadAndCache(
          file,
          fields: const {'media_kind': 'voice'},
          category: 'voice',
          uploadId: uploadId,
        );
        final mediaId = upload['id'] as String;
        final body = <String, dynamic>{
          'chat_id': widget.chatId,
          'message_type': 'voice',
          'media_id': mediaId,
          'content': '',
        };
        if (reply != null) body['reply_to_id'] = reply.id;
        final res = await _api.post('/messages/', body);
        if (!mounted) return;
        final msg = _sentMessage({
          ...res,
          'media_id': mediaId,
          'media_url': '/api/v1/media/$mediaId',
          'message_type': 'voice',
        }, reply);
        setState(() {
          _mergeMessages([msg]);
          if (_replyTo?.id == reply?.id) _replyTo = null;
        });
        unawaited(SoundService().playMessageSent());
        if (_historyMode) await _loadMessages();
        _scrollToBottom();
        if (mounted) ref.read(chatListProvider.notifier).refresh();
      } catch (e) {
        if (!mounted || e is UploadCancelledException) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      } finally {
        _endUpload(uploadId);
      }
    } else {
      await _playback.pause();
      final ok = await _voice.startRecording();
      if (!mounted) return;
      if (ok && !_can('send_voice')) {
        await _voice.cancelRecording();
        return;
      }
      if (ok) {
        setState(() => _isRecording = true);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_label('Microphone access is required.', 'دسترسی میکروفون لازم است'))),
        );
      }
    }
  }

  Future<void> _cancelVoiceRecord() async {
    await _voice.cancelRecording();
    if (!mounted) return;
    setState(() => _isRecording = false);
  }

  // --- Telegram-like reactions ---
  Future<void> _toggleReaction(MessageModel msg, String emoji) async {
    try {
      unawaited(SoundService().playReaction());
      await _api.post('/reactions/${msg.id}/reaction', {'emoji': emoji});
      // Local optimistic toggle: update reactions list immediately, then refresh from server
      // For simplicity, trigger a status refresh which will pull reactions via payloads
      unawaited(_refreshMessageStatuses());
      // Also poll messages to get updated reactions quickly
      final res = await _api.get('/messages/${widget.chatId}', query: {'from_id': msg.id});
      if (!mounted) return;
      final list = (res['messages'] as List? ?? []).map((e) => MessageModel.fromJson(e as Map<String, dynamic>)).toList();
      if (list.isNotEmpty) {
        setState(() {
          for (final updated in list) {
            final idx = _messages.indexWhere((m) => m.id == updated.id);
            if (idx != -1) _messages[idx] = updated;
          }
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _showReactionPicker(MessageModel msg) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => const QuickReactionSheet(),
    );
    if (emoji != null && mounted) await _toggleReaction(msg, emoji);
  }

  // --- Telegram-like stickers ---
  Future<void> _showStickerPicker() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StickerPicker(
        api: _api,
        onStickerSelected: (sticker) async {
          Navigator.pop(ctx);
          await _sendSticker(sticker);
        },
      ),
    );
  }

  Future<void> _sendSticker(dynamic sticker) async {
    if (_sending || !_can('send_messages')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label('Stickers cannot be sent in this chat.', 'امکان ارسال استیکر در این چت وجود ندارد'))));
      return;
    }
    final reply = _replyTo;
    setState(() => _sending = true);
    try {
      // sticker is StickerModel or map with id/media
      final stickerId = sticker is Map ? sticker['id'] : sticker.id;
      final emoji = sticker is Map ? sticker['emoji'] : sticker.emoji;
      // If sticker has media_id, use it; else send content emoji
      String? mediaId;
      if (sticker is Map && sticker['media_id'] != null) mediaId = sticker['media_id'] as String;
      else if (sticker is! Map && sticker.mediaId != null) mediaId = sticker.mediaId;
      else if (sticker is! Map && sticker.fileUrl != null) {
        // For seeded packs we may have url only - send as sticker via content fallback
      }
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'sticker',
        'content': emoji ?? '🙂',
      };
      if (mediaId != null) body['media_id'] = mediaId;
      // If no mediaId but fileUrl exists, we send without media and server will fallback to display emoji
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage(res, reply);
      setState(() {
        _mergeMessages([msg]);
        _replyTo = null;
        _sending = false;
      });
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  // --- Telegram-like GIFs ---
  Future<void> _showGifPicker() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GifPicker(
        api: _api,
        onGifSelected: (gif) async {
          Navigator.pop(ctx);
          await _sendGif(gif);
        },
      ),
    );
  }

  Future<void> _sendGif(dynamic gif) async {
    if (_sending || !_can('send_messages')) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label('GIFs cannot be sent here.', 'امکان ارسال گیف وجود ندارد'))));
      return;
    }
    final reply = _replyTo;
    setState(() => _sending = true);
    try {
      // gif is SavedGif (has mediaId or gif_url) – online GIFs are no longer offered.
      String? mediaId;
      String? gifUrl;
      String? title;
      if (gif is Map) {
        mediaId = gif['media_id'] as String?;
        gifUrl = gif['gif_url'] as String? ?? gif['url'] as String?;
        title = gif['title'] as String?;
      } else {
        // GifModel
        try { mediaId = (gif as dynamic).mediaId as String?; } catch (_) {}
        try { gifUrl = (gif as dynamic).gifUrl as String?; } catch (_) {}
        try { title = (gif as dynamic).title as String?; } catch (_) {}
        try { gifUrl ??= (gif as dynamic).previewUrl as String?; } catch (_) {}
      }
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'gif',
        'content': (title?.isNotEmpty == true ? title : null) ?? gifUrl ?? 'GIF',
      };
      if (mediaId != null && mediaId.isNotEmpty) {
        body['media_id'] = mediaId;
      } else if (gifUrl != null && gifUrl.isNotEmpty) {
        // fallback: send URL as content; backend will still create gif message
        body['content'] = gifUrl;
      } else {
        throw Exception(_label('The selected GIF is missing required information.', 'گیف انتخاب‌شده فاقد اطلاعات است'));
      }
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({
        ...res,
        // Hydrate media_url for local preview when backend omits it but we have the external URL
        if ((res['media_url'] == null || (res['media_url'] as String).isEmpty) && gifUrl != null && !gifUrl.startsWith('/')) 'media_url': gifUrl,
        if (res['media_id'] == null && mediaId != null) 'media_id': mediaId,
      }, reply);
      setState(() {
        _mergeMessages([msg]);
        _replyTo = null;
        _sending = false;
      });
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted && _sending) setState(() => _sending = false);
    }
  }

  Future<void> _makeGifFromVideo() async {
    final picker = ImagePicker();
    final video = await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
    if (video == null || !mounted) return;
    final uploadId = _beginUpload('video', null);
    try {
      final upload = await _uploadAndCache(
        File(video.path),
        category: 'video',
        uploadId: uploadId,
      );
      final mediaId = upload['id'] as String?;
      if (mediaId == null || mediaId.isEmpty) throw Exception(_label('Video upload failed.', 'آپلود ویدیو ناموفق بود'));
      // /gifs/make returns {ok:true, media_id, gif_url} – not {gif:{}}
      Map<String, dynamic> res;
      try {
        res = await _api.post('/gifs/make', {'media_id': mediaId, 'title': 'Converted GIF'});
      } catch (_) {
        // If make endpoint fails, fall back to sending video as gif directly
        res = {'media_id': mediaId, 'gif_url': '/api/v1/media/$mediaId'};
      }
      final outMediaId = (res['media_id'] as String?) ?? mediaId;
      final gifUrl = res['gif_url'] as String? ?? res['url'] as String? ?? '/api/v1/media/$outMediaId';
      final gifMap = res['gif'] as Map<String, dynamic>?;
      if (gifMap != null) {
        await _sendGif(gifMap);
        return;
      }
      // Fallback: optionally save to saved GIFs for future reuse (best-effort)
      try {
        await _api.post('/gifs/save', {'media_id': outMediaId, 'gif_url': gifUrl, 'preview_url': gifUrl, 'title': _label('GIF from video', 'GIF از ویدیو')});
      } catch (_) {}
      // Direct send as gif message (most reliable, avoids double-save crash)
      final reply = _replyTo;
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'gif',
        'media_id': outMediaId,
        'content': 'GIF',
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final msgRes = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({...msgRes, 'media_id': outMediaId, 'media_url': '/api/v1/media/$outMediaId', 'message_type': 'gif'}, reply);
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
      });
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted && e is! UploadCancelledException) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label('Could not create GIF: $e', 'ساخت گیف ناموفق: $e'))));
      }
    } finally {
      _endUpload(uploadId);
    }
  }

  // --- Telegram-like round video messages (video_note) ---
  Future<void> _recordVideoNote() async {
    if (!_can('send_messages')) return;
    // Telegram round videos are portrait, max 60s, circular. We reuse gallery/camera video picker and send as video_note.
    final picker = ImagePicker();
    final XFile? video = await picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(seconds: 60));
    if (video == null || !mounted) return;
    final file = File(video.path);
    final reply = _replyTo;
    final uploadId = _beginUpload('video_note', null);
    try {
      final upload = await _uploadAndCache(
        file,
        category: 'video',
        uploadId: uploadId,
      );
      final mediaId = upload['id'] as String;
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'video_note',
        'media_id': mediaId,
        'content': '',
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({...res, 'media_id': mediaId, 'media_url': '/api/v1/media/$mediaId', 'message_type': 'video_note'}, reply);
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
      });
      unawaited(SoundService().playMessageSent());
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted && e is! UploadCancelledException) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      _endUpload(uploadId);
    }
  }

  Future<void> _reportCurrentChat() async {
    final targetType = _chatType == 'private' ? 'user' : 'chat';
    final targetUserId = _chatType == 'private' ? _otherUser?.id : null;
    await showDialog(
      context: context,
      builder: (_) => ReportDialog(
        api: _api,
        targetType: targetType == 'user' ? 'user' : 'group',
        targetUserId: targetUserId,
        targetChatId: widget.chatId,
        title: _displayTitle,
      ),
    );
  }

  Future<void> _reportMessage(MessageModel msg) async {
    await showDialog(
      context: context,
      builder: (_) => ReportDialog(
        api: _api,
        targetType: 'message',
        targetMessageId: msg.id,
        targetChatId: widget.chatId,
        title: _label('Message', 'پیام'),
      ),
    );
  }

  Future<void> _deleteMessage(MessageModel msg, {required bool forAll}) async {
    try {
      await _api.post('/messages/${msg.id}/delete', {'for_all': forAll});
      if (!mounted) return;
      _applyMessageUpdate(MessageSyncResult(deletedIds: {msg.id}));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _clearHistory({required bool forAll}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(forAll ? _label('Delete for everyone', 'حذف برای همه') : _label('Delete for me', 'حذف فقط برای من')) ,
        content: Text(
          forAll
              ? _label('Messages will be deleted for everyone.', 'پیام‌ها برای همه حذف می‌شوند.')
              : _label('Only your chat history will be cleared.', 'تاریخچه فقط برای شما پاک می‌شود.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_label('Cancel', 'لغو')) ,
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_label('Confirm', 'تایید')) ,
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _api.post('/messages/chat/${widget.chatId}/clear', {
        'for_all': forAll,
      });
      if (!mounted) return;
      setState(() {
        ++_loadGeneration;
        _reconciler.remove(
          _reconciler
              .batches(_messages, selectedReply: _replyTo)
              .expand((ids) => ids),
        );
        _messages.clear();
        _messageKeys.clear();
        // Keep the soft-deleted cursor to fetch the next message reliably.
        _loading = false;
        _replyTo = null;
        _hasEarlier = false;
        _historyMode = false;
        _pinned.clear();
        _pinnedIndex = 0;
      });
      // The offline copy must be cleared too, or the history would come
      // back the next time this chat is opened without a connection.
      final userId = _sessionUserId;
      if (userId != null) {
        unawaited(
          OfflineCacheService.instance.removeChat(userId, widget.chatId),
        );
      }
      unawaited(_loadPinned());
      ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _blockUser() async {
    _currentUserId ??= StorageService.getUserId();
    final other = _otherUser?.id;
    if (other == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_label('Could not find the user to block.', 'کاربری برای بلاک یافت نشد'))),
        );
      }
      return;
    }
    try {
      await _api.post('/users/block/$other', {});
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_label('User blocked.', 'کاربر بلاک شد'))));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openPhoto(MessageModel message) async {
    if (_openingMedia || _reconciler.isUnavailable(message.id)) return;
    _openingMedia = true;
    try {
      await _playback.pause();
      if (!mounted) return;
      final route = MaterialPageRoute<void>(
        builder: (_) => PhotoViewerScreen(
          url: _mediaFullUrl(message.mediaId, existingUrl: message.mediaUrl),
          token: _authToken,
          caption: message.content,
          mediaId: message.mediaId,
          chatId: message.chatId,
          messageId: message.id,
        ),
      );
      _photoRoute = route;
      _photoMessageId = message.id;
      await Navigator.of(context).push(route);
    } finally {
      _openingMedia = false;
      _photoRoute = null;
      _photoMessageId = null;
    }
  }

  Future<void> _openViewOnce(MessageModel message) async {
    if (_openingMedia ||
        !message.isViewOnce ||
        message.viewedAt != null ||
        message.senderId == _currentUserId ||
        _reconciler.isUnavailable(message.id))
      return;
    // Timed photos already past their server deadline open to nothing.
    if (message.isTimedExpired) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_label('This timed photo has expired.', 'این عکس زمان‌دار منقضی شده است'))),
      );
      if (mounted) _refreshMessageStatuses();
      return;
    }
    _openingMedia = true;
    try {
      await _playback.pause();
      if (!mounted) return;
      final route = MaterialPageRoute<void>(
        builder: (_) => ViewOncePhotoScreen(
          viewDuration: message.viewDuration,
          viewExpiresAt: message.viewExpiresAt,
          loadPhoto: () =>
              _api.getBytes('/messages/${message.id}/view-once/media'),
          consumePhoto: () async {
            final result = await _api
                .post('/messages/${message.id}/view-once', {})
                .timeout(const Duration(seconds: 20));
            return ViewOnceClaim(
              viewedAt: parseApiDateTime(result['viewed_at'] as String)!,
              viewExpiresAt: parseApiDateTime(
                result['view_expires_at'] as String?,
              ),
            );
          },
          onViewed: (claim) {
            if (!mounted) return;
            setState(() {
              final index = _messages.indexWhere((m) => m.id == message.id);
              if (index != -1)
                _messages[index] = _messages[index].copyWith(
                  viewedAt: claim.viewedAt,
                  viewExpiresAt: claim.viewExpiresAt,
                );
            });
          },
        ),
      );
      _photoRoute = route;
      _photoMessageId = message.id;
      await Navigator.of(context).push(route);
      if (mounted) _refreshMessageStatuses();
    } finally {
      _openingMedia = false;
      _photoRoute = null;
      _photoMessageId = null;
    }
  }

  void _showMessageActions(MessageModel msg) {
    if (_reconciler.isUnavailable(msg.id)) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12, bottom: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: ['❤️', '👍', '😂', '😮', '😢', '🙏'].map((e) => InkWell(
                      onTap: () { Navigator.pop(sheetCtx); _toggleReaction(msg, e); },
                      borderRadius: BorderRadius.circular(24),
                      child: Container(width: 48, height: 48, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.08), shape: BoxShape.circle, border: Border.all(color: Colors.grey.withValues(alpha: 0.12))), child: Text(e, style: const TextStyle(fontSize: 24))),
                    )).toList(),
                  ),
                ),
                const Divider(height: 16),
                MessageActionsSheet(
                  message: msg,
                  canDeleteForAll: _canDelete(msg),
                  canReply: _can('send_messages'),
                  canPin: _canPinMessages,
                  canForward: _allowForwarding && !msg.isSecure,
                  canEdit: _canEdit(msg),
                  onEdit: () => _editMessage(msg),
                  onTogglePin: (pin) => _togglePin(msg, pin),
                  onReply: () { if (mounted && _can('send_messages') && !_reconciler.isUnavailable(msg.id)) setState(() => _replyTo = msg); },
                  onForward: () => _forwardMessage(msg),
                  onDelete: (forAll) => _deleteMessage(msg, forAll: forAll),
                ),
                ListTile(leading: const Icon(Icons.add_reaction_outlined), title: Text(_label('Add reaction (more)', 'افزودن واکنش (بیشتر)')), onTap: () { Navigator.pop(sheetCtx); _showReactionPicker(msg); }),
                ListTile(leading: const Icon(Icons.report_outlined, color: Colors.orange), title: Text(_label('Report and block', 'گزارش و بلاک')), subtitle: Text(_label('Report and block at the same time', 'گزارش + بلاک همزمان'), style: TextStyle(fontSize: 11, color: Colors.grey)), onTap: () { Navigator.pop(sheetCtx); _reportMessage(msg); }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openInvite(ChatInviteLink link) async {
    if (_openingInvite || _chatUnavailable) return;
    setState(() => _openingInvite = true);
    final labels = ChatLabels.of(context);
    try {
      await _playback.pause();
      if (!mounted) return;
      final response = await _api.post('/chats/invite-preview', {
        'invite_link': link.value,
      });
      if (!mounted) return;
      var invite = ChatInviteModel.fromJson(response);
      if (!invite.isMember) {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => ChatInviteDialog(invite: invite, token: _authToken),
        );
        if (confirm != true || !mounted) return;
        final joined = await _api.post('/chats/join', {
          'invite_link': link.value,
        });
        if (!mounted) return;
        invite = ChatInviteModel.fromJson(joined);
      }
      unawaited(ref.read(chatListProvider.notifier).refresh());
      if (invite.id == widget.chatId) {
        unawaited(_loadChatInfo());
        return;
      }
      if (!mounted) return;
      setState(() => _openingInvite = false);
      await ChatNavigation.open(
        context,
        chatId: invite.id,
        builder: (_) => ChatScreen(
          chatId: invite.id,
          title: invite.title,
          chatType: invite.chatType,
          avatarUrl: invite.avatarUrl,
        ),
      );
    } catch (error) {
      if (mounted) {
        final unavailable =
            error is ApiException &&
            [400, 403, 404, 410].contains(error.statusCode);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              unavailable ? labels.inviteUnavailable : labels.inviteFailed,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingInvite = false);
    }
  }

  Future<void> _pickAndSendMusic() async {
    if (!_can('send_files')) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac', 'opus', 'wma'],
      allowMultiple: true,
    );
    if (result == null || !mounted) return;
    final reply = _replyTo;
    var first = true;
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null) continue;
      unawaited(
        _sendMusicFile(
          File(path),
          picked.name,
          reply: first ? reply : null,
        ),
      );
      first = false;
    }
  }

  /// Sends one picked music file, independently of any other upload.
  Future<void> _sendMusicFile(
    File file,
    String pickedName, {
    MessageModel? reply,
  }) async {
    var name = pickedName;
    name = name.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    String? artist;
    String title = name;
    if (name.contains(' - ')) {
      final parts = name.split(' - ');
      artist = parts.first.trim();
      title = parts.sublist(1).join(' - ').trim();
    }
    final sendSpoiler = _isSpoiler;
    final uploadId = _beginUpload('audio', name);
    try {
      final upload = await _uploadAndCache(
        file,
        category: 'audio',
        uploadId: uploadId,
      );
      final mediaId = upload['id'] as String;
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'audio',
        'media_id': mediaId,
        'content': title,
        'audio_title': title,
        if (artist?.isNotEmpty == true) 'audio_artist': artist,
        'is_spoiler': sendSpoiler,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage({
        ...res,
        'media_id': mediaId,
        'media_url': '/api/v1/media/$mediaId',
        'message_type': 'audio',
        'content': title,
        'audio_title': title,
        if (artist?.isNotEmpty == true) 'audio_artist': artist,
      }, reply);
      setState(() {
        _mergeMessages([msg]);
        if (_replyTo?.id == reply?.id) _replyTo = null;
        _isSpoiler = false;
      });
      unawaited(SoundService().playMessageSent());
      if (_slowModeDelay > 0 && (_myRole != 'owner' && _myRole != 'admin')) {
        _startSlowModeTimer(_slowModeDelay);
      }
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (!mounted || e is UploadCancelledException) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      _endUpload(uploadId);
    }
  }

  Future<void> _sendLocation() async {
    if (_sending || !_can('send_messages')) return;
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const LocationPickerScreen()),
    );
    if (picked == null || !mounted) return;
    final reply = _replyTo;
    setState(() => _sending = true);
    try {
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': picked['is_live'] == true ? 'live_location' : 'location',
        'latitude': picked['latitude'],
        'longitude': picked['longitude'],
        if ((picked['title'] as String?)?.isNotEmpty == true) 'location_title': picked['title'],
        if (picked['is_live'] == true) 'live_minutes': picked['live_minutes'] ?? 15,
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage(res, reply);
      setState(() {
        _mergeMessages([msg]);
        _replyTo = null;
        _sending = false;
      });
      if (picked['is_live'] == true) {
        _startLiveLocation(
          msg.id,
          Duration(minutes: (picked['live_minutes'] as int?) ?? 15),
        );
      }
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Polling-based live location: push our position every 20s until the
  /// sharing window ends (Telegram behaviour without a realtime socket).
  void _startLiveLocation(String messageId, Duration duration) {
    _liveLocationTimer?.cancel();
    _liveLocationMessageId = messageId;
    _liveLocationUntil = DateTime.now().add(duration);
    if (mounted) setState(() {});
    _liveLocationTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _pushLiveLocation());
    _pushLiveLocation();
  }

  Future<void> _pushLiveLocation() async {
    final id = _liveLocationMessageId;
    final until = _liveLocationUntil;
    if (id == null || until == null) return;
    if (DateTime.now().isAfter(until)) {
      _stopLiveLocation();
      return;
    }
    final result = await LocationService.current(
      timeout: const Duration(seconds: 12),
    );
    if (!mounted || !result.isSuccess || _liveLocationMessageId != id) return;
    try {
      final res = await _api.post('/messages/$id/live-location', {
        'latitude': result.position!.latitude,
        'longitude': result.position!.longitude,
      });
      if (!mounted) return;
      setState(() => _mergeMessages([MessageModel.fromJson(res)]));
    } catch (_) {
      // A transient failure must not kill the share; the next tick retries.
    }
  }

  Future<void> _stopLiveLocation({bool notifyServer = true}) async {
    final id = _liveLocationMessageId;
    _liveLocationTimer?.cancel();
    _liveLocationTimer = null;
    _liveLocationMessageId = null;
    _liveLocationUntil = null;
    if (mounted) setState(() {});
    if (id == null || !notifyServer) return;
    try {
      final res = await _api.post('/messages/$id/live-location', {'stop': true});
      if (mounted) setState(() => _mergeMessages([MessageModel.fromJson(res)]));
    } catch (_) {}
  }

  Future<void> _sendEncryptedText() async {
    if (_sending || !_can('send_messages')) return;
    final textCtrl = TextEditingController(text: _textCtrl.text.trim());
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_label('Password-protected message', 'متن پیام رمزدار')),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 5,
          minLines: 1,
          decoration: InputDecoration(border: const OutlineInputBorder(), hintText: _label('Message text...', 'متن...')) ,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_label('Cancel', 'لغو'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, textCtrl.text.trim()), child: Text(_label('Continue', 'ادامه')) ,),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    final lock = await EncryptDialog.show(context);
    if (lock == null || !mounted) return;
    final reply = _replyTo;
    setState(() => _sending = true);
    try {
      final cipher = EncryptionService.encryptText(text, lock['password']!);
      final body = <String, dynamic>{
        'chat_id': widget.chatId,
        'message_type': 'text',
        'content': cipher,
        'is_encrypted': true,
        if (lock['hint'] != null) 'encryption_hint': lock['hint'],
      };
      if (reply != null) body['reply_to_id'] = reply.id;
      final res = await _api.post('/messages/', body);
      if (!mounted) return;
      final msg = _sentMessage(res, reply);
      setState(() {
        _mergeMessages([msg]);
        _textCtrl.clear();
        _replyTo = null;
        _sending = false;
      });
      if (_historyMode) await _loadMessages();
      _scrollToBottom();
      if (mounted) ref.read(chatListProvider.notifier).refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Whether this chat currently has a live secure conversation, so the menu
  /// can offer "continue" instead of "start". Leaving the secure page no
  /// longer erases it, so it can be resumed at any time.
  Future<void> _checkSecureSession() async {
    try {
      final res = await _api.get(
        '/messages/${widget.chatId}',
        query: const {'secure': '1', 'limit': '1'},
      );
      final has = (res['messages'] as List? ?? []).isNotEmpty;
      if (mounted && has != _hasSecureSession) {
        setState(() => _hasSecureSession = has);
      }
    } catch (_) {}
  }

  Future<void> _openSecureChat() async {
    await _playback.pause();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SecureChatScreen(chatId: widget.chatId, title: _chatTitle ?? widget.title),
      ),
    );
    if (!mounted) return;
    _refreshMessageStatuses();
    // The secure session may have been erased while we were inside it.
    _checkSecureSession();
  }

  /// Telegram-style poll / quiz composer. The created poll comes back as a
  /// normal message payload and is merged into the history immediately.
  Future<void> _createPoll({bool quiz = false}) async {
    if (_sending || !_can('send_messages')) return;
    final reply = _replyTo;
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => CreatePollScreen(
          chatId: widget.chatId,
          api: _api,
          quiz: quiz,
          replyToId: reply?.id,
        ),
      ),
    );
    if (created == null || !mounted) return;
    setState(() {
      _mergeMessages([MessageModel.fromJson(created)]);
      _replyTo = null;
    });
    if (_historyMode) await _loadMessages();
    _scrollToBottom();
    if (mounted) ref.read(chatListProvider.notifier).refresh();
  }

  /// Replace a poll message in place with the server's fresh tally.
  void _applyPollResult(MessageModel message, Map<String, dynamic> payload) {
    if (!mounted) return;
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index < 0) return;
    setState(() {
      _messages[index] = _messages[index].copyWith(
        poll: PollModel.fromJson(payload),
      );
      _pollBusyId = null;
    });
  }

  Future<void> _runPollAction(
    MessageModel message,
    Future<Map<String, dynamic>> Function() action,
  ) async {
    final poll = message.poll;
    if (poll == null || _pollBusyId != null) return;
    setState(() => _pollBusyId = poll.id);
    try {
      _applyPollResult(message, await action());
    } catch (error) {
      if (!mounted) return;
      setState(() => _pollBusyId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _votePoll(MessageModel message, String optionId) {
    final poll = message.poll!;
    // Multiple-answer polls send the full selection, like Telegram does.
    final selection = poll.allowsMultipleAnswers
        ? (poll.myOptionIds.contains(optionId)
            ? (poll.myOptionIds.where((id) => id != optionId).toList())
            : [...poll.myOptionIds, optionId])
        : [optionId];
    if (poll.allowsMultipleAnswers && selection.isEmpty) {
      return _runPollAction(
        message,
        () => _api.post('/polls/${poll.id}/retract', {}),
      );
    }
    return _runPollAction(
      message,
      () => _api.post('/polls/${poll.id}/vote', {'option_ids': selection}),
    );
  }

  Future<void> _retractPoll(MessageModel message) => _runPollAction(
        message,
        () => _api.post('/polls/${message.poll!.id}/retract', {}),
      );

  Future<void> _closePoll(MessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_label('Close poll', 'بستن نظرسنجی')),
        content: Text(
          _label('No one can vote after the poll is closed. Continue?', 'بعد از بستن، دیگر کسی نمی‌تواند رأی بدهد. ادامه می‌دهید؟'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_label('Cancel', 'لغو')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_label('Close', 'بستن')) ,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runPollAction(
      message,
      () => _api.post('/polls/${message.poll!.id}/close', {}),
    );
  }

  Future<void> _showPollVoters(MessageModel message) async {
    final poll = message.poll;
    if (poll == null) return;
    try {
      final result = await _api.get('/polls/${poll.id}/voters');
      if (!mounted) return;
      final options = (result['options'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(
                  poll.question,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final option in options) ...[
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  title: Text(option['text'] as String? ?? ''),
                  trailing: Text(
                    '${(option['voters'] as List? ?? const []).length}',
                  ),
                ),
                for (final voter in (option['voters'] as List? ?? const [])
                    .whereType<Map<String, dynamic>>())
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline, size: 18),
                    title: Text(voter['display_name'] as String? ?? ''),
                  ),
              ],
            ],
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          final isDark = theme.brightness == Brightness.dark;

          Widget attachBadge(IconData icon, List<Color> colors) {
            return Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.first.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            );
          }

          return Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF17212B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, bottom: 12),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white24 : Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      if (_can('send_photos'))
                        ListTile(
                          leading: attachBadge(Icons.photo_library_rounded, const [Color(0xFF8E2DE2), Color(0xFF4A00E0)]),
                          title: Text(_label('Photos', 'عکس از گالری'), style: TextStyle(fontWeight: FontWeight.w600)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickAndSendMedia(ImageSource.gallery);
                          },
                        ),
                      if (_can('send_photos'))
                        ListTile(
                          leading: attachBadge(Icons.camera_alt_rounded, const [Color(0xFF00C6FF), Color(0xFF0072FF)]),
                          title: Text(_label('Camera', 'دوربین'), style: TextStyle(fontWeight: FontWeight.w600)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickAndSendMedia(ImageSource.camera);
                          },
                        ),
                      if (_can('send_videos'))
                        ListTile(
                          leading: attachBadge(Icons.videocam_rounded, const [Color(0xFFFF416C), Color(0xFFFF4B2B)]),
                          title: Text(_label('Video', 'ویدیو'), style: TextStyle(fontWeight: FontWeight.w600)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickAndSendMedia(ImageSource.gallery, isVideo: true);
                          },
                        ),
                      if (_can('send_files'))
                        ListTile(
                          leading: attachBadge(Icons.insert_drive_file_rounded, const [Color(0xFFF7971E), Color(0xFFFFD200)]),
                          title: Text(_label('Send file (documents, PDF, ZIP, PNG, TXT, ...)', 'ارسال فایل (اسناد، PDF، ZIP، PNG، TXT، ...)'), style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(_label('All formats are supported, like Telegram', 'همه فرمت‌ها مانند تلگرام پشتیبانی می‌شوند'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickAndSendFile();
                          },
                        ),
                      ListTile(
                        leading: attachBadge(Icons.emoji_emotions_rounded, const [Color(0xFFFF0844), Color(0xFFFFB199)]),
                        title: Text(_label('Sticker', 'استیکر'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Choose from sticker packs', 'انتخاب از پک‌های آماده'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showStickerPicker();
                        },
                      ),
                      ListTile(
                        leading: attachBadge(Icons.gif_box_rounded, const [Color(0xFF43E97B), Color(0xFF38F9D7)]),
                        title: const Text('GIF', style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Your saved GIFs (upload a .gif file)', 'گیف‌های ذخیره‌شده شما (فایل .gif آپلود کنید)'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showGifPicker();
                        },
                      ),
                      if (_can('send_files'))
                        ListTile(
                          leading: attachBadge(Icons.music_note_rounded, const [Color(0xFF654EA3), Color(0xFFEAAFC8)]),
                          title: Text(_label('Music / audio file', 'موسیقی / فایل صوتی'), style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(_label('Send music with the built-in player', 'ارسال آهنگ با پخش‌کننده داخلی'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _pickAndSendMusic();
                          },
                        ),
                      ListTile(
                        key: const ValueKey('attach-poll'),
                        leading: attachBadge(Icons.poll_rounded, const [Color(0xFF2193B0), Color(0xFF6DD5ED)]),
                        title: Text(_label('Poll', 'نظرسنجی'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Ask a question with multiple options', 'سؤال با چند گزینه، مثل تلگرام'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _createPoll();
                        },
                      ),
                      ListTile(
                        key: const ValueKey('attach-quiz'),
                        leading: attachBadge(Icons.quiz_rounded, const [Color(0xFF834D9B), Color(0xFFD04ED6)]),
                        title: Text(_label('Quiz (multiple choice)', 'آزمون (چهارگزینه‌ای)'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('One correct answer; results are shown', 'یک گزینه صحیح دارد و نتیجه اعلام می‌شود'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _createPoll(quiz: true);
                        },
                      ),
                      ListTile(
                        leading: attachBadge(Icons.location_on_rounded, const [Color(0xFF11998E), Color(0xFF38EF7D)]),
                        title: Text(_label('Location', 'موقعیت مکانی'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Share a place or live location', 'ارسال لوکیشن ثابت یا زنده'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _sendLocation();
                        },
                      ),
                      ListTile(
                        leading: attachBadge(Icons.enhanced_encryption_rounded, const [Color(0xFFF2994A), Color(0xFFF2C94C)]),
                        title: Text(_label('Password-protected message', 'پیام رمزدار'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Lock text with a password', 'قفل متن با رمز (بدون رمز باز نمی‌شود)'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _sendEncryptedText();
                        },
                      ),
                      ListTile(
                        leading: attachBadge(Icons.play_circle_fill_rounded, const [Color(0xFF00B4DB), Color(0xFF0083B0)]),
                        title: Text(_label('Video message', 'پیام ویدیویی گرد'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('Round video message (video_note)', 'ویدیو دایره‌ای مانند تلگرام (video_note)'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _recordVideoNote();
                        },
                      ),
                      Divider(color: theme.dividerColor.withValues(alpha: 0.3), height: 16),
                      SwitchListTile(
                        secondary: const Icon(Icons.visibility_off_outlined, color: Colors.purple),
                        title: Text(_label('Spoiler (hidden until tapped)', 'حالت اسپویلر (مخفی تا زمان لمس)'), style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(_label('The next message will be blurred', 'پیام بعدی محو نمایش داده می‌شود'), style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                        value: _isSpoiler,
                        onChanged: (val) {
                          setSheetState(() {});
                          setState(() => _isSpoiler = val);
                        },
                      ),
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _setBackgroundImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 80,
    );
    if (picked == null) return;
    try {
      final upload = await _api.uploadFile('/media/upload', File(picked.path));
      final mediaId = upload['id'] as String;
      final url = _mediaFullUrl(mediaId, existingUrl: null);
      await _api.post('/chats/${widget.chatId}/background', {
        'type': 'image',
        'value': url,
      });
      setState(() {
        _bgImageUrl = url;
        _bgColor = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(
          content: Text(ChatLabels.of(context).backgroundSet),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  /// Telegram-like edit rights: only the sender edits their own message
  /// (text or caption). Encrypted / view-once / secure messages are not editable.
  bool _canEdit(MessageModel msg) {
    if (_reconciler.isUnavailable(msg.id)) return false;
    if (msg.isViewOnce || msg.isEncrypted || msg.isSecure) return false;
    final mine = _chatType == 'channel'
        ? msg.author?.id == _currentUserId
        : msg.senderId == _currentUserId;
    if (mine != true) return false;
    if (msg.messageType == 'text') return (msg.content?.isNotEmpty ?? false);
    return ['image', 'video', 'file', 'audio', 'music', 'gif']
        .contains(msg.messageType);
  }

  Future<void> _editMessage(MessageModel msg) async {
    final ctrl = TextEditingController(text: msg.content ?? '');
    final isCaption = msg.messageType != 'text';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isCaption ? _label('Edit caption', 'ویرایش کپشن') : _label('Edit message', 'ویرایش پیام')) ,
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 5,
          minLines: 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: _label('New text...', 'متن جدید...'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_label('Cancel', 'لغو'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(_label('Save', 'ذخیره'))),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    if (result == (msg.content ?? '')) return;
    try {
      await _api.post('/messages/${msg.id}/edit', {'content': result});
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((m) => m.id == msg.id);
        if (i != -1) {
          _messages[i] = _messages[i].copyWith(content: result, isEdited: true, editedAt: DateTime.now());
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label('Message edited.', 'پیام ویرایش شد'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Tap on an @username mention → resolve to user → open their private chat.
  Future<void> _openMention(String username) async {
    try {
      final user = await _api.get('/users/by-username/$username');
      if (!mounted) return;
      final userId = user['id'] as String?;
      final displayName = user['display_name'] as String? ?? '@$username';
      if (userId == null) return;
      if (userId == _currentUserId) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_label('That is you.', 'این خود شما هستید'))));
        return;
      }
      final res = await _api.post('/chats/private', {'user_id': userId});
      if (!mounted) return;
      final chatId = res['chat_id'] as String?;
      if (chatId == null) return;
      if (chatId == widget.chatId) return;
      await _playback.pause();
      if (!mounted) return;
      await ChatNavigation.open(
        context,
        chatId: chatId,
        builder: (_) => ChatScreen(
          chatId: chatId,
          title: displayName,
          chatType: 'private',
        ),
      );
    } catch (e) {
      if (mounted) {
        final msg = e is ApiException && e.statusCode == 404
            ? _label('User @$username was not found.', 'کاربر @$username یافت نشد')
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _forwardMessage(MessageModel msg) async {
    if (!_allowForwarding) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_label('Forwarding from this chat is disabled by an administrator.', 'فوروارد از این گفتگو توسط مدیر بسته شده است'))),
      );
      return;
    }
    final chatsRes = await _api.get('/chats/');
    final chats = (chatsRes['chats'] as List? ?? []);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ListView.builder(
        itemCount: chats.length,
        itemBuilder: (_, i) {
          final c = chats[i];
          final title =
              c['title'] as String? ??
              (c['other_user'] != null
                  ? c['other_user']['display_name'] as String? ?? _label('Chat', 'چت')
                  : _label('Chat', 'چت'));
          return ListTile(
            title: Text(title),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                await _api.post('/messages/${msg.id}/forward', {
                  'target_chat_id': c['id'],
                });
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(_label('Forwarded.', 'فوروارد شد'))));
                }
              } catch (e) {
                if (mounted) {
                  final msg = e is ApiException && e.statusCode == 403
                      ? _label('This message cannot be forwarded (sender or administrator privacy settings).', 'فوروارد این پیام مجاز نیست (حریم خصوصی فرستنده یا مدیر)')
                      : e.toString();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                }
              }
            },
          );
        },
      ),
    );
  }

  void _showMoreMenu() {
    final isGroupOrChannel = _chatType == 'group' || _chatType == 'channel';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12, bottom: 8), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                if (isGroupOrChannel)
                  ListTile(
                    leading: Icon(_chatType == 'channel' ? Icons.campaign_outlined : Icons.group_outlined),
                    title: Text(_chatType == 'channel' ? _label('Channel information', 'اطلاعات کانال') : _label('Group information', 'اطلاعات گروه')),
                    onTap: () { Navigator.pop(ctx); _openManagement(); },
                  ),
                ListTile(
                  leading: const Icon(Icons.report_outlined, color: Colors.orange),
                  title: Text(_chatType == 'private' ? _label('Report and block user', 'گزارش و بلاک کاربر') : _label('Report group/channel', 'گزارش گروه/کانال')) ,
                  subtitle: Text(_label('Report and block at the same time', 'گزارش + بلاک همزمان (مانند تلگرام)'), style: TextStyle(fontSize: 11, color: Colors.grey)),
                  onTap: () { Navigator.pop(ctx); _reportCurrentChat(); },
                ),
                ListTile(
                  leading: const Icon(Icons.shield_outlined, color: Colors.green),
                  title: Text(_hasSecureSession ? _label('Continue secure chat', 'ادامه گفتگوی امن') : _label('Secure chat', 'گفتگوی امن')) ,
                  subtitle: Text(
                    _hasSecureSession
                        ? _label('Secure chat is open • tap to continue', 'گفتگوی امن باز است • برای ادامه ضربه بزنید')
                        : _label('Separate protected screen • screenshots, forwarding, and downloads disabled', 'صفحه مشکی جدا • ضد اسکرین‌شات • بدون فوروارد و دانلود'),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  onTap: () { Navigator.pop(ctx); _openSecureChat(); },
                ),
                ListTile(leading: const Icon(Icons.schedule), title: Text(_label('Scheduled messages', 'پیام‌های زمان‌بندی‌شده')), onTap: () { Navigator.pop(ctx); _openScheduledSheet(); }),
                ListTile(leading: const Icon(Icons.image), title: Text(_label('Chat wallpaper', 'بک‌گراند تصویری')), onTap: () { Navigator.pop(ctx); _setBackgroundImage(); }),
                ListTile(leading: const Icon(Icons.search), title: Text(_label('Search in chat', 'جستجو در چت')), onTap: () { Navigator.pop(ctx); setState(() => _searchMode = true); }),
                const Divider(height: 12),
                ListTile(leading: const Icon(Icons.delete_outline), title: Text(_label('Clear history for me', 'پاک کردن تاریخچه برای من')), onTap: () { Navigator.pop(ctx); _clearHistory(forAll: false); }),
                if (!isGroupOrChannel || _myRole == 'owner' || _capabilities['clear_history_for_all'] == true)
                  ListTile(
                    key: const ValueKey('clear-history-for-all'),
                    leading: const Icon(Icons.delete_forever, color: Colors.red),
                    title: Text(_label('Clear history for everyone', 'پاک کردن برای همه'), style: const TextStyle(color: Colors.red)),
                    subtitle: Text(_label('This will be removed for all chat members', 'برای همه اعضای چت حذف می‌شود'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () { Navigator.pop(ctx); _clearHistory(forAll: true); },
                  ),
                if (_canPinMessages && _pinned.isNotEmpty)
                  ListTile(key: const ValueKey('unpin-all'), leading: const Icon(Icons.push_pin_outlined), title: Text(ChatLabels.of(context).unpinAll), onTap: () { Navigator.pop(ctx); _unpinAll(); }),
                if (!isGroupOrChannel)
                  ListTile(leading: const Icon(Icons.block, color: Colors.red), title: Text(_label('Block user', 'بلاک کاربر'), style: const TextStyle(color: Colors.red)), onTap: () { Navigator.pop(ctx); _blockUser(); }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _label(String en, String fa) =>
      Localizations.localeOf(context).languageCode == 'fa' ? fa : en;

  Future<void> _openManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _chatType == 'channel'
            ? ChannelManagementScreen(
                chatId: widget.chatId,
                api: _api,
                token: _authToken,
              )
            : GroupManagementScreen(
                chatId: widget.chatId,
                api: _api,
                token: _authToken,
              ),
      ),
    );
    if (!mounted) return;
    await _loadChatInfo();
    if (mounted) ref.read(chatListProvider.notifier).refresh();
  }

  Future<void> _toggleMute() async {
    if (_muting) return;
    setState(() => _muting = true);
    try {
      final res = await _api.post('/chats/${widget.chatId}/mute', {
        'is_muted': !_isMuted,
      });
      if (mounted) setState(() => _isMuted = res['is_muted'] as bool);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _muting = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(authenticatedSessionProvider);
    if (session.userId == _sessionUserId) {
      _api = session.api;
      _authToken = session.token;
    }
    _currentUserId = _sessionUserId;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _searchMode
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
decoration: InputDecoration(
                        hintText: _label('Search...', 'جستجو...'),
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onSubmitted: (q) => _loadMessages(query: q),
              )
            : ChatHeader(
                title: _displayTitle,
                chatType: _chatType,
                otherUser: _otherUser,
                avatarUrl: _chatAvatarUrl,
                membersCount: _hasChatInfo ? _membersCount : null,
                onlineCount: _hasChatInfo ? _onlineCount : null,
                token: _authToken,
                onTap: _chatType == 'group' || _chatType == 'channel'
                    ? _openManagement
                    : _otherUser == null
                    ? null
                    : () async {
                        await _playback.pause();
                        if (!mounted || _otherUser == null) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                UserProfileScreen(userId: _otherUser!.id),
                          ),
                        );
                        if (mounted) unawaited(_loadChatInfo());
                      },
              ),
        actions: [
          if (_searchMode)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() => _searchMode = false);
                _loadMessages();
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _showMoreMenu,
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          color: _bgImageUrl == null
              ? (_bgColor ?? theme.scaffoldBackgroundColor)
              : null,
          image: _bgImageUrl != null
              ? DecorationImage(
                  image: CachedNetworkImageProvider(
                    _bgImageUrl!,
                    headers: _authToken != null
                        ? {'Authorization': 'Bearer ${_authToken}'}
                        : null,
                  ),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: SafeArea(
          child: Column(
            children: [
              if (_openingInvite) const LinearProgressIndicator(minHeight: 2),
              if (_isSuspended)
                Container(
                  width: double.infinity,
                  color: Colors.red.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.block, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_label('This group/channel is suspended${_suspensionReason != null ? ': $_suspensionReason' : ''}', 'این گروه/کانال تعلیق شده است${_suspensionReason != null ? ': $_suspensionReason' : ''}'), style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600))),
                      if (_myRole == 'owner')
                        TextButton(onPressed: _loadChatInfo, child: Text(_label('Refresh', 'به‌روزرسانی'), style: TextStyle(fontSize: 12))),
                    ],
                  ),
                ),
              if (_isClosed)
                Container(
                  width: double.infinity,
                  color: Colors.orange.withValues(alpha: 0.14),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.lock, color: Colors.orange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _label(
                            'This group/channel is closed${_closedReason != null ? ': $_closedReason' : ' (only the owner can send messages)'}',
                            "این گروه/کانال بسته شده است${_closedReason != null ? ': $_closedReason' : ' (فقط مالک می‌تواند ارسال کند)'}",
                          ),
                          style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_pinned.isNotEmpty && !_searchMode)
                PinnedMessagesBar(
                  pinned: _pinned,
                  index: _pinnedIndex,
                  onTap: _tapPinnedBar,
                  onShowAll: _openPinnedMessages,
                  onUnpin: _canPinMessages
                      ? () => _togglePin(
                          _pinned[_pinnedIndex < _pinned.length
                              ? _pinnedIndex
                              : 0],
                          false,
                        )
                      : null,
                ),
              if (_liveLocationMessageId != null)
                Container(
                  width: double.infinity,
                  color: Colors.green.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    const Icon(Icons.share_location, color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _liveLocationUntil != null
                            ? _label('Live location is shared until ${_liveLocationUntil!.hour.toString().padLeft(2, '0')}:${_liveLocationUntil!.minute.toString().padLeft(2, '0')}', 'موقعیت زنده تا ${_liveLocationUntil!.hour.toString().padLeft(2, '0')}:${_liveLocationUntil!.minute.toString().padLeft(2, '0')} به‌اشتراک گذاشته می‌شود')
                            : _label('Live location is being shared', 'موقعیت زنده در حال اشتراک است'),
                        style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: _stopLiveLocation,
                      child: Text(_label('Stop', 'توقف'), style: TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  ]),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                            ElevatedButton(
                              onPressed: _chatUnavailable
                                  ? () => Navigator.of(context).maybePop()
                                  : () => _loadMessages(),
                              child: Text(
                                _chatUnavailable
                                    ? ChatLabels.of(context).close
                                    : MediaLabels.of(context).retry,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _messages.isEmpty
                    ? Center(
                        child: Text(
                          _label('No messages yet', 'هنوز پیامی نیست'),
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        itemCount: _messages.length + 1,
                        findChildIndexCallback: (key) {
                          if (key == const ValueKey('history-header')) return 0;
                          final index = _messages.indexWhere(
                            (m) => _messageKeys[m.id] == key,
                          );
                          return index == -1 ? null : index + 1;
                        },
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Center(
                              key: const ValueKey('history-header'),
                              child: _hasEarlier
                                  ? TextButton.icon(
                                      onPressed: _loadingEarlier
                                          ? null
                                          : _loadEarlier,
                                      icon: _loadingEarlier
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.expand_less),
                                      label: Text(
                                        MediaLabels.of(context).earlier,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            );
                          }
                          final msg = _messages[index - 1];
                          final isMine =
                              _chatType != 'channel' &&
                              msg.senderId == _currentUserId;
                          return GestureDetector(
                            key: _messageKeys.putIfAbsent(
                              msg.id,
                              () => GlobalKey(),
                            ),
                            onLongPress: () => _showMessageActions(msg),
                            onDoubleTap: () => _showReactionPicker(msg),
                            // Reply gestures do not own taps on media anymore.
                            onHorizontalDragEnd: (details) {
                              final velocity = details.primaryVelocity ?? 0;
                              if (velocity.abs() > 200 &&
                                  _can('send_messages')) {
                                setState(() => _replyTo = msg);
                              }
                            },
                            child: MessageBubble(
                              message: msg,
                              isMine: isMine,
                              currentUserId: _currentUserId,
                              reply: _replyPreviewFor(msg),
                              onReplyTap: msg.replyToId == null ? null : () => _jumpToReply(msg.replyToId!),
                              onOpenPhoto: () {
                                // For sticker/gif/video_note also allow viewing
                                if (msg.messageType == 'sticker' || msg.messageType == 'gif' || msg.messageType == 'video_note') return;
                                _openPhoto(msg);
                              },
                              onOpenViewOnce: () => _openViewOnce(msg),
                              onInviteTap: _openInvite,
                              onMentionTap: _openMention,
                              musicQueue: _messages.where((m) => m.isMusic && m.mediaId != null).toList(),
                              chatTitle: _chatTitle ?? widget.title,
                              coordinator: _playback,
                              highlighted: _highlightedMessageId == msg.id,
                              showSender: _chatType == 'group' || _chatType == 'channel',
                              mediaUrl: _mediaFullUrl(msg.mediaId, existingUrl: msg.mediaUrl),
                              token: _authToken,
                              onReactionTap: (emoji) => _toggleReaction(msg, emoji),
                              onAddReaction: () => _showReactionPicker(msg),
                              isSecurityChat: _chatType == 'security',
                              pollBusy: msg.poll != null &&
                                  _pollBusyId == msg.poll!.id,
                              onPollVote: (optionId) => _votePoll(msg, optionId),
                              onPollRetract: () => _retractPoll(msg),
                              onPollClose: () => _closePoll(msg),
                              onPollShowVoters: () => _showPollVoters(msg),
                            ),
                          );
                        },
                      ),
              ),
              if (_historyMode)
                TextButton.icon(
                  onPressed: () => _loadMessages(),
                  icon: const Icon(Icons.arrow_downward_rounded),
                  label: Text(MediaLabels.of(context).latest),
                ),
              if (_replyTo != null && !_searchMode) _buildReplyComposer(theme),
              const MiniMusicPlayer(),
              if (!_searchMode && !_chatUnavailable) _buildInputBar(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReplyComposer(ThemeData theme) {
    return Container(
      color: theme.cardColor,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: ReplyPreview(
              reply: _replyTo!.asReplyPreview,
              currentUserId: _currentUserId,
              token: _authToken,
            ),
          ),
          IconButton(
            tooltip: MediaLabels.of(context).cancelReply,
            onPressed: () => setState(() => _replyTo = null),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    if (!_can('send_messages')) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _chatType == 'security'
                    ? _label(
                        'Official security notices. This chat is read-only.',
                        'اعلان‌های رسمی امنیتی. این چت فقط خواندنی است.',
                      )
                    : _chatType == 'channel'
                        ? _label(
                            'Broadcast channel — only authorized administrators can publish.',
                            'کانال انتشار — فقط مدیران مجاز می‌توانند پست منتشر کنند.',
                          )
                        : _label(
                            'Sending messages is not allowed in this group.',
                            'ارسال پیام در این گروه مجاز نیست.',
                          ),
                textAlign: TextAlign.center,
              ),
              if (_chatType == 'channel')
                TextButton.icon(
                  onPressed: _muting ? null : _toggleMute,
                  icon: Icon(
                    _isMuted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_outlined,
                  ),
                  label: Text(
                    _isMuted
                        ? _label('Unmute', 'فعال کردن اعلان‌ها')
                        : _label('Mute', 'بی‌صدا'),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: theme.cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_slowModeRemaining > 0)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer, size: 16, color: Colors.amber),
                    const SizedBox(width: 6),
                    Text(
                      _label('Slow mode is on: wait $_slowModeRemaining seconds before sending again.', 'حالت کند فعال است: $_slowModeRemaining ثانیه تا امکان ارسال بعدی'),
                      style: const TextStyle(fontSize: 12, color: Colors.amber),
                    ),
                  ],
                ),
              ),
            AnimatedBuilder(
              animation: UploadQueue.instance,
              builder: (context, _) {
                final jobs = UploadQueue.instance.jobsFor(widget.chatId);
                if (jobs.isEmpty) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final upload in jobs)
                      ChatUploadBanner(
                        key: ValueKey(upload.id),
                        mediaType: upload.mediaType,
                        fileName: upload.fileName,
                        progress: upload.progress,
                        isSending: upload.isFinalizing,
                        onCancel: upload.canCancel
                            ? () => UploadQueue.instance.cancel(upload.id)
                            : null,
                        isFa: Localizations.localeOf(context).languageCode == 'fa',
                      ),
                  ],
                );
              },
            ),
            if (_isRecording)
              VoiceRecordingBar(
                onCancel: _cancelVoiceRecord,
                onSend: _toggleVoiceRecord,
                isFa: Localizations.localeOf(context).languageCode == 'fa',
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded),
                    tooltip: _label('Attach media or files', 'پیوست (عکس، فایل، استیکر، GIF، ویدیو گرد)'),
                    onPressed: _showAttachMenu,
                  ),
                if (_isSpoiler)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10, right: 2),
                    child: GestureDetector(
                      onTap: () => setState(() => _isSpoiler = false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.purple),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.visibility_off, size: 14, color: Colors.purple),
                            const SizedBox(width: 4),
                            Text(_label('Spoiler', 'اسپویلر'), style: const TextStyle(fontSize: 11, color: Colors.purple)),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: TextField(
                      controller: _textCtrl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendText(),
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: _chatType == 'channel'
                            ? _label('Broadcast a post...', 'انتشار پست...')
                            : _label('Message...', 'پیام...'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: theme.brightness == Brightness.dark
                            ? const Color(0xFF242F3D)
                            : const Color(0xFFF1F5F9),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.schedule_rounded),
                  tooltip: _label('Schedule message', 'زمان‌بندی ارسال پیام'),
                  onPressed: _scheduleMessage,
                ),
                IconButton(
                  onPressed: !_isRecording && !_can('send_voice')
                      ? null
                      : _toggleVoiceRecord,
                  icon: Icon(
                    _isRecording ? Icons.stop_circle : Icons.mic_rounded,
                    color: _isRecording ? Colors.red : theme.colorScheme.primary,
                  ),
                ),
                Material(
                  color: theme.colorScheme.primary,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.hardEdge,
                  elevation: 1.5,
                  child: InkWell(
                    onTap: _sendText,
                    onLongPress: _scheduleMessage,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
            ],
          ),
        ),
    );
  }
}
