import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:secure_messenger/data/models/chat_model.dart';
import 'package:secure_messenger/data/models/message_model.dart';
import 'package:secure_messenger/data/services/api_service.dart';
import 'package:secure_messenger/data/services/offline_cache_service.dart';
import 'package:secure_messenger/presentation/providers/chat_list_provider.dart';

MessageModel message(String id, {String content = 'hello', int minute = 0}) {
  return MessageModel(
    id: id,
    chatId: 'chat',
    senderId: 'bob',
    messageType: 'text',
    content: content,
    createdAt: DateTime.utc(2026, 9, 7, 12, minute),
    status: 'read',
  );
}

class OfflineApi extends ApiService {
  OfflineApi() : super.withToken('alice');

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    throw ApiException(statusCode: 0, message: 'no network', code: 'network');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('offline-cache-test-');
    Hive.init(dir.path);
  });

  setUp(() async {
    await OfflineCacheService.instance.init();
  });

  tearDown(() async {
    await OfflineCacheService.instance.resetForTest();
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('messages round-trip through the offline store in order', () async {
    final cache = OfflineCacheService.instance;
    await cache.saveMessages('alice', 'chat', [
      message('m2', minute: 2),
      message('m1', minute: 1),
    ]);
    final restored = cache.messagesSync('alice', 'chat');
    expect(restored.map((m) => m.id), ['m1', 'm2']);
    expect(restored.first.content, 'hello');
    expect(restored.first.status, 'read');
  });

  test('saving merges by id and caps the history', () async {
    final cache = OfflineCacheService.instance;
    await cache.saveMessages('alice', 'chat', [message('m1', content: 'old')]);
    await cache.saveMessages('alice', 'chat', [
      message('m1', content: 'edited', minute: 1),
      message('m2', minute: 2),
    ]);
    final restored = cache.messagesSync('alice', 'chat');
    expect(restored, hasLength(2));
    expect(restored.first.content, 'edited');

    final many = [
      for (var i = 0; i < OfflineCacheService.maxMessagesPerChat + 25; i++)
        message('bulk-$i', minute: i % 60),
    ];
    await cache.replaceMessages('alice', 'chat', many);
    expect(
      cache.messagesSync('alice', 'chat'),
      hasLength(OfflineCacheService.maxMessagesPerChat),
    );
  });

  test('replace overwrites so deleted messages stay deleted', () async {
    final cache = OfflineCacheService.instance;
    await cache.saveMessages('alice', 'chat', [message('m1'), message('m2', minute: 1)]);
    await cache.replaceMessages('alice', 'chat', [message('m2', minute: 1)]);
    expect(cache.messagesSync('alice', 'chat').map((m) => m.id), ['m2']);
    await cache.removeChat('alice', 'chat');
    expect(cache.messagesSync('alice', 'chat'), isEmpty);
  });

  test('cache is isolated per user and clearable per user', () async {
    final cache = OfflineCacheService.instance;
    await cache.saveMessages('alice', 'chat', [message('m1')]);
    await cache.saveMessages('bob', 'chat', [message('m9')]);
    await cache.clearUser('alice');
    expect(cache.messagesSync('alice', 'chat'), isEmpty);
    expect(cache.messagesSync('bob', 'chat').map((m) => m.id), ['m9']);
  });

  test('model JSON round-trips are lossless', () {
    final original = message('m1', content: 'سلام دنیا');
    final restored = MessageModel.fromJson(original.toJson());
    expect(restored, original);

    final chat = ChatModel(
      id: 'chat',
      chatType: 'private',
      title: 'Bob',
      unreadCount: 3,
      updatedAt: DateTime.utc(2026, 9, 7, 12),
      lastMessage: LastMessageModel(
        id: 'm1',
        content: 'hi',
        messageType: 'text',
        senderId: 'bob',
        createdAt: DateTime.utc(2026, 9, 7, 12),
      ),
    );
    final restoredChat = ChatModel.fromJson(chat.toJson());
    expect(restoredChat.id, chat.id);
    expect(restoredChat.unreadCount, 3);
    expect(restoredChat.lastMessage?.content, 'hi');
  });

  test('chat list provider seeds from cache and survives a dead network',
      () async {
    final chat = ChatModel(
      id: 'chat',
      chatType: 'private',
      title: 'Bob',
      updatedAt: DateTime.utc(2026, 9, 7, 12),
    );
    await OfflineCacheService.instance.saveChatListJson('alice', json: {
      'chats': [chat.toJson()],
      'archived': {'total': 0, 'unread': 0, 'chats_with_unread': 0},
    });

    final notifier = ChatListNotifier(
      api: OfflineApi(),
      enabled: true,
      userId: 'alice',
    );
    addTearDown(notifier.dispose);

    // The cached list is visible synchronously — no loading spinner.
    expect(notifier.state.hasValue, isTrue);
    expect(notifier.state.value!.chats.single.id, 'chat');

    // A failed refresh keeps the cached list instead of erroring.
    await notifier.loadChats();
    expect(notifier.state.hasValue, isTrue);
    expect(notifier.state.value!.chats.single.id, 'chat');
  });
}
