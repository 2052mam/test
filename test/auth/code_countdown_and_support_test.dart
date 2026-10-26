import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:secure_messenger/presentation/screens/auth/login_screen.dart';
import 'package:secure_messenger/presentation/screens/auth/phone_verification_screen.dart';

import '../support/messenger_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  setUpAll(storage.open);
  setUp(storage.reset);
  tearDownAll(storage.close);

  Future<void> pumpVerification(
    WidgetTester tester, {
    String channel = 'sms',
    int resendAfter = 300,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PhoneVerificationScreen(
            verificationId: 'challenge-1',
            mobileNumber: '+989121234567',
            flow: PhoneVerificationFlow.login,
            deliveryChannel: channel,
            resendAfterSeconds: resendAfter,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Tearing the tree down cancels the countdown timer.
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  group('Point 1 — the resend countdown', () {
    testWidgets('starts at five minutes and counts down every second',
        (tester) async {
      await pumpVerification(tester);

      expect(find.text('ارسال دوباره کد تا 05:00 دیگر'), findsOneWidget);
      // The resend button is hidden while the countdown runs.
      expect(find.byKey(const ValueKey('resend-button')), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('ارسال دوباره کد تا 04:59 دیگر'), findsOneWidget);

      await tester.pump(const Duration(seconds: 59));
      expect(find.text('ارسال دوباره کد تا 04:00 دیگر'), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('reveals the resend button once it reaches zero',
        (tester) async {
      await pumpVerification(tester, resendAfter: 3);

      expect(find.byKey(const ValueKey('resend-countdown')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('resend-countdown')), findsNothing);
      expect(find.byKey(const ValueKey('resend-button')), findsOneWidget);

      await disposeTree(tester);
    });

    testWidgets('restarts from the server value after a successful resend',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/resend-phone-code')) {
          return jsonResponse({
            'verification_id': 'challenge-2',
            'delivery_channel': 'sms',
            'resend_after_seconds': 120,
          }, status: 202);
        }
        return jsonResponse({'ok': true});
      });

      await http.runWithClient(() async {
        await pumpVerification(tester, resendAfter: 1);
        await tester.pump(const Duration(seconds: 1));

        await tester.tap(find.byKey(const ValueKey('resend-button')));
        await tester.pump();
        await tester.pump();

        expect(find.text('Resend code in 02:00'), findsOneWidget);
        expect(find.text('A new code was sent by SMS.'), findsOneWidget);
        await disposeTree(tester);
      }, () => client);
    });

    testWidgets('a 429 puts the remaining server wait back on the clock',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/resend-phone-code')) {
          return jsonResponse({
            'error': 'لطفاً پیش از درخواست دوباره کمی صبر کنید.',
            'retry_after_seconds': 45,
          }, status: 429);
        }
        return jsonResponse({'ok': true});
      });

      await http.runWithClient(() async {
        await pumpVerification(tester, resendAfter: 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byKey(const ValueKey('resend-button')));
        await tester.pump();
        await tester.pump();

        expect(find.text('Resend code in 00:45'), findsOneWidget);
        await disposeTree(tester);
      }, () => client);
    });
  });

  group('Point 3 — in-app code delivery', () {
    testWidgets('explains that the code went to another signed-in device',
        (tester) async {
      await pumpVerification(tester, channel: 'in_app');

      expect(find.textContaining('sent to another device'), findsOneWidget);
      expect(find.byKey(const ValueKey('force-sms-button')), findsOneWidget);
      await disposeTree(tester);
    });

    testWidgets('an SMS delivery does not offer the SMS fallback',
        (tester) async {
      await pumpVerification(tester);

      expect(find.textContaining('sent by SMS'), findsOneWidget);
      expect(find.byKey(const ValueKey('force-sms-button')), findsNothing);
      await disposeTree(tester);
    });

    testWidgets('the SMS fallback ignores the countdown and forces an SMS',
        (tester) async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/resend-phone-code')) {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'verification_id': 'challenge-3',
            'delivery_channel': 'sms',
            'resend_after_seconds': 300,
          }, status: 202);
        }
        return jsonResponse({'ok': true});
      });

      await http.runWithClient(() async {
        // The countdown is still running: the SMS button must work anyway.
        await pumpVerification(tester, channel: 'in_app', resendAfter: 300);
        await tester.tap(find.byKey(const ValueKey('force-sms-button')));
        await tester.pump();
        await tester.pump();

        expect(sentBody?['force_sms'], true);
        expect(find.text('A new code was sent by SMS.'), findsOneWidget);
        // Having switched to SMS, the in-app notice is gone.
        expect(find.byKey(const ValueKey('force-sms-button')), findsNothing);
        await disposeTree(tester);
      }, () => client);
    });

    testWidgets('the login screen forwards the delivery channel it was given',
        (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/request-phone-code')) {
          return jsonResponse({
            'verification_id': 'challenge-4',
            'mobile_number': '+989121234567',
            'registration_required': false,
            'delivery_channel': 'in_app',
            'resend_after_seconds': 300,
          }, status: 202);
        }
        return jsonResponse({'ok': true});
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: LoginScreen())),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byType(TextFormField).first, '+989121234567');
        await tester.tap(find.text('Continue'));
        await tester.pump();
        await tester.pump();

        final screen = tester.widget<PhoneVerificationScreen>(
            find.byType(PhoneVerificationScreen));
        expect(screen.deliveryChannel, 'in_app');
        expect(screen.resendAfterSeconds, 300);
        await disposeTree(tester);
      }, () => client);
    });
  });

  group('Point 6 — contact support', () {
    testWidgets('the code screen offers a support entry point', (tester) async {
      await pumpVerification(tester);
      expect(
          find.byKey(const ValueKey('contact-support-button')), findsOneWidget);
      await disposeTree(tester);
    });

    testWidgets('the login screen offers a support entry point',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LoginScreen())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('login-contact-support')),
        200,
      );
      expect(
          find.byKey(const ValueKey('login-contact-support')), findsOneWidget);
    });

    testWidgets('the sheet submits a ticket with the number already filled in',
        (tester) async {
      Map<String, dynamic>? ticket;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/support/topics')) {
          return jsonResponse({
            'topics': [
              {'id': 'code_not_received', 'title': 'کد تأیید را دریافت نکردم'},
            ],
          });
        }
        if (request.url.path.endsWith('/support/tickets')) {
          ticket = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({'ok': true, 'ticket_id': 't1'}, status: 201);
        }
        return jsonResponse({'ok': true});
      });

      await http.runWithClient(() async {
        await pumpVerification(tester);
        await tester.tap(find.byKey(const ValueKey('contact-support-button')));
        await tester.pumpAndSettle();

        expect(find.text('تماس با پشتیبانی'), findsOneWidget);
        // The number the user is verifying is pre-filled.
        expect(find.text('+989121234567'), findsOneWidget);

        await tester.enterText(
            find.widgetWithText(TextFormField, 'شرح مشکل'), 'کد نمی‌آید');
        await tester.tap(find.text('ارسال به پشتیبانی'));
        await tester.pumpAndSettle();

        expect(ticket?['mobile_number'], '+989121234567');
        expect(ticket?['message'], 'کد نمی‌آید');
        expect(ticket?['topic'], 'code_not_received');
        // The sheet closes and the screen confirms the ticket.
        expect(find.textContaining('پشتیبانی ثبت شد'), findsOneWidget);
        await disposeTree(tester);
      }, () => client);
    });

    testWidgets('a too-short description is rejected before any request',
        (tester) async {
      var posted = false;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/support/tickets')) posted = true;
        return jsonResponse({'topics': []});
      });

      await http.runWithClient(() async {
        await pumpVerification(tester);
        await tester.tap(find.byKey(const ValueKey('contact-support-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ارسال به پشتیبانی'));
        await tester.pumpAndSettle();

        expect(posted, isFalse);
        expect(find.text('لطفاً مشکل را کمی کامل‌تر بنویسید'), findsOneWidget);
        await disposeTree(tester);
      }, () => client);
    });
  });
}
