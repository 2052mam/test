import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../data/models/chat_folder_model.dart';
import '../../data/models/chat_model.dart';
import '../../data/services/api_service.dart';
import '../../data/services/archive_lock_service.dart';
import '../../data/services/offline_cache_service.dart';
import '../../data/services/notification_service.dart';
import 'auth_provider.dart';

/// The main (non archived) chat list plus the archive summary shown on top of
/// it, exactly like Telegram's collapsed "Archived chats" row.
class ChatListState {
  const ChatListState({
    this.chats = const [],
    this.archivedTotal = 0,
    this.archivedUnread = 0,
    this.archivedChatsWithUnread = 0,
    this.hasArchivePin = false,
    this.archiveLocked = false,
  });

  final List<ChatModel> chats;
  final int archivedTotal;
  final int archivedUnread;
  final int archivedChatsWithUnread;
  final bool hasArchivePin;
  final bool archiveLocked;

  bool get hasArchive => archivedTotal > 0;

  factory ChatListState.fromJson(Map<String, dynamic> json) {
    final archived = json['archived'] as Map<String, dynamic>? ?? const {};
    return ChatListState(
      chats: (json['chats'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatModel.fromJson)
          .toList(),
      archivedTotal: archived['total'] as int? ?? 0,
      archivedUnread: archived['unread'] as int? ?? 0,
      archivedChatsWithUnread: archived['chats_with_unread'] as int? ?? 0,
      hasArchivePin: json['has_archive_pin'] as bool? ?? false,
      archiveLocked: json['archive_locked'] as bool? ?? false,
    );
  }
}

final archiveLockProvider = Provider<ArchiveLockService>((ref) {
  final session = ref.watch(authenticatedSessionProvider);
  return ArchiveLockService(session.api, userId: session.userId);
});

final chatListProvider =
    StateNotifierProvider.autoDispose<ChatListNotifier, AsyncValue<ChatListState>>(
      (ref) {
        final session = ref.watch(authenticatedSessionProvider);
        return ChatListNotifier(
          api: session.api,
          enabled: session.userId != null,
          userId: session.userId,
        );
      },
    );

/// Archived chats are fetched on demand, only while the archive is unlocked.
final archivedChatListProvider =
    StateNotifierProvider.autoDispose<ChatListNotifier, AsyncValue<ChatListState>>(
      (ref) {
        final session = ref.watch(authenticatedSessionProvider);
        final lock = ref.watch(archiveLockProvider);
        return ChatListNotifier(
          api: session.api,
          enabled: session.userId != null,
          archived: true,
          lock: lock,
        );
      },
    );

final chatFoldersProvider =
    StateNotifierProvider.autoDispose<ChatFoldersNotifier, AsyncValue<List<ChatFolderModel>>>(
      (ref) {
        final session = ref.watch(authenticatedSessionProvider);
        return ChatFoldersNotifier(
          api: session.api,
          enabled: session.userId != null,
          userId: session.userId,
        );
      },
    );

class ChatListNotifier extends StateNotifier<AsyncValue<ChatListState>> {
  ChatListNotifier({
    ApiService? api,
    bool enabled = true,
    bool archived = false,
    ArchiveLockService? lock,
    String? userId,
  }) : _api = api ?? ApiService(),
       _enabled = enabled,
       _archived = archived,
       _lock = lock,
       _userId = userId,
       super(_initial(enabled, userId, archived)) {
    if (enabled) {
      unawaited(loadChats());
      _pollTimer = Timer.periodic(
        const Duration(seconds: ApiConstants.pollingIntervalSeconds),
        (_) => loadChats(),
      );
    }
  }

  final ApiService _api;
  final bool _enabled;
  final bool _archived;
  final ArchiveLockService? _lock;
  final String? _userId;
  Timer? _pollTimer;
  Future<void>? _loading;

  /// Offline-first: a previously loaded list is shown immediately (no
  /// spinner, no error screen) and refreshed in the background; only a
  /// device that has never loaded the list starts from the loading state.
  static AsyncValue<ChatListState> _initial(
    bool enabled,
    String? userId,
    bool archived,
  ) {
    if (!enabled) return const AsyncValue.data(ChatListState());
    if (userId != null) {
      final cached = OfflineCacheService.instance.chatListJsonSync(
        userId,
        archived: archived,
      );
      if (cached != null) {
        try {
          return AsyncValue.data(ChatListState.fromJson(cached));
        } catch (_) {
          // A corrupt snapshot must never block startup.
        }
      }
    }
    return const AsyncValue.loading();
  }

  Future<void> loadChats() {
    if (!mounted || !_enabled) return Future<void>.value();
    // Polling and a read/send/delete refresh can happen together. Share the
    // request rather than allowing an older response to replace newer state.
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final res = await _api.get(
        '/chats/',
        query: _archived ? const {'archived': '1'} : null,
        headers: _archived ? _lock?.headers : null,
      );
      if (!mounted) return;
      final previous = state.valueOrNull;
      final next = ChatListState.fromJson(res);
      state = AsyncValue.data(next);
      if (_userId != null) {
        unawaited(
          OfflineCacheService.instance.saveChatListJson(
            _userId,
            archived: _archived,
            json: res,
          ),
        );
      }
      // Instant in-app/background notifications (Item 3): the same 3s poll
      // Telegram-style diffs unread counts — no push server needed.
      if (!_archived) {
        unawaited(
          NotificationService().notifyForChatList(
            previous: previous?.chats,
            current: next.chats,
            currentUserId: _userId,
          ),
        );
      }
    } catch (error, stack) {
      if (!mounted) return;
      // A locked archive is a real error for the archive screen, but the main
      // list must not flash an error/loading screen on each background poll.
      if (!state.hasValue) state = AsyncValue.error(error, stack);
    }
  }

  Future<void> refresh() => loadChats();

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

class ChatFoldersNotifier
    extends StateNotifier<AsyncValue<List<ChatFolderModel>>> {
  ChatFoldersNotifier({ApiService? api, bool enabled = true, String? userId})
    : _api = api ?? ApiService(),
      _enabled = enabled,
      _userId = userId,
      super(_initial(enabled, userId)) {
    if (enabled) unawaited(load());
  }

  final ApiService _api;
  final bool _enabled;
  final String? _userId;

  static AsyncValue<List<ChatFolderModel>> _initial(
    bool enabled,
    String? userId,
  ) {
    if (!enabled) return const AsyncValue.data(<ChatFolderModel>[]);
    final cached = userId == null
        ? null
        : OfflineCacheService.instance.foldersJsonSync(userId);
    final folders = cached?['folders'] as List?;
    if (folders != null) {
      try {
        return AsyncValue.data(
          folders
              .whereType<Map<String, dynamic>>()
              .map(ChatFolderModel.fromJson)
              .toList(),
        );
      } catch (_) {}
    }
    return const AsyncValue.loading();
  }

  static List<ChatFolderModel> _parse(Map<String, dynamic> res) =>
      (res['folders'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatFolderModel.fromJson)
          .toList()
        ..sort((a, b) => a.position.compareTo(b.position));

  Future<void> load() async {
    if (!mounted || !_enabled) return;
    try {
      final res = await _api.get('/chats/folders');
      if (!mounted) return;
      state = AsyncValue.data(_parse(res));
      if (_userId != null) {
        unawaited(
          OfflineCacheService.instance.saveFoldersJson(_userId, res),
        );
      }
    } catch (error, stack) {
      if (!mounted) return;
      if (!state.hasValue) state = AsyncValue.error(error, stack);
    }
  }

  Future<void> save(ChatFolderModel folder, {String? id}) async {
    await _api.post(
      id == null ? '/chats/folders' : '/chats/folders/$id',
      folder.toRequestBody(),
    );
    await load();
  }

  Future<void> remove(String id) async {
    await _api.post('/chats/folders/$id/delete', {});
    await load();
  }
}
