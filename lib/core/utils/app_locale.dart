/// Point 5: the app language, readable from code that has no BuildContext.
///
/// Notifications, background polls and other services build user-facing text
/// outside the widget tree, so they cannot call `Localizations.localeOf`.
/// Until now they simply hardcoded Persian, which is why an English user still
/// saw Persian banners (and why a Persian string could show up on an English
/// screen). `LocaleNotifier` publishes the chosen language here whenever it
/// changes, and services read it through [isFa].
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppLocale {
  AppLocale._();

  /// English is the product default, matching `LocaleNotifier`.
  static String _code = 'en';

  /// The active language code ('fa' or 'en').
  static String get code => _code;

  static bool get isFa => _code == 'fa';

  /// Called by `LocaleNotifier` on load and on every language change.
  static void set(String languageCode) {
    if (languageCode.isNotEmpty) _code = languageCode;
  }

  /// Read the stored preference directly. Used by entry points that run before
  /// any widget exists — a background isolate handling an FCM message, for
  /// instance, where the notifier has never been constructed.
  static Future<String> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      set(prefs.getString('locale') ?? 'en');
    } catch (_) {
      // Storage unavailable: keep the default rather than fail a notification.
    }
    return _code;
  }

  /// Pick the string matching the active language.
  static String pick(String fa, String en) => isFa ? fa : en;
}
