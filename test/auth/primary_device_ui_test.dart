import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:secure_messenger/presentation/screens/auth/two_factor_security_screen.dart';
import 'package:secure_messenger/presentation/screens/settings/device_management_screen.dart';

import '../support/messenger_test_support.dart';

/// Point 4: the device screen must make the primary-device rules visible and
/// must not offer actions the server will refuse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  setUpAll(storage.open);
  setUp(storage.reset);
  tearDownAll(storage.close);

  Map<String, dynamic> device({
    required String id,
    required String name,
    bool isCurrent = false,
    bool isPrimary = false,
    bool canTerminate = true,
  }) =>
      {
        'id': id,
        'device_name': name,
        'device_model': 'Pixel 7',
        'device_type': 'mobile',
        'os': 'Android 14',
        'app_version': '1.4.0',
        'ip_address': '5.23.1.1',
        'last_active_at': '2026-09-18T10:00:00Z',
        'is_current': isCurrent,
        'is_primary': isPrimary,
        'can_terminate': canTerminate,
      };

  MockClient deviceClient(
    List<Map<String, dynamic>> devices, {
    List<String>? calls,
    bool isPrimaryDevice = false,
  }) =>
      MockClient((request) async {
        calls?.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/devices/')) {
          return jsonResponse({
            'devices': devices,
            'current_device_id': 'd-current',
          });
        }
        if (request.url.path.endsWith('/security/alerts')) {
          return jsonResponse({
            'alerts': [],
            'is_primary_device': isPrimaryDevice,
          });
        }
        return jsonResponse({'ok': true});
      });

  Future<void> pumpDevices(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: DeviceManagementScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the primary device is badged and cannot be removed from another',
      (tester) async {
    final client = deviceClient([
      device(
          id: 'd-primary',
          name: 'Old Phone',
          isPrimary: true,
          canTerminate: false),
      device(id: 'd-current', name: 'New Phone', isCurrent: true),
    ]);

    await http.runWithClient(() async {
      await pumpDevices(tester);

      expect(find.text('اصلی'), findsOneWidget);
      expect(find.text('فعلی'), findsOneWidget);
      expect(find.textContaining('فقط از روی خودش قابل حذف است'),
          findsOneWidget);
      // Exactly one row (the non-primary, non-current one) offers logout.
      expect(find.byIcon(Icons.logout), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    }, () => client);
  });

  testWidgets('the primary device itself may remove its own entry',
      (tester) async {
    final calls = <String>[];
    final client = deviceClient(
      [
        device(
            id: 'd-current',
            name: 'This Phone',
            isCurrent: true,
            isPrimary: true,
            canTerminate: true),
        device(id: 'd-other', name: 'Tablet'),
      ],
      calls: calls,
      isPrimaryDevice: true,
    );

    await http.runWithClient(() async {
      await pumpDevices(tester);

      expect(find.text('این دستگاه، دستگاه اصلی حساب است'), findsOneWidget);
      // Both rows can be terminated from here.
      expect(find.byIcon(Icons.logout), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.logout).first);
      await tester.pumpAndSettle();
      expect(find.text('حذف دستگاه اصلی'), findsWidgets);
      await tester.tap(find.text('حذف دستگاه اصلی').last);
      await tester.pumpAndSettle();

      expect(
        calls.any((call) => call.contains('/devices/d-current/terminate')),
        isTrue,
      );
    }, () => client);
  });

  testWidgets('a secondary device sees an explanation instead of the badge',
      (tester) async {
    final client = deviceClient([
      device(
          id: 'd-primary',
          name: 'Old Phone',
          isPrimary: true,
          canTerminate: false),
      device(id: 'd-current', name: 'New Phone', isCurrent: true),
    ]);

    await http.runWithClient(() async {
      await pumpDevices(tester);
      expect(find.text('این دستگاه، دستگاه اصلی نیست'), findsOneWidget);
      expect(find.textContaining('تنظیمات امنیتی فقط روی آن دستگاه'),
          findsOneWidget);
    }, () => client);
  });

  testWidgets('the current device can request to become primary',
      (tester) async {
    final calls = <String>[];
    Map<String, dynamic>? transferBody;
    final client = MockClient((request) async {
      calls.add(request.url.path);
      if (request.url.path.endsWith('/devices/primary/transfer')) {
        transferBody = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({'primary_device_id': 'd-current'});
      }
      if (request.url.path.endsWith('/devices/')) {
        return jsonResponse({
          'devices': [
            device(
                id: 'd-primary',
                name: 'Old Phone',
                isPrimary: true,
                canTerminate: false),
            device(id: 'd-current', name: 'New Phone', isCurrent: true),
          ],
          'current_device_id': 'd-current',
        });
      }
      return jsonResponse({'alerts': [], 'is_primary_device': false});
    });

    await http.runWithClient(() async {
      await pumpDevices(tester);
      await tester.tap(find.byIcon(Icons.shield_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('انتقال'));
      await tester.pumpAndSettle();

      expect(transferBody?['device_id'], 'd-current');
    }, () => client);
  });

  testWidgets('a server refusal is surfaced to the user', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.contains('/terminate')) {
        return jsonResponse({
          'error': 'دستگاه اصلی حساب را فقط از روی همان دستگاه می‌توان حذف کرد.',
          'code': 'cannot_terminate_primary',
        }, status: 403);
      }
      if (request.url.path.endsWith('/devices/')) {
        return jsonResponse({
          'devices': [
            device(id: 'd-current', name: 'This Phone', isCurrent: true),
            // A stale row that the server will actually refuse.
            device(id: 'd-primary', name: 'Old Phone', canTerminate: true),
          ],
          'current_device_id': 'd-current',
        });
      }
      return jsonResponse({'alerts': [], 'is_primary_device': false});
    });

    await http.runWithClient(() async {
      await pumpDevices(tester);
      await tester.tap(find.byIcon(Icons.logout).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأیید'));
      await tester.pumpAndSettle();

      expect(find.textContaining('فقط از روی همان دستگاه'), findsOneWidget);
    }, () => client);
  });

  testWidgets('two-step verification is blocked off a secondary device',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({'alerts': [], 'is_primary_device': false});
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: TwoFactorSecurityScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('primary-device-notice')),
          findsOneWidget);
      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'فعال‌سازی Google Authenticator'));
      expect(button.onPressed, isNull);
    }, () => client);
  });

  testWidgets('two-step verification is available on the primary device',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/security/alerts')) {
        return jsonResponse({'alerts': [], 'is_primary_device': true});
      }
      return jsonResponse({'ok': true});
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: TwoFactorSecurityScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('primary-device-notice')), findsNothing);
      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'فعال‌سازی Google Authenticator'));
      expect(button.onPressed, isNotNull);
    }, () => client);
  });
}
