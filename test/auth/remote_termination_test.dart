/// Point 3: logging a second device out from the primary phone must really
/// end that device's session and send it back to the login screen.
///
/// The bug was re-entrancy. Once a device is terminated the server answers
/// EVERY request with 401 `device_terminated`, including the requests made
/// while signing out. `ApiService` fires `onUnauthorized` for each of those,
/// which re-entered `handleRemoteTermination`, bumped the session generation,
/// and made the outer `_clearSession(generation)` fail its `_isCurrent` guard
/// and return having cleared nothing — so the phone stayed logged in.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:secure_messenger/data/services/account_service.dart';
import 'package:secure_messenger/data/services/api_service.dart';
import 'package:secure_messenger/data/services/storage_service.dart';
import 'package:secure_messenger/presentation/providers/auth_provider.dart';

import '../support/messenger_test_support.dart';

/// Every call answers like a terminated device, which is exactly what the
/// second phone sees after the primary phone ends its session.
MockClient terminatedClient({List<String>? seen}) => MockClient((request) async {
  seen?.add(request.url.path);
  return jsonResponse({
    'error': 'این دستگاه از حساب خارج شده است.',
    'code': 'device_terminated',
  }, status: 401);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = TestStorage();
  setUpAll(storage.open);
  setUp(storage.reset);
  tearDownAll(storage.close);

  test('A terminated device clears its session even when sign-out 401s', () async {
    await http.runWithClient(() async {
      final auth = AuthNotifier();
      final container = ProviderContainer(
        overrides: [authNotifierProvider.overrideWith((ref) => auth)],
      );
      addTearDown(container.dispose);
      container.read(authNotifierProvider);
      await auth.setLoggedIn(testUser('alice'), 'alice-access', 'alice-refresh');
      expect(StorageService.getToken(), 'alice-access');

      await auth.handleRemoteTermination();

      // Signed out for real: no user, no tokens, no saved active account.
      expect(container.read(authNotifierProvider).valueOrNull, isNull);
      expect(StorageService.getToken(), isNull);
      expect(await AccountService.getActive(), isNull);
    }, terminatedClient());
  });

  test('Re-entrant 401s during termination cannot revive the session', () async {
    await http.runWithClient(() async {
      final auth = AuthNotifier();
      final container = ProviderContainer(
        overrides: [authNotifierProvider.overrideWith((ref) => auth)],
      );
      addTearDown(container.dispose);
      container.read(authNotifierProvider);
      await auth.setLoggedIn(testUser('alice'), 'alice-access', 'alice-refresh');

      // The real wiring: a 401 from any in-flight call re-triggers termination.
      ApiService.onUnauthorized = (_) => auth.handleRemoteTermination();
      addTearDown(() => ApiService.onUnauthorized = null);

      // Several screens polling at once all hit 401 simultaneously.
      await Future.wait([
        auth.handleRemoteTermination(),
        auth.handleRemoteTermination(),
        auth.handleRemoteTermination(),
      ]);
      // Let any microtask-scheduled callbacks run.
      await Future<void>.delayed(Duration.zero);

      expect(container.read(authNotifierProvider).valueOrNull, isNull);
      expect(StorageService.getToken(), isNull);
    }, terminatedClient());
  });

  test('An expired-session code signs the device out too', () async {
    await http.runWithClient(() async {
      final auth = AuthNotifier();
      final container = ProviderContainer(
        overrides: [authNotifierProvider.overrideWith((ref) => auth)],
      );
      addTearDown(container.dispose);
      container.read(authNotifierProvider);
      await auth.setLoggedIn(testUser('alice'), 'alice-access', 'alice-refresh');
      await auth.handleRemoteTermination();
      expect(container.read(authNotifierProvider).valueOrNull, isNull);
    }, MockClient((request) async => jsonResponse(
      {'error': 'نشست منقضی شده است.', 'code': 'session_ended'},
      status: 401,
    )));
  });

  test('checkSession on a terminated device lands on signed-out', () async {
    await http.runWithClient(() async {
      final auth = AuthNotifier();
      final container = ProviderContainer(
        overrides: [authNotifierProvider.overrideWith((ref) => auth)],
      );
      addTearDown(container.dispose);
      container.read(authNotifierProvider);
      await auth.setLoggedIn(testUser('alice'), 'alice-access', 'alice-refresh');

      // The second phone resumes the app: /users/me and the refresh both 401.
      await auth.checkSession();

      expect(container.read(authNotifierProvider).valueOrNull, isNull);
      expect(StorageService.getToken(), isNull);
    }, terminatedClient());
  });

  test('ApiException exposes the termination codes', () {
    expect(
      ApiException(statusCode: 401, message: 'x', code: 'device_terminated')
          .isDeviceTerminated,
      isTrue,
    );
    expect(
      ApiException(statusCode: 401, message: 'x', code: 'session_ended')
          .isDeviceTerminated,
      isTrue,
    );
    // An ordinary 401 (a bad password) must NOT nuke the session.
    expect(
      ApiException(statusCode: 401, message: 'x').isDeviceTerminated,
      isFalse,
    );
  });
}
