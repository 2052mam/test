import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart';
import 'package:secure_messenger/data/models/message_model.dart';
import 'package:secure_messenger/data/services/offline_cache_service.dart';
import 'package:secure_messenger/presentation/providers/auth_provider.dart';
import 'package:secure_messenger/presentation/screens/chat/chat_screen.dart';

import '../support/messenger_test_support.dart';

/// Every request fails the way a phone with its connection off fails.
Future<http.Response> _offline(http.Request request) {
  throw const SocketException('Network is unreachable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  late RecordPlatform previousRecord;

  setUpAll(storage.open);
  setUp(() async {
    await storage.reset();
    await OfflineCacheService.instance.init();
    previousRecord = RecordPlatform.instance;
    RecordPlatform.instance = IdleRecordPlatform();
  });
  tearDown(() async {
    RecordPlatform.instance = previousRecord;
    await OfflineCacheService.instance.resetForTest();
  });
  tearDownAll(storage.close);

  testWidgets(
    'opening a chat with no connection shows the cached history, not an error',
    (tester) async {
      await OfflineCacheService.instance.saveMessages('alice', 'chat', [
        MessageModel(
          id: 'cached-1',
          chatId: 'chat',
          senderId: 'bob',
          messageType: 'text',
          content: 'Cached hello from yesterday',
          createdAt: DateTime.utc(2026, 9, 6, 20, 15),
          status: 'read',
        ),
        MessageModel(
          id: 'cached-2',
          chatId: 'chat',
          senderId: 'alice',
          messageType: 'text',
          content: 'And my cached reply',
          createdAt: DateTime.utc(2026, 9, 6, 20, 16),
          status: 'read',
        ),
      ]);

      final auth = AuthNotifier();
      await auth.setLoggedIn(testUser('alice'), 'alice-access', 'alice-refresh');

      await http.runWithClient(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [authNotifierProvider.overrideWith((ref) => auth)],
            child: const MaterialApp(
              home: ChatScreen(chatId: 'chat', title: 'Bob'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Cached hello from yesterday'), findsOneWidget);
        expect(find.text('And my cached reply'), findsOneWidget);
        // No internet-error screen replaced the conversation.
        expect(find.textContaining('اتصال به سرور برقرار نشد'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, () => MockClient(_offline));
    },
  );
}
