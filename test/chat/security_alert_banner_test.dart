import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:secure_messenger/presentation/screens/home/chat_list_screen.dart';

import '../support/messenger_test_support.dart';

/// Point 3: the "another device signed in" warning has to be on the chat list
/// straight away, not after an app restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  setUpAll(storage.open);
  setUp(storage.reset);
  tearDownAll(storage.close);

  Map<String, dynamic> alert({
    String id = 'a1',
    String severity = 'critical',
    String title = 'ورود جدید به حساب شما',
  }) =>
      {
        'id': id,
        'alert_type': 'new_device_login',
        'title': title,
        'body': 'دستگاه Pixel 7 از IP 5.23.1.1 وارد شد.',
        'severity': severity,
        'device_name': 'Pixel 7',
        'created_at': '2026-09-18T10:00:00Z',
      };

  Map<String, dynamic> emptyChatList() => {
        'chats': [],
        'has_archive': false,
        'archived_total': 0,
        'archived_unread': 0,
      };

  Future<void> pumpChatList(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ChatListScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('a pending alert is rendered on the chat list', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        // Only unread alerts are asked for, and only one at a time.
        expect(request.url.queryParameters['unread'], '1');
        expect(request.url.queryParameters['limit'], '1');
        return jsonResponse({'alerts': [alert()], 'unread': 1});
      }
      if (request.url.path.contains('/chats')) {
        return jsonResponse(emptyChatList());
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpChatList(tester);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('security-alert-banner')),
          findsOneWidget);
      expect(find.text('ورود جدید به حساب شما'), findsOneWidget);
      expect(find.byIcon(Icons.gpp_maybe), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('no banner is shown when there is nothing to warn about',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({'alerts': [], 'unread': 0});
      }
      if (request.url.path.contains('/chats')) {
        return jsonResponse(emptyChatList());
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpChatList(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('security-alert-banner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('an alert raised while the list is open appears within a poll',
      (tester) async {
    // This is the actual bug from Point 3: the old banner only ever fetched
    // once, so an alert raised later never showed up.
    var raised = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({
          'alerts': raised ? [alert()] : [],
          'unread': raised ? 1 : 0,
        });
      }
      if (request.url.path.contains('/chats')) {
        return jsonResponse(emptyChatList());
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpChatList(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('security-alert-banner')), findsNothing);

      raised = true;
      await tester.pump(const Duration(seconds: 20));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('security-alert-banner')),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('dismissing tells the server so it does not come back',
      (tester) async {
    final calls = <String>[];
    var dismissed = false;
    final client = MockClient((request) async {
      calls.add(request.url.path);
      if (request.url.path.contains('/alerts/a1/dismiss')) {
        dismissed = true;
        return jsonResponse({'ok': true});
      }
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({'alerts': dismissed ? [] : [alert()]});
      }
      if (request.url.path.contains('/chats')) {
        return jsonResponse(emptyChatList());
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpChatList(tester);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(dismissed, isTrue);
      expect(find.byKey(const ValueKey('security-alert-banner')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('a warning-level alert uses the softer styling', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({
          'alerts': [
            alert(severity: 'warning', title: 'درخواست کد ورود'),
          ],
        });
      }
      if (request.url.path.contains('/chats')) {
        return jsonResponse(emptyChatList());
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpChatList(tester);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.security), findsOneWidget);
      expect(find.byIcon(Icons.gpp_maybe), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });
}
