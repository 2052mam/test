import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/message_model.dart';

/// Offline-first store for chats and messages (Telegram-style).
///
/// Everything the server last told us — the chat list, each chat's recent
/// history, chat info, pinned messages and backgrounds — is persisted in a
/// Hive box keyed by user id. Screens seed themselves from this store before
/// (and regardless of whether) the network answers, so with the connection
/// off the app still opens onto the real chat list and every chat still
/// shows its previous messages instead of an "internet error" screen. Media
/// binaries live in [MediaCacheService]; this store holds the metadata that
/// points at them.
///
/// All reads used for seeding are synchronous (Hive serves them from memory
/// once the box is open) and every method fails soft: a corrupt entry or a
/// missing box degrades to "no cache", never to a crash.
class OfflineCacheService {
  OfflineCacheService._();

  static final OfflineCacheService instance = OfflineCacheService._();

  static const String _boxName = 'offline_cache_v1';

  /// How much history is kept per chat. Enough to read back comfortably
  /// offline without letting one busy group eat the device's storage.
  static const int maxMessagesPerChat = 500;

  Box<String>? _box;

  bool get isReady => _box != null;

  Future<void> init() async {
    if (_box != null) return;
    try {
      _box = await Hive.openBox<String>(_boxName);
    } catch (error) {
      debugPrint('OfflineCacheService init failed: $error');
      _box = null;
    }
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    try {
      await _box?.clear();
      await _box?.close();
    } catch (_) {}
    _box = null;
  }

  // ---------------------------------------------------------------------
  // keys
  // ---------------------------------------------------------------------
  static String _chatListKey(String userId, bool archived) =>
      archived ? 'arch:$userId' : 'chats:$userId';
  static String _foldersKey(String userId) => 'folders:$userId';
  static String _messagesKey(String userId, String chatId) =>
      'msgs:$userId:$chatId';
  static String _metaKey(String userId, String chatId, String kind) =>
      'meta:$userId:$chatId:$kind';

  // ---------------------------------------------------------------------
  // raw JSON helpers (single source; everything else builds on these)
  // ---------------------------------------------------------------------
  Map<String, dynamic>? rawJsonSync(String key) {
    final raw = _box?.get(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // A half-written entry must never break offline startup.
    }
    return null;
  }

  Future<void> saveRawJson(String key, Map<String, dynamic> value) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(key, jsonEncode(value));
    } catch (error) {
      debugPrint('OfflineCacheService could not persist $key: $error');
    }
  }

  // ---------------------------------------------------------------------
  // chat list + folders (raw server payloads, re-parsed by the providers)
  // ---------------------------------------------------------------------
  Map<String, dynamic>? chatListJsonSync(String userId, {bool archived = false}) =>
      rawJsonSync(_chatListKey(userId, archived));

  Future<void> saveChatListJson(
    String userId, {
    bool archived = false,
    required Map<String, dynamic> json,
  }) =>
      saveRawJson(_chatListKey(userId, archived), json);

  Map<String, dynamic>? foldersJsonSync(String userId) =>
      rawJsonSync(_foldersKey(userId));

  Future<void> saveFoldersJson(String userId, Map<String, dynamic> json) =>
      saveRawJson(_foldersKey(userId), json);

  // ---------------------------------------------------------------------
  // per-chat metadata: info / pinned / background, as raw server payloads
  // ---------------------------------------------------------------------
  Map<String, dynamic>? chatMetaSync(String userId, String chatId, String kind) =>
      rawJsonSync(_metaKey(userId, chatId, kind));

  Future<void> saveChatMeta(
    String userId,
    String chatId,
    String kind,
    Map<String, dynamic> json,
  ) =>
      saveRawJson(_metaKey(userId, chatId, kind), json);

  // ---------------------------------------------------------------------
  // messages
  // ---------------------------------------------------------------------
  List<MessageModel> messagesSync(String userId, String chatId) {
    final stored = rawJsonSync(_messagesKey(userId, chatId));
    final raw = stored?['messages'] as List? ?? const [];
    final messages = <MessageModel>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        messages.add(
          MessageModel.fromJson(Map<String, dynamic>.from(entry)),
        );
      } catch (_) {
        // Skip a single unparseable row; keep the rest of the history.
      }
    }
    messages.sort((a, b) {
      final order = a.createdAt.compareTo(b.createdAt);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return messages;
  }

  /// Merges [messages] into the stored history of a chat (newest wins per
  /// id), caps it to the most recent [maxMessagesPerChat] and persists it.
  Future<void> saveMessages(
    String userId,
    String chatId,
    Iterable<MessageModel> messages,
  ) async {
    if (_box == null || userId.isEmpty || chatId.isEmpty) return;
    final byId = <String, MessageModel>{
      for (final message in messagesSync(userId, chatId)) message.id: message,
    };
    for (final message in messages) {
      byId[message.id] = message;
    }
    if (byId.isEmpty) return;
    final merged = byId.values.toList()
      ..sort((a, b) {
        final order = a.createdAt.compareTo(b.createdAt);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    final capped = merged.length > maxMessagesPerChat
        ? merged.sublist(merged.length - maxMessagesPerChat)
        : merged;
    await saveRawJson(_messagesKey(userId, chatId), {
      'messages': capped.map((m) => m.toJson()).toList(),
    });
  }

  /// Overwrites the stored history with exactly [messages] (used after the
  /// server confirms deletions, where merging would resurrect old rows).
  Future<void> replaceMessages(
    String userId,
    String chatId,
    Iterable<MessageModel> messages,
  ) async {
    if (_box == null || userId.isEmpty || chatId.isEmpty) return;
    final sorted = messages.toList()
      ..sort((a, b) {
        final order = a.createdAt.compareTo(b.createdAt);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    final capped = sorted.length > maxMessagesPerChat
        ? sorted.sublist(sorted.length - maxMessagesPerChat)
        : sorted;
    await saveRawJson(_messagesKey(userId, chatId), {
      'messages': capped.map((m) => m.toJson()).toList(),
    });
  }

  /// Drops one chat's stored history (e.g. after "clear history").
  Future<void> removeChat(String userId, String chatId) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.delete(_messagesKey(userId, chatId));
      await box.delete(_metaKey(userId, chatId, 'pinned'));
    } catch (_) {}
  }

  /// Drops everything stored for one account (used on sign-out of that
  /// account so a different person on the same device never sees it).
  Future<void> clearUser(String userId) async {
    final box = _box;
    if (box == null || userId.isEmpty) return;
    try {
      final suffix = ':$userId';
      final keys = box.keys
          .whereType<String>()
          .where((k) =>
              k.endsWith(suffix) ||
              k.contains('$suffix:') ||
              k == _chatListKey(userId, false) ||
              k == _chatListKey(userId, true) ||
              k == _foldersKey(userId))
          .toList();
      await box.deleteAll(keys);
    } catch (_) {}
  }
}
