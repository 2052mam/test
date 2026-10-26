import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/chat_navigation.dart';

void main() {
  testWidgets('a repeated chat open from search focuses the existing route',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Launcher()));
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open search results'));
    await tester.pumpAndSettle();
    expect(find.text('Search results'), findsOneWidget);

    await tester.tap(find.text('Open this chat'));
    await tester.pumpAndSettle();

    expect(find.text('Chat room'), findsOneWidget);
    expect(find.text('Search results'), findsNothing);
  });
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => ChatNavigation.open(
              context,
              chatId: 'same-chat',
              builder: (_) => const _ChatPage(),
            ),
            child: const Text('Open chat'),
          ),
        ),
      );
}

class _ChatPage extends StatelessWidget {
  const _ChatPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const _SearchPage()),
            ),
            child: const Text('Open search results'),
          ),
        ),
      );
}

class _SearchPage extends StatelessWidget {
  const _SearchPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Search results'),
              TextButton(
                onPressed: () => ChatNavigation.open(
                  context,
                  chatId: 'same-chat',
                  builder: (_) => const _ChatPage(),
                ),
                child: const Text('Open this chat'),
              ),
            ],
          ),
        ),
      );
}
