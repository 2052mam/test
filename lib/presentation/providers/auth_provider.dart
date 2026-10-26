import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/app_locale.dart';
import '../../data/models/user_model.dart';
import '../../data/services/account_service.dart';
import '../../data/services/api_service.dart';
import '../../data/services/background_poll_service.dart';
import '../../data/services/connection_service.dart';
import '../../data/services/notification_service.dart';
import '../../data/services/push_service.dart';
import '../../data/services/storage_service.dart';

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<UserModel?>>((ref) {
      final notifier = AuthNotifier();
      // A device terminated from another phone signs THIS phone out on its
      // very next API call (Item 4), exactly like Telegram.
      ApiService.onUnauthorized = (_) => notifier.handleRemoteTermination();
      ref.onDispose(() {
        if (ApiService.onUnauthorized != null) ApiService.onUnauthorized = null;
      });
      notifier.checkSession();
      return notifier;
    });

/// Published only after credentials and auth state agree. A token refresh for
/// the same user updates request clients without resetting their route stack.
/// Older clients/requests retain their original account's credentials.
final authenticatedSessionProvider =
    Provider<({String? userId, String? token, ApiService api})>((ref) {
      final user = ref.watch(authNotifierProvider).valueOrNull;
      final token = user == null ? null : StorageService.getToken();
      return (userId: user?.id, token: token, api: ApiService.withToken(token));
    });

class AuthNotifier extends StateNotifier<AsyncValue<UserModel?>> {
  AuthNotifier() : super(const AsyncValue.loading());

  int _sessionGeneration = 0;

  bool _isCurrent(int generation) =>
      mounted && generation == _sessionGeneration;

  Future<({UserModel user, String accessToken})> _loadSession(
    String accessToken,
    String refreshToken,
  ) async {
    Map<String, dynamic> response;
    try {
      response = await ApiService.withToken(accessToken).get('/users/me');
    } on ApiException catch (error) {
      if (![401, 422].contains(error.statusCode) || refreshToken.isEmpty)
        rethrow;
      final refreshed = await ApiService.withToken(
        refreshToken,
      ).post('/auth/refresh', {});
      accessToken = refreshed['access_token'] as String;
      response = await ApiService.withToken(accessToken).get('/users/me');
    }
    return (user: UserModel.fromJson(response), accessToken: accessToken);
  }

  Future<void> checkSession() async {
    final generation = ++_sessionGeneration;
    final previous = state.valueOrNull;
    var token = StorageService.getToken();
    if (token == null || token.isEmpty) {
      // No active token, but the device may still hold a valid saved account
      // (e.g. after an "add account" flow was cancelled). Restoring it keeps
      // the user out of the login screen they already passed once.
      var saved = await AccountService.getActive();
      if (saved == null) {
        final all = await AccountService.list();
        if (all.isNotEmpty) saved = all.last;
      }
      if (saved != null) {
        try {
          final session = await _loadSession(
            saved.accessToken,
            saved.refreshToken,
          );
          if (!_isCurrent(generation)) return;
          await _saveSession(
            session.user,
            session.accessToken,
            saved.refreshToken,
            generation,
          );
          return;
        } catch (error) {
          if (error is ApiException && error.statusCode == 0) {
            // Offline cold start: restore the saved account locally
            // (Telegram-style). Its tokens are kept, so the moment the
            // connection returns the normal session refresh resumes, and
            // in the meantime every screen renders its offline cache.
            if (!_isCurrent(generation)) return;
            await _saveSession(
              _userFromSaved(saved),
              saved.accessToken,
              saved.refreshToken,
              generation,
            );
            return;
          }
          // Saved session is dead — drop it and fall through to signed-out.
          // Only a real server rejection may do this; a network failure
          // must never erase the account (or its offline cache).
          if (error is ApiException &&
              [401, 403, 404, 422].contains(error.statusCode)) {
            await AccountService.remove(saved.userId);
          }
        }
      }
      if (!_isCurrent(generation)) return;
      ApiService().setToken(null);
      state = const AsyncValue.data(null);
      return;
    }
    try {
      final refreshToken = StorageService.getRefreshToken() ?? '';
      final session = await _loadSession(token, refreshToken);
      if (!_isCurrent(generation)) return;
      await _saveSession(
        session.user,
        session.accessToken,
        refreshToken,
        generation,
      );
    } catch (error, stack) {
      // A response belonging to the previous account must never log out the
      // account that has just finished signing in / switching.
      if (!_isCurrent(generation)) return;
      if (error is ApiException &&
          [401, 403, 404, 422].contains(error.statusCode)) {
        await _clearSession(generation);
      } else if (previous == null) {
        // Offline cold start with a stored token: open onto the locally
        // saved account instead of an error/login screen. Credentials are
        // untouched, so sync simply resumes when connectivity returns.
        final restored = error is ApiException && error.statusCode == 0
            ? await _offlineFallbackUser()
            : null;
        if (!_isCurrent(generation)) return;
        if (restored != null) {
          ApiService().setToken(token);
          state = AsyncValue.data(restored);
        } else {
          // Keep credentials on transient network failures; retry remains possible.
          state = AsyncValue.error(error, stack);
        }
      }
    }
  }

  static UserModel _userFromSaved(SavedAccount account) => UserModel(
        id: account.userId,
        email: account.email,
        mobileNumber: account.mobileNumber,
        username: account.username,
        displayName: account.displayName,
        avatarUrl: account.avatarUrl,
      );

  /// The locally saved account matching the stored session, if any. Used to
  /// open the app offline; never invents a session for an unknown account.
  Future<UserModel?> _offlineFallbackUser() async {
    try {
      final accounts = await AccountService.list();
      final userId = StorageService.getUserId();
      for (final account in accounts) {
        if (account.userId == userId) return _userFromSaved(account);
      }
      final active = await AccountService.getActive();
      if (active != null) return _userFromSaved(active);
    } catch (_) {}
    return null;
  }

  Future<void> _saveSession(
    UserModel user,
    String accessToken,
    String refreshToken,
    int generation,
  ) async {
    if (!_isCurrent(generation)) return;
    await StorageService.saveToken(accessToken);
    if (!_isCurrent(generation)) return;
    await StorageService.saveRefreshToken(refreshToken);
    if (!_isCurrent(generation)) return;
    await StorageService.saveUserId(user.id);
    if (!_isCurrent(generation)) return;
    await AccountService.save(
      SavedAccount.fromUser(user, accessToken, refreshToken),
    );
    if (!_isCurrent(generation)) return;
    ApiService().setToken(accessToken);
    state = AsyncValue.data(user);
  }

  Future<void> setLoggedIn(
    UserModel user,
    String accessToken,
    String refreshToken,
  ) {
    return _saveSession(user, accessToken, refreshToken, ++_sessionGeneration);
  }

  Future<void> switchAccount(SavedAccount account) async {
    final generation = ++_sessionGeneration;
    // Validate/refresh BEFORE replacing the current user's credentials. A bad
    // saved session must not strand a valid account on the login screen.
    final session = await _loadSession(
      account.accessToken,
      account.refreshToken,
    );
    if (!_isCurrent(generation)) return;
    if (session.user.id != account.userId) {
      throw ApiException(statusCode: 403, message: AppLocale.pick('حساب ذخیره‌شده معتبر نیست', 'The saved account is invalid.'));
    }
    await _saveSession(
      session.user,
      session.accessToken,
      account.refreshToken,
      generation,
    );
  }

  void setUser(UserModel? user) {
    ++_sessionGeneration;
    state = AsyncValue.data(user);
  }

  Future<void> _clearSession(int generation) async {
    if (!_isCurrent(generation)) return;
    await StorageService.clearTokens();
    if (!_isCurrent(generation)) return;
    await AccountService.clearActive();
    if (!_isCurrent(generation)) return;
    ApiService().setToken(null);
    // Signed out: no banners, no background polling for this account.
    try {
      await NotificationService().cancelAll();
    } catch (_) {}
    try {
      await ConnectionService.stop();
    } catch (_) {}
    try {
      await BackgroundPollService.stop();
    } catch (_) {}
    state = const AsyncValue.data(null);
  }

  Future<void> _logout({required bool keepAccounts}) async {
    final generation = ++_sessionGeneration;
    final userId = state.valueOrNull?.id ?? StorageService.getUserId();
    final token = StorageService.getToken();
    if (token != null) {
      try {
        await ApiService.withToken(token).post('/auth/logout', {});
      } catch (_) {}
    }
    // Stop FCM ticks to this device (runs while the stored token is still
    // valid; clears the server-side token and rotates the local FCM token).
    try {
      await PushService.unregisterToken();
    } catch (_) {}
    if (!_isCurrent(generation)) return;
    if (!keepAccounts && userId != null) await AccountService.remove(userId);
    await _clearSession(generation);
  }

  Future<void> logout() => _logout(keepAccounts: false);

  /// Sign out of the active account but keep it in the saved-accounts list, so
  /// it can be resumed from the login screen without retyping credentials.
  Future<void> logoutKeepAccounts() => _logout(keepAccounts: true);

  /// Called when the server reports `device_terminated` / `session_ended`:
  /// drop the dead credentials locally (the remote device already ended the
  /// server-side session, so no logout call is needed).
  ///
  /// Point 3: this used to leave the phone signed in. Terminating a device
  /// makes *every* subsequent request 401, and the calls made while signing
  /// out — `PushService.unregisterToken()` above all — 401 as well. Each of
  /// those re-entered this method, bumped `_sessionGeneration`, and so made
  /// the outer `_clearSession(generation)` fail its `_isCurrent` check and
  /// return without clearing anything. The session survived and the phone
  /// stayed on the chat list. The guard below makes termination run exactly
  /// once, and the state is cleared FIRST so no later failure can undo it.
  bool _terminating = false;

  Future<void> handleRemoteTermination() async {
    if (_terminating) return;
    _terminating = true;
    try {
      final generation = ++_sessionGeneration;
      final userId = state.valueOrNull?.id ?? StorageService.getUserId();
      // Clear before any network call, so a 401 on the way out cannot leave
      // the device authenticated.
      await _clearSession(generation);
      if (userId != null) {
        try {
          await AccountService.remove(userId);
        } catch (_) {}
      }
      // Rotate the FCM token too (the POST 401s harmlessly; the server already
      // cleared the token when terminating the device).
      try {
        await PushService.unregisterToken();
      } catch (_) {}
    } finally {
      _terminating = false;
    }
  }
}
