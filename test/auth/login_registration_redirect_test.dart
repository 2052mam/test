import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:secure_messenger/presentation/screens/auth/login_screen.dart';
import 'package:secure_messenger/presentation/screens/auth/phone_verification_screen.dart';
import 'package:secure_messenger/presentation/screens/auth/register_screen.dart';

import '../support/messenger_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  setUpAll(storage.open);
  setUp(storage.reset);
  tearDownAll(storage.close);

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('An unregistered number is sent to sign-up instead of an SMS code',
      (tester) async {
    final calls = <String>[];
    final client = MockClient((request) async {
      calls.add(request.url.path);
      if (request.url.path.endsWith('/auth/request-phone-code')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['mobile_number'], '+989121234567');
        return jsonResponse({
          'registration_required': true,
          'mobile_number': '+989121234567',
        });
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextFormField).single, '+989121234567');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.byType(PhoneVerificationScreen, skipOffstage: false), findsNothing);
      // The number is carried over so the user does not retype it.
      expect(find.text('+989121234567'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, () => client);

    expect(calls.where((p) => p.endsWith('/auth/request-phone-code')).length, 1);
  });

  testWidgets('A response without a verification id never opens the code screen',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/auth/request-phone-code')) {
        return jsonResponse({'mobile_number': '+989121234567'});
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextFormField).single, '+989121234567');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(RegisterScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('A registered number still receives a code and the verify screen',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/auth/request-phone-code')) {
        return jsonResponse({
          'verification_id': 'phone-challenge',
          'mobile_number': '+989••••567',
          'registration_required': false,
        }, status: 202);
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextFormField).single, '+989121234567');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneVerificationScreen), findsOneWidget);
      expect(find.byType(RegisterScreen, skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, () => client);
  });
}
